import org.apache.zookeeper.*;
import org.apache.zookeeper.data.*;
import java.util.*;
import java.util.concurrent.CountDownLatch;

/** Grow the datatree and the ACL cache so a full SNAP is large enough that the
 *  leader's socket write to a stalled learner actually blocks. Each znode gets a
 *  distinct digest ACL, so every one adds an entry to ReferenceCountedACLCache. */
public class ZKLoad {
    public static void main(String[] a) throws Exception {
        String servers = a[0];
        int n = Integer.parseInt(a[1]);
        String prefix = a.length > 2 ? a[2] : "/load";
        // ReferenceCountedACLCache.serialize writes the ACL map FIRST and releases the
        // monitor before the nodes are written, so the ACL section alone has to exceed
        // the learner socket's buffer for writeInt to actually block. Fat ACL ids are
        // the cheapest way to get there: aclIdLen bytes x n entries.
        int aclIdLen = Integer.parseInt(System.getProperty("aclIdLen", "2000"));
        StringBuilder pad = new StringBuilder();
        for (int i = 0; i < aclIdLen; i++) pad.append('p');
        String padding = pad.toString();
        byte[] payload = new byte[200];
        Arrays.fill(payload, (byte) 'x');

        CountDownLatch connected = new CountDownLatch(1);
        ZooKeeper zk = new ZooKeeper(servers, 30000, e -> {
            if (e.getState() == Watcher.Event.KeeperState.SyncConnected) connected.countDown();
        });
        connected.await();

        try { zk.create(prefix, new byte[0], ZooDefs.Ids.OPEN_ACL_UNSAFE, CreateMode.PERSISTENT); }
        catch (KeeperException.NodeExistsException ignored) { }

        for (int i = 0; i < n; i++) {
            List<ACL> acl = new ArrayList<>();
            // unique id per node => unique ACL => a new ReferenceCountedACLCache entry
            acl.add(new ACL(ZooDefs.Perms.ALL, new Id("digest", "u" + i + ":pw" + i + padding)));
            acl.add(new ACL(ZooDefs.Perms.READ, ZooDefs.Ids.ANYONE_ID_UNSAFE));
            try { zk.create(prefix + "/n" + i, payload, acl, CreateMode.PERSISTENT); }
            catch (KeeperException.NodeExistsException ignored) { }
            if (i % 2000 == 0) System.out.println("  created " + i);
        }
        System.out.println("ZKLoad done: " + n + " znodes with distinct ACLs under " + prefix);
        zk.close();
    }
}
