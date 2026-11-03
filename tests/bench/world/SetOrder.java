import it.unimi.dsi.fastutil.shorts.*;
import java.util.*;

/** Reads one line per case from stdin ("p1,p2,..." = the order in which positions are added to vanilla's ChunkHolder.changedBlocksPerSection set) and prints, per case, the
 *  iteration order of fastutil's ShortOpenHashSet, comma separated: the order in which ClientboundSectionBlocksUpdatePacket writes its entries.  Run it with the fastutil
 *  jar of the pinned server (libraries/it/unimi/dsi/fastutil/8.5.18/ under the server's directory): see set_order.sh. */
public class SetOrder {
    public static void main(String[] a) {
        Scanner sc = new Scanner(System.in);
        while (sc.hasNextLine()) {
            String line = sc.nextLine().trim();
            if (line.isEmpty()) { System.out.println(); continue; }
            ShortSet s = new ShortOpenHashSet();
            for (String t : line.split(",")) s.add(Short.parseShort(t.trim()));
            StringBuilder sb = new StringBuilder();
            ShortIterator it = s.iterator();
            while (it.hasNext()) { if (sb.length() > 0) sb.append(','); sb.append(it.nextShort()); }
            System.out.println(sb);
        }
    }
}
