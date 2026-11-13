// Dumps, for every block state of the pinned 26.3 server, the facts the light engine needs (net.minecraft.world.level.lighting.*): the state's light
// emission, light dampening, and its occlusion face shapes as LightEngine.getOcclusionShape(state, direction) answers them (empty for a state that does
// not use its shape for light occlusion), plus the table of which pairs of those face shapes occlude (Shapes.faceShapeOccludes).  tools/gen_light.sh compiles
// and runs this and writes $DBCRAFT_REPORTS/light_states.tsv, which tools/load_light.py loads into mc.light_state / mc.light_face / mc.light_face_occ.
// It touches ONLY static data of the vanilla classes (it boots the registries as the data generator does, nothing is simulated); everything is read through
// reflection so that the file compiles with any JDK without the Minecraft classes on the compile class path (javac 21 cannot read 26.3's class files,
// java 25 runs them).
//
// Output:
//   "S" rows (one per block state, ordered by state id), tab separated:  S  state_id  emission  dampening  shaped  f_down f_up f_north f_south f_west f_east
//        shaped   t when the state uses its occlusion shape for light (canOcclude && useShapeForLightOcclusion); the six f_* are face-shape ids ("F" rows),
//                 0 (the empty shape) for a state that is not shaped
//   "F" rows: id  kind (0 empty, 1 full square, 2 other)  boxes ("x0 y0 z0 x1 y1 z1;..." of the face shape)
//   "P" rows: a  b    every ordered pair of face-shape ids for which Shapes.faceShapeOccludes(a, b) is true
import java.lang.reflect.*;
import java.util.*;

public class LightDump {
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
    static String b(boolean v) { return v ? "t" : "f"; }
    static boolean bool(Object o) { return (Boolean) o; }

    public static void main(String[] a) throws Exception {
        call(c("net.minecraft.SharedConstants"), "tryDetectVersion");
        call(c("net.minecraft.server.Bootstrap"), "bootStrap");
        Object blockReg = field(c("net.minecraft.core.registries.BuiltInRegistries"), "BLOCK");
        Class<?> blockC = c("net.minecraft.world.level.block.Block");
        Object stateReg = field(blockC, "BLOCK_STATE_REGISTRY");
        Class<?> dirC = c("net.minecraft.core.Direction");
        Object[] dirs = dirC.getEnumConstants();                     // DOWN, UP, NORTH, SOUTH, WEST, EAST
        Class<?> shapesC = c("net.minecraft.world.phys.shapes.Shapes");
        Class<?> engineC = c("net.minecraft.world.level.lighting.LightEngine");
        Object shapesBlock = call(shapesC, "block");
        Object shapesEmpty = call(shapesC, "empty");
        List<Object> shapeObjs = new ArrayList<>();
        List<String> shapeKey = new ArrayList<>();
        Map<String, Integer> shapeId = new HashMap<>();
        shapeObjs.add(shapesEmpty); shapeKey.add("empty"); shapeId.put("empty", 0);
        List<String[]> rows = new ArrayList<>();
        for (Object block : (Iterable<?>) blockReg) {
            Iterable<?> states = (Iterable<?>) call(call(block, "getStateDefinition"), "getPossibleStates");
            for (Object st : states) {
                int id = (Integer) call(stateReg, "getId", st);
                boolean shaped = bool(call(st, "canOcclude")) && bool(call(st, "useShapeForLightOcclusion"));
                String[] r = new String[11];
                r[0] = "S"; r[1] = String.valueOf(id); r[2] = String.valueOf(call(st, "getLightEmission")); r[3] = String.valueOf(call(st, "getLightDampening")); r[4] = b(shaped);
                for (int d = 0; d < 6; d++) {
                    Object shape = call(engineC, "getOcclusionShape", st, dirs[d]);
                    String key = shape == shapesEmpty || bool(call(shape, "isEmpty")) ? "empty" : (shape == shapesBlock ? "full" : boxes(shape));
                    Integer sid = shapeId.get(key);
                    if (sid == null) { sid = shapeObjs.size(); shapeObjs.add(shape); shapeKey.add(key); shapeId.put(key, sid); }
                    r[5 + d] = String.valueOf(sid);
                }
                rows.add(r);
            }
        }
        rows.sort(Comparator.comparingInt(r -> Integer.parseInt(r[1])));
        StringBuilder out = new StringBuilder();
        for (String[] r : rows) out.append(String.join("\t", r)).append('\n');
        for (int i = 0; i < shapeKey.size(); i++) {
            String k = shapeKey.get(i);
            out.append("F\t").append(i).append('\t').append(k.equals("empty") ? 0 : k.equals("full") ? 1 : 2).append('\t').append(k.equals("empty") || k.equals("full") ? "" : k).append('\n');
        }
        for (int i = 0; i < shapeKey.size(); i++)
            for (int j = 0; j < shapeKey.size(); j++)
                if (bool(call(shapesC, "faceShapeOccludes", shapeObjs.get(i), shapeObjs.get(j)))) out.append("P\t").append(i).append('\t').append(j).append('\n');
        System.out.print(out);
    }

    static String boxes(Object shape) throws Exception {
        StringBuilder sb = new StringBuilder();
        for (Object box : (Iterable<?>) call(shape, "toAabbs")) {
            if (sb.length() > 0) sb.append(';');
            for (String f : new String[]{"minX", "minY", "minZ", "maxX", "maxY", "maxZ"}) sb.append(String.format(Locale.ROOT, "%.6f ", (Double) box.getClass().getField(f).get(box)));
            sb.setLength(sb.length() - 1);
        }
        return sb.toString();
    }
}
