import java.io.*;
import java.util.Arrays;
import java.util.zip.Inflater;

/**
 * Second judge for the native deflate extension: Java's own java.util.zip.Inflater, which is the inflater the Minecraft client uses.
 * Same input format as tools/zlib_check.py:   label TAB kind TAB hex_stream TAB hex_expected    (kind: zlib | frame | raw)
 *   raw = a bare deflate stream (Inflater(nowrap = true)), used for deflate_raw and for fragments.
 * Run (Java 11+ source launch):   java tests/bench/native/InflateCheck.java < /tmp/dbcraft_native_zin.tsv      (tests/bench/native/inflate_java.sh does it)
 */
public class InflateCheck {
    static byte[] hex(String s) {
        byte[] b = new byte[s.length() / 2];
        for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
        return b;
    }

    // returns {value, next offset}
    static int[] varint(byte[] b, int o) {
        int v = 0, shift = 0;
        while (true) {
            int c = b[o++] & 0xff;
            v |= (c & 0x7f) << shift;
            if ((c & 0x80) == 0) return new int[] {v, o};
            shift += 7;
        }
    }

    public static void main(String[] args) throws Exception {
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in), 1 << 20);
        String line;
        int ok = 0, bad = 0;
        while ((line = in.readLine()) != null) {
            if (line.isEmpty()) continue;
            String[] f = line.split("\t", -1);
            String label = f[0], kind = f[1];
            String verdict;
            try {
                byte[] stream = hex(f[2]), want = hex(f[3]);
                int off = 0, dlen = -1;
                if (kind.equals("frame")) {
                    int[] pl = varint(stream, 0);
                    if (pl[0] != stream.length - pl[1]) throw new Exception("packet length " + pl[0] + " but " + (stream.length - pl[1]) + " bytes follow");
                    int[] dl = varint(stream, pl[1]);
                    dlen = dl[0];
                    off = dl[1];
                    if (dlen != want.length) throw new Exception("data length " + dlen + ", payload is " + want.length);
                }
                Inflater inf = new Inflater(kind.equals("raw"));     // zlib wrapper (header + Adler-32) as the protocol sends it; raw = no wrapper
                inf.setInput(stream, off, stream.length - off);
                byte[] out = new byte[want.length + 16];
                int n = 0;
                while (!inf.finished()) {
                    int r = inf.inflate(out, n, out.length - n);
                    if (r == 0 && !inf.finished() && (inf.needsInput() || inf.needsDictionary())) throw new Exception("stream ended early");
                    n += r;
                    if (n >= out.length) break;
                }
                if (!inf.finished()) throw new Exception("stream not terminated");
                if (inf.getRemaining() != 0) throw new Exception(inf.getRemaining() + " bytes after the end of the stream");
                verdict = (n == want.length && Arrays.equals(Arrays.copyOf(out, n), want)) ? "ok" : "FAIL inflates to " + n + " bytes, expected " + want.length;
                inf.end();
            } catch (Exception e) {
                verdict = "FAIL " + e.getClass().getSimpleName() + ": " + e.getMessage();
            }
            if (verdict.equals("ok")) ok++; else bad++;
            if (!verdict.equals("ok")) System.out.println(label + "\t" + verdict);
        }
        System.out.println("java.util.zip.Inflater: " + ok + " ok, " + bad + " rejected");
        System.exit(bad == 0 ? 0 : 1);
    }
}
