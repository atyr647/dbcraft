// Dumps what the pinned 26.3 server answers for digging: per block state BlockState.getDestroySpeed(level, pos) (the hardness, -1 = unbreakable) and
// BlockState.requiresCorrectToolForDrops(), and which block classes override BlockBehaviour.getDestroyProgress (none are expected: the dump says so).  tools/gen_mining.sh
// compiles and runs this and writes $DBCRAFT_REPORTS/block_mining.tsv, which tools/load_mining.py loads into ref.block_mining.  Like SoundDump.java it only reads the vanilla
// classes' static data (boots the registries the way the data generator does, simulates nothing) and goes through reflection, so it compiles with any JDK.
//
//   java -cp SERVER_JAR:LIBS MiningDump.java > block_mining.tsv
//
// Output rows, tab separated:
//   B  block_name  hardness  requires_correct_tool(0/1)      (the default state)
//   X  state_id  hardness  requires_correct_tool              (a state that differs from its block's default state)
//   O  block_name  declaring_class                            (a block class that overrides getDestroyProgress)
import java.lang.reflect.*;
import java.util.*;

public class MiningDump {
    static Class<?> c(String n) throws Exception { return Class.forName(n); }
    static Class<?> wrap(Class<?> p) {
        if (p == int.class) return Integer.class; if (p == boolean.class) return Boolean.class; if (p == double.class) return Double.class;
        if (p == float.class) return Float.class; if (p == long.class) return Long.class; return p;
    }
    static Object call(Object o, String name, Object... args) throws Exception {
        boolean stat = o instanceof Class;
        for (Method m : (stat ? (Class<?>) o : o.getClass()).getMethods()) {
            if (!m.getName().equals(name) || m.getParameterCount() != args.length) continue;
            boolean ok = true;
            Class<?>[] pt = m.getParameterTypes();
            for (int i = 0; i < args.length; i++) if (args[i] != null && !wrap(pt[i]).isAssignableFrom(args[i].getClass())) ok = false;
            if (!ok) continue;
            m.setAccessible(true);
            try { return m.invoke(stat ? null : o, args); } catch (InvocationTargetException e) { throw (e.getCause() instanceof Exception) ? (Exception) e.getCause() : e; }
        }
        throw new NoSuchMethodException(name + "/" + args.length + " on " + (stat ? o : o.getClass()));
    }
    static Object field(Class<?> k, String n) throws Exception { return k.getField(n).get(null); }
    static float hardness(Object st) throws Exception {
        for (Method m : st.getClass().getMethods())
            if (m.getName().equals("getDestroySpeed") && m.getParameterCount() == 2) { m.setAccessible(true); return (Float) m.invoke(st, (Object) null, (Object) null); }
        throw new NoSuchMethodException("getDestroySpeed");
    }

    public static void main(String[] a) throws Exception {
        call(c("net.minecraft.SharedConstants"), "tryDetectVersion");
        call(c("net.minecraft.server.Bootstrap"), "bootStrap");
        Object blockReg = field(c("net.minecraft.core.registries.BuiltInRegistries"), "BLOCK");
        Object stateReg = field(c("net.minecraft.world.level.block.Block"), "BLOCK_STATE_REGISTRY");
        StringBuilder blocks = new StringBuilder(), exc = new StringBuilder(), ovr = new StringBuilder();
        Class<?> base = c("net.minecraft.world.level.block.state.BlockBehaviour");
        for (Object block : (Iterable<?>) blockReg) {
            String name = String.valueOf(call(call(blockReg, "getKey", block), "toString"));
            Object ds = call(block, "defaultBlockState");
            float dh = hardness(ds); boolean dr = (Boolean) call(ds, "requiresCorrectToolForDrops");
            blocks.append("B\t").append(name).append('\t').append(dh).append('\t').append(dr ? 1 : 0).append('\n');
            for (Object st : (Iterable<?>) call(call(block, "getStateDefinition"), "getPossibleStates")) {
                float h = hardness(st); boolean r = (Boolean) call(st, "requiresCorrectToolForDrops");
                if (h != dh || r != dr) exc.append("X\t").append(call(stateReg, "getId", st)).append('\t').append(h).append('\t').append(r ? 1 : 0).append('\n');
            }
            for (Method m : block.getClass().getMethods())
                if (m.getName().equals("getDestroyProgress") && m.getDeclaringClass() != base && !m.getDeclaringClass().getName().startsWith("net.minecraft.world.level.block.state.BlockBehaviour"))
                    ovr.append("O\t").append(name).append('\t').append(m.getDeclaringClass().getName()).append('\n');
        }
        System.out.print(blocks); System.out.print(exc); System.out.print(ovr);
    }
}
