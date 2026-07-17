import oathkeeper.engine.InferEngine;
import oathkeeper.runtime.EventTracer;
import oathkeeper.runtime.FileLayoutManager;
import oathkeeper.runtime.event.OpTriggerEvent;
import oathkeeper.runtime.event.SemanticEvent;
import oathkeeper.runtime.eventlist.EventList;
import oathkeeper.runtime.invariant.Context;
import oathkeeper.runtime.invariant.Invariant;
import oathkeeper.runtime.template.EventImplyEventTemplate;
import org.junit.Assert;
import org.junit.Before;
import org.junit.Test;

import java.util.List;
import java.util.Map;

/**
 * Regression tests for the eventMap aliasing bug.
 *
 * registerOpEvent/registerStateEvent -- the calls DynamicClassModifier injects into each instrumented
 * method -- reuse ONE event object per thread and overwrite its fields on every call. Follow two calls
 * with that single object E:
 *
 *   registerOpEvent("acquire"):   E.opName = "acquire"     eventMap["acquire"] -> [E]
 *   registerOpEvent("release"):   E.opName = "release"     eventMap["release"] -> [E]
 *
 * Both buckets now hold the same E, whose opName is "release" -- whatever fired last. So reading
 * eventMap["acquire"] back reports "release":
 *
 *   eventMap["acquire"] -> [E] -> reads back "release"     <-- the lie
 *   eventMap["release"] -> [E] -> reads back "release"
 *
 * verify then asks "did an acquire ever happen?" -- did the antecedent of "acquire implies release", its
 * left-hand trigger, occur? It scans the "acquire" bucket, sees only "release", and concludes no. The rule
 * is filed INACTIVE, meaning the antecedent never occurred. Every rule meets the same fate: verify reports 0.
 *
 * That verdict refutes itself. The bucket "acquire" EXISTS only because enqueueMap was once handed an event
 * whose getMapKey() returned "acquire" -- creating the bucket is a receipt that the antecedent did occur.
 * So the key says "an acquire happened" while the events filed under it say "no acquire here".
 *
 * enqueue() therefore stores a snapshot, giving each bucket its own copy:
 *
 *   eventMap["acquire"] -> [{opName:"acquire"}]
 *   eventMap["release"] -> [{opName:"release"}]
 *
 * Only the live tracer is affected: eventQueue is cloned either way, eventMap is transient, and
 * loadFromFile rebuilds it from that queue -- so a trace round-tripped through a file comes back clean.
 */
public class TestEventTracerAliasing {

    //A real high-level property: acquires and releases must balance, i.e. each acquire is matched by a
    //later release (EventImplyEventTemplate counts acquires up, releases down, and holds only if the
    //count ends at 0). CORRECT balances 3 acquires with 3 releases. FAULTY keeps all 3 acquires but
    //drops 2 releases, leaving 2 unmatched, so the rule fails there -- which is what lets infer mine it.
    private static final String[] CORRECT_WORKLOAD =
            {"acquire", "release", "read", "read", "acquire", "read", "flush", "read", "release", "acquire", "release"};
    private static final String[] FAULTY_WORKLOAD =
            {"acquire", "read", "read", "acquire", "read", "flush", "read", "acquire", "release"};

    @Before
    public void freshTracer() {
        System.setProperty("ok.ok_root_abs_path", System.getProperty("user.dir"));
        //registerOpEvent writes into the static instance; reset so cases don't bleed into each other
        EventTracer.instance = new EventTracer();
    }

    @Test
    public void testInferredInvariantsStayActiveOnSameWorkload() {
        String dir = FileLayoutManager.getPathForTestTraceDir();

        //gentrace: emit via registerOpEvent, dump both variants to file
        EventTracer.dumpToFile(dir, "aliasingPipeline" + EventTracer.PATCHED_SUFFIX, traceFor(CORRECT_WORKLOAD));
        EventTracer.dumpToFile(dir, "aliasingPipeline" + EventTracer.UNPATCHED_SUFFIX, traceFor(FAULTY_WORKLOAD));

        //infer: reads those files back, mining the property that separates the two workloads
        List<Invariant> invs = InferEngine.processTrace(dir + "/" + "aliasingPipeline", false);
        Assert.assertFalse("infer mined nothing, so this workload cannot test verify", invs.isEmpty());

        //verify: replay the same workload and check against the LIVE tracer, as RuntimeChecker does.
        //The corruption lives only here -- eventMap is transient and loadFromFile rebuilds it from the
        //(always cloned) eventQueue, so a trace that round-trips through a file comes back clean.
        emitViaRegisterOpEvent(CORRECT_WORKLOAD);
        int active = 0;
        for (Invariant inv : invs)
            if (inv.verify(EventTracer.instance) != Invariant.InvState.INACTIVE)
                active++;

        //INACTIVE means the antecedent never occurred: for "acquire implies release", no acquire was seen.
        //Here that is false by construction -- infer mined these rules FROM this workload, and it can only
        //mine "acquire implies release" if an acquire appeared in the trace. Replaying that same workload
        //therefore cannot leave every antecedent unseen, whatever one takes the right verify result to be.
        Assert.assertTrue("all " + invs.size() + " invariants inferred from this workload reported INACTIVE"
                + " (antecedent never occurred) when verified against that same workload", active > 0);
    }

    @Test
    public void testLiveEventMapAgreesWithQueue() {
        emitViaRegisterOpEvent(CORRECT_WORKLOAD);
        Invariant inv = acquireImpliesRelease();

        Invariant.InvState viaLiveMap = inv.verify(EventTracer.instance);

        //a file round-trip drops the transient eventMap and rebuilds it from eventQueue via
        //loadMapFromQueue(), giving a second path over identical events
        String dir = FileLayoutManager.getPathForTestTraceDir();
        EventTracer.dumpToFile(dir, "aliasingOracle", EventTracer.instance);
        EventTracer rebuilt = EventTracer.loadFromFile(dir + "/" + "aliasingOracle");
        Assert.assertNotNull("could not round-trip the tracer", rebuilt);

        //eventMap is only an index over eventQueue, so it cannot contradict the data it indexes. This
        //assumes nothing about which answer is correct, so it holds even if one disputes what verify
        //should return here.
        Assert.assertEquals("verify through the live eventMap disagrees with verify through the same"
                + " events rebuilt from eventQueue", inv.verify(rebuilt), viaLiveMap);
    }

    @Test
    public void testVerifyTellsHeldRuleFromNeverFired() {
        emitViaRegisterOpEvent(CORRECT_WORKLOAD);

        //holds by construction: CORRECT_WORKLOAD balances 3 acquires against 3 releases
        Assert.assertEquals("acquires and releases balance in this workload, so the rule holds",
                Invariant.InvState.PASS, acquireImpliesRelease().verify(EventTracer.instance));

        //Control: nobody ever fires this op, so INACTIVE is the right answer here. It proves INACTIVE is
        //reachable, which is what makes the PASS above mean something. Under the bug both come back
        //INACTIVE -- the checker can no longer tell "it happened" from "it never happened".
        Invariant neverFires = new Invariant(new EventImplyEventTemplate(),
                new Context(new OpTriggerEvent("op_that_never_fires"), new OpTriggerEvent("release")));
        Assert.assertEquals("op_that_never_fires never occurs, so this rule has no antecedent to trigger on",
                Invariant.InvState.INACTIVE, neverFires.verify(EventTracer.instance));
    }

    @Test
    public void testEventMapBucketsMatchTheirKey() {
        emitViaRegisterOpEvent(CORRECT_WORKLOAD);

        //Every event in bucket "acquire" should say "acquire". That is not a rule of my own choosing:
        //iterator(Context) looks a bucket up by name and trusts whatever it finds inside.
        //Weaker than the tests above -- it shows WHERE the corruption is, not that it is wrong.
        for (Map.Entry<String, EventList> entry : EventTracer.instance.eventMap.entrySet()) {
            String key = entry.getKey();
            EventList lst = entry.getValue();
            for (int i = 0; i < lst.size(); ++i) {
                SemanticEvent stored = (SemanticEvent) lst.get(i);
                Assert.assertEquals("event in bucket '" + key + "' reads back as '"
                        + stored.getMapKey() + "'", key, stored.getMapKey());
            }
        }
    }

    private Invariant acquireImpliesRelease() {
        return new Invariant(new EventImplyEventTemplate(),
                new Context(new OpTriggerEvent("acquire"), new OpTriggerEvent("release")));
    }

    //Go through registerOpEvent, the entry point DynamicClassModifier injects into instrumented methods,
    //so events pass through the per-thread reused object. Constructing OpTriggerEvents directly (as
    //traces/TraceFor* do) allocates a fresh one each call and never exercises the reuse.
    private void emitViaRegisterOpEvent(String[] workload) {
        EventTracer.instance = new EventTracer();
        for (String op : workload)
            EventTracer.registerOpEvent(op);
    }

    private EventTracer traceFor(String[] workload) {
        emitViaRegisterOpEvent(workload);
        EventTracer.instance.assignSerialTimestamp(true, true);
        return EventTracer.instance;
    }
}
