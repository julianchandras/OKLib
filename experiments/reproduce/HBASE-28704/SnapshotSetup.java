import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.hbase.HBaseConfiguration;
import org.apache.hadoop.hbase.TableName;
import org.apache.hadoop.hbase.client.Admin;
import org.apache.hadoop.hbase.client.ColumnFamilyDescriptorBuilder;
import org.apache.hadoop.hbase.client.Connection;
import org.apache.hadoop.hbase.client.ConnectionFactory;
import org.apache.hadoop.hbase.client.Put;
import org.apache.hadoop.hbase.client.SnapshotDescription;
import org.apache.hadoop.hbase.client.SnapshotType;
import org.apache.hadoop.hbase.client.Table;
import org.apache.hadoop.hbase.client.TableDescriptorBuilder;
import org.apache.hadoop.hbase.util.Bytes;
import org.apache.hadoop.hbase.util.EnvironmentEdgeManager;

/**
 * Create a table, load it, and take a snapshot carrying a TTL -- the setup half of the
 * HBASE-28704 reproduction. Mirrors what
 * TestRestoreSnapshotHelper#testCopyExpiredSnapshotForScanner does inside a MiniCluster,
 * but against a live standalone HBase.
 *
 * Usage: SnapshotSetup <table> <snapshot> <ttlSeconds> <rows> [destTable]
 *
 * destTable, if given, is created empty with the same column family: CopyTable
 * --snapshot --bulkload writes into an existing table, as TestCopyTable does.
 */
public class SnapshotSetup {
  public static void main(String[] args) throws Exception {
    String tableNameStr = args[0];
    String snapshotName = args[1];
    int ttl = Integer.parseInt(args[2]);
    int rows = Integer.parseInt(args[3]);
    String destTableStr = args.length > 4 ? args[4] : null;

    Configuration conf = HBaseConfiguration.create();
    byte[] cf = Bytes.toBytes("A");
    byte[] qual = Bytes.toBytes("q");
    TableName tn = TableName.valueOf(tableNameStr);

    try (Connection conn = ConnectionFactory.createConnection(conf); Admin admin = conn.getAdmin()) {
      for (SnapshotDescription s : admin.listSnapshots()) {
        if (snapshotName.equals(s.getName())) {
          admin.deleteSnapshot(snapshotName);
        }
      }
      if (admin.tableExists(tn)) {
        admin.disableTable(tn);
        admin.deleteTable(tn);
      }
      admin.createTable(TableDescriptorBuilder.newBuilder(tn)
        .setColumnFamily(ColumnFamilyDescriptorBuilder.of(cf)).build());

      try (Table table = conn.getTable(tn)) {
        List<Put> puts = new ArrayList<>();
        for (int i = 0; i < rows; i++) {
          Put p = new Put(Bytes.toBytes(String.format("row%06d", i)));
          p.addColumn(cf, qual, Bytes.toBytes("value" + i));
          puts.add(p);
        }
        table.put(puts);
      }
      // The snapshot is FLUSH type, so force the memstore out first; otherwise the
      // snapshot manifest can reference zero store files and the later scan reads 0 rows
      // for a reason that has nothing to do with the TTL.
      admin.flush(tn);

      Map<String, Object> props = new HashMap<>();
      props.put("TTL", ttl);
      SnapshotDescription desc = new SnapshotDescription(snapshotName, tn, SnapshotType.FLUSH, null,
        EnvironmentEdgeManager.currentTime(), -1, props);
      admin.snapshot(desc);

      boolean listed = false;
      for (SnapshotDescription s : admin.listSnapshots()) {
        if (snapshotName.equals(s.getName())) {
          listed = true;
        }
      }
      if (destTableStr != null) {
        TableName dest = TableName.valueOf(destTableStr);
        if (admin.tableExists(dest)) {
          admin.disableTable(dest);
          admin.deleteTable(dest);
        }
        admin.createTable(TableDescriptorBuilder.newBuilder(dest)
          .setColumnFamily(ColumnFamilyDescriptorBuilder.of(cf)).build());
        System.out.println("SETUP_DEST_TABLE=" + destTableStr);
      }
      System.out.println("SETUP_SNAPSHOT_LISTED=" + listed);
      System.out.println("SETUP_TTL_SECONDS=" + ttl);
      System.out.println("SETUP_CREATION_TIME=" + desc.getCreationTime());
      System.out.println("SETUP_ROWS=" + rows);
      System.out.println("SETUP_RESULT=" + (listed ? "OK" : "SNAPSHOT_MISSING"));
      System.exit(listed ? 0 : 1);
    }
  }
}
