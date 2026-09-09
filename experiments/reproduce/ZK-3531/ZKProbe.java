import org.apache.zookeeper.*;
import org.apache.zookeeper.data.*;
import java.util.*;
import java.util.concurrent.*;

/** Issue one ACL-touching write and report how long it takes.
 *  While the leader is blocked inside the synchronized ReferenceCountedACLCache.serialize,
 *  this cannot complete -- that is the hang. */
public class ZKProbe {
    public static void main(String[] a) throws Exception {
        String servers = a[0];
        int timeoutSec = Integer.parseInt(a[1]);
        CountDownLatch connected = new CountDownLatch(1);
        ZooKeeper zk = new ZooKeeper(servers, 30000, e -> {
            if (e.getState() == Watcher.Event.KeeperState.SyncConnected) connected.countDown();
        });
        if (!connected.await(timeoutSec, TimeUnit.SECONDS)) {
            System.out.println("PROBE_RESULT=NO_CONNECTION"); System.exit(2);
        }
        List<ACL> acl = new ArrayList<>();
        acl.add(new ACL(ZooDefs.Perms.ALL, new Id("digest", "probe:probe" + System.nanoTime())));

        ExecutorService ex = Executors.newSingleThreadExecutor();
        long t0 = System.currentTimeMillis();
        Future<String> f = ex.submit(() -> {
            zk.create("/probe-" + System.nanoTime(), new byte[]{1}, acl, CreateMode.PERSISTENT);
            return "ok";
        });
        try {
            f.get(timeoutSec, TimeUnit.SECONDS);
            System.out.println("PROBE_RESULT=COMPLETED elapsed_ms=" + (System.currentTimeMillis() - t0));
        } catch (TimeoutException te) {
            System.out.println("PROBE_RESULT=HUNG waited_s=" + timeoutSec);
        } catch (ExecutionException ee) {
            // A hung leader stops answering pings, so the session dies before our
            // own timeout fires and the create surfaces as ConnectionLoss. That is
            // the hang too -- report it rather than letting it kill the process.
            System.out.println("PROBE_RESULT=HUNG_CONNECTION_LOSS elapsed_ms="
                    + (System.currentTimeMillis() - t0) + " cause=" + ee.getCause());
        } finally {
            ex.shutdownNow();
            try { zk.close(); } catch (Exception ignored) { }
        }
    }
}
