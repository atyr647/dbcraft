// Dumps the block sound types of the pinned 26.3 server: what the game itself answers for BlockState.getSoundType() of every block state.  tools/gen_sounds.sh compiles and
// runs this and writes $DBCRAFT_REPORTS/block_sounds.tsv, which tools/load_sounds.py loads into mc.sound_type / mc.block_sound.  Like DynDump.java it only reads the
// vanilla classes' static data (boots the registries the way the data generator does, simulates nothing) and goes through reflection, so it compiles with any JDK.
//
//   java -cp SERVER_JAR:LIBS SoundDump.java > block_sounds.tsv
//
// Output rows, tab separated:
//   T  type_id  volume  pitch  break_sound  step_sound  place_sound  hit_sound  fall_sound     (sound event names without the namespace: "block.stone.break")
//   B  block_name  type_id                                                                      (the default state's sound type)
//   X  state_id  type_id                                                                         (a state whose sound type differs from its block's default state)
import java.lang.reflect.*;
import java.util.*;

public class SoundDump {
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
    static String ev(Object soundEvent) throws Exception {
        String s = String.valueOf(call(call(soundEvent, "location"), "toString"));
        return s.startsWith("minecraft:") ? s.substring(10) : s;
    }

    public static void main(String[] a) throws Exception {
        call(c("net.minecraft.SharedConstants"), "tryDetectVersion");
        call(c("net.minecraft.server.Bootstrap"), "bootStrap");
        Object blockReg = field(c("net.minecraft.core.registries.BuiltInRegistries"), "BLOCK");
        Object stateReg = field(c("net.minecraft.world.level.block.Block"), "BLOCK_STATE_REGISTRY");
        IdentityHashMap<Object, Integer> ids = new IdentityHashMap<>();
        List<Object> types = new ArrayList<>();
        StringBuilder blocks = new StringBuilder(), exc = new StringBuilder();
        for (Object block : (Iterable<?>) blockReg) {
            String name = String.valueOf(call(call(blockReg, "getKey", block), "toString"));
            int def = -1;
            Object ds = call(block, "defaultBlockState");
            for (Object st : (Iterable<?>) call(call(block, "getStateDefinition"), "getPossibleStates")) {
                Object t = call(st, "getSoundType");
                Integer id = ids.get(t);
                if (id == null) { id = types.size(); ids.put(t, id); types.add(t); }
                if (st == ds) { def = id; blocks.append("B\t").append(name).append('\t').append(id).append('\n'); }
            }
            for (Object st : (Iterable<?>) call(call(block, "getStateDefinition"), "getPossibleStates")) {
                int id = ids.get(call(st, "getSoundType"));
                if (id != def) exc.append("X\t").append(call(stateReg, "getId", st)).append('\t').append(id).append('\n');
            }
        }
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < types.size(); i++) {
            Object t = types.get(i);
            out.append("T\t").append(i).append('\t').append(call(t, "getVolume")).append('\t').append(call(t, "getPitch")).append('\t')
               .append(ev(call(t, "getBreakSound"))).append('\t').append(ev(call(t, "getStepSound"))).append('\t').append(ev(call(t, "getPlaceSound"))).append('\t')
               .append(ev(call(t, "getHitSound"))).append('\t').append(ev(call(t, "getFallSound"))).append('\n');
        }
        System.out.print(out); System.out.print(blocks); System.out.print(exc);
    }
}
