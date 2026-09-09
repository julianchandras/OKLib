import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.FileSystem;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.hbase.HBaseConfiguration;
import org.apache.hadoop.hbase.TableName;
import org.apache.hadoop.hbase.client.Admin;
import org.apache.hadoop.hbase.client.Connection;
import org.apache.hadoop.hbase.client.ConnectionFactory;
import org.apache.hadoop.hbase.client.Result;
import org.apache.hadoop.hbase.client.Scan;
import org.apache.hadoop.hbase.client.TableSnapshotScanner;
import org.apache.hadoop.hbase.snapshot.RestoreSnapshotHelper;
import org.apache.hadoop.hbase.snapshot.SnapshotDescriptionUtils;
import org.apache.hadoop.hbase.snapshot.SnapshotTTLExpiredException;
import org.apache.hadoop.hbase.util.CommonFSUtils;
import org.apache.hadoop.hbase.util.EnvironmentEdgeManager;

import org.apache.hadoop.hbase.shaded.protobuf.generated.SnapshotProtos;

/**
 * The differential probe for HBASE-28704: can a TTL-expired snapshot still be read?
 *
 * Three checks, in order of what they establish:
 *
 *   A  RestoreSnapshotHelper.copySnapshotForScanner -- the exact method the fix guards.
 *   B  TableSnapshotScanner over the expired snapshot -- the user-visible consequence,
 *      i.e. rows of data that policy says should no longer be readable. Plain client
 *      API, no MapReduce (which is what makes this variant runnable live at all;
 *      CopyTable and ExportSnapshot both need a job runner).
 *   C  Admin.cloneSnapshot -- the CONTROL. HBASE-27671 put a TTL check in
 *      CloneSnapshotProcedure, and 27671 is present on BOTH sides of this pair, so C
 *      must be refused on both. If C ever succeeds we are looking at the wrong build;
 *      if C is the only thing that differs we are measuring 27671, not 28704.
 *
 * Usage: SnapshotProbe <snapshot> <restoreDir> <cloneTable> [lingerSeconds]
 */
public class SnapshotProbe {
  public static void main(String[] args) throws Exception {
    String snapshotName = args[0];
    Path restoreDir = new Path(args[1]);
    String cloneTable = args[2];
    int lingerSec = args.length > 3 ? Integer.parseInt(args[3]) : 0;

    Configuration conf = HBaseConfiguration.create();
    Path rootDir = CommonFSUtils.getRootDir(conf);
    FileSystem fs = rootDir.getFileSystem(conf);

    Path snapshotDir = SnapshotDescriptionUtils.getCompletedSnapshotDir(snapshotName, rootDir);
    SnapshotProtos.SnapshotDescription desc = SnapshotDescriptionUtils.readSnapshotInfo(fs, snapshotDir);
    boolean expired = SnapshotDescriptionUtils.isExpiredSnapshot(desc.getTtl(),
      desc.getCreationTime(), EnvironmentEdgeManager.currentTime());
    System.out.println("PROBE_SNAPSHOT_TTL=" + desc.getTtl());
    System.out.println("PROBE_SNAPSHOT_CREATED=" + desc.getCreationTime());
    System.out.println("PROBE_SNAPSHOT_AGE_MS=" + (EnvironmentEdgeManager.currentTime() - desc.getCreationTime()));
    System.out.println("PROBE_SNAPSHOT_EXPIRED=" + expired);
    if (!expired) {
      // Not a build difference -- the script did not wait long enough, or the snapshot
      // was recreated. Fail loudly rather than reporting a fixed-looking result.
      System.out.println("PROBE_A=INCONCLUSIVE_NOT_YET_EXPIRED");
      System.exit(2);
    }

    // --- A: the guarded method itself -------------------------------------------------
    try {
      RestoreSnapshotHelper.copySnapshotForScanner(conf, fs, rootDir, restoreDir, snapshotName);
      System.out.println("PROBE_A=READ_EXPIRED_SNAPSHOT");
    } catch (SnapshotTTLExpiredException e) {
      System.out.println("PROBE_A=REFUSED_TTL_EXPIRED");
    } catch (Exception e) {
      System.out.println("PROBE_A=ERROR:" + e.getClass().getName() + ":" + e.getMessage());
    }

    // --- B: the data actually coming back ---------------------------------------------
    try (TableSnapshotScanner scanner =
        new TableSnapshotScanner(conf, rootDir, new Path(restoreDir + "-scan"), snapshotName, new Scan())) {
      int rows = 0;
      for (Result r = scanner.next(); r != null; r = scanner.next()) {
        rows++;
      }
      System.out.println("PROBE_B=READ_EXPIRED_SNAPSHOT rows=" + rows);
    } catch (SnapshotTTLExpiredException e) {
      System.out.println("PROBE_B=REFUSED_TTL_EXPIRED");
    } catch (Exception e) {
      System.out.println("PROBE_B=ERROR:" + e.getClass().getName() + ":" + e.getMessage());
    }

    // --- C: control, expected identical on both builds ---------------------------------
    try (Connection conn = ConnectionFactory.createConnection(conf); Admin admin = conn.getAdmin()) {
      TableName clone = TableName.valueOf(cloneTable);
      if (admin.tableExists(clone)) {
        admin.disableTable(clone);
        admin.deleteTable(clone);
      }
      admin.cloneSnapshot(snapshotName, clone);
      System.out.println("PROBE_C=CLONED  <-- UNEXPECTED: HBASE-27671 is missing from this build");
    } catch (Exception e) {
      String chain = e.getClass().getName();
      for (Throwable t = e.getCause(); t != null; t = t.getCause()) {
        chain += "<-" + t.getClass().getSimpleName();
      }
      boolean ttl = chain.contains("SnapshotTTLExpired");
      System.out.println("PROBE_C=" + (ttl ? "REFUSED_TTL_EXPIRED" : "ERROR") + " (" + chain + ")");
    }

    // Keep the JVM alive so OKLib's periodic checker gets rounds in. The bug lives in a
    // short-lived client process, not a daemon, so without this the process can exit
    // before a single check window closes.
    if (lingerSec > 0) {
      System.out.println("PROBE_LINGER=" + lingerSec + "s");
      Thread.sleep(lingerSec * 1000L);
    }
    System.out.println("PROBE_DONE");
    System.out.flush();
    // OKLib's RuntimeChecker runs `while (true) { sleep; check(); }` on a thread that is
    // never marked daemon (RuntimeChecker.java:467), so returning from main is not enough:
    // DestroyJavaVM waits on it and an instrumented client JVM never exits. The daemons
    // OKLib was built against get killed externally, so this never showed up there;
    // HBASE-28704 lives in a short-lived client process, where it does.
    // Exiting explicitly also pins the linger to a known point, keeping check-round
    // counts comparable between runs.
    System.exit(0);
  }
}
