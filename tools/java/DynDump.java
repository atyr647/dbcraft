// Dumps, for every block state of the pinned 26.3 server, the facts the world-dynamics SQL needs.  tools/gen_dynamics.sh compiles and runs this and writes
// $DBCRAFT_REPORTS/dyn_states.tsv, which tools/load_dynamics.py loads into mc.dyn_state / mc.dyn_shape / mc.dyn_occlude.  It touches ONLY the vanilla classes' static
// data: it boots the registries (as the data generator does) and asks every block state what the game itself answers.  Nothing is simulated.  Everything is read
// through reflection so that the file compiles with any JDK without the Minecraft classes on the compile class path (javac 21 cannot read 26.3's class files,
// java 25 runs them).
//
//   javac -d OUT DynDump.java ; java -cp OUT:SERVER_JAR:LIBS DynDump > dyn_states.tsv
//
// Output: three sections.
//   "S" rows (one per block state, ordered by state id), tab separated:
//      S  state_id  block  class_chain  rtick  air  solid  occludes  blocks_motion  fluid  fluid_amount  fluid_falling  waterlogged_cap  coll_shape  sturdy_full  sturdy_center  sturdy_rigid  liquid_container  replaceable  light_dampening
//      class_chain  the Java class names from the block's class up to (excluding) Block / BlockBehaviour, joined with '>'
//      fluid        '' | water | lava;  fluid_amount 0..9 (8 = source level, 1..7 flowing, 8 + falling = the falling flowing state)
//      coll_shape   id of the collision shape (rows "H"), -1 when it could not be read
//      sturdy_*     six characters 0/1 in the order DOWN UP NORTH SOUTH WEST EAST: BlockState.isFaceSturdy(.., dir, SupportType.FULL / CENTER / RIGID)
//   "H" rows: shape_id  kind (0 empty, 1 full block, 2 other)  aabbs   (the collision shape's boxes, "x0 y0 z0 x1 y1 z1;..." in blocks)
//   "O" rows: from_shape  to_shape  dir   one row for every ordered pair of non-empty, non-full collision shapes and direction for which
//             Shapes.mergedFaceOccludes(from, to, dir) is true (FlowingFluid.canPassThroughWall's test); pairs involving an empty or full shape are decided by kind
import java.lang.reflect.*;
import java.util.*;

public class DynDump {
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
        Object emptyGetter = field(c("net.minecraft.world.level.EmptyBlockGetter"), "INSTANCE");
        Object zero = field(c("net.minecraft.core.BlockPos"), "ZERO");
        Class<?> dirC = c("net.minecraft.core.Direction");
        Object[] dirs = dirC.getEnumConstants();                     // DOWN, UP, NORTH, SOUTH, WEST, EAST
        Class<?> shapesC = c("net.minecraft.world.phys.shapes.Shapes");
        Object shapesBlock = call(shapesC, "block");
        Object shapesEmpty = call(shapesC, "empty");
        Class<?> simpleWl = c("net.minecraft.world.level.block.SimpleWaterloggedBlock");
        Class<?> waterF = c("net.minecraft.world.level.material.WaterFluid");
        Class<?> lavaF = c("net.minecraft.world.level.material.LavaFluid");
        Class<?> flowingF = c("net.minecraft.world.level.material.FlowingFluid");
        Class<?> lbcC = c("net.minecraft.world.level.block.LiquidBlockContainer");
        Class<?> supportC = c("net.minecraft.world.level.block.SupportType");
        Object[] supports = supportC.getEnumConstants();             // FULL, CENTER, RIGID
        Object fallingProp = field(flowingF, "FALLING");
        Object levelProp = field(flowingF, "LEVEL");

        List<Object> shapeObjs = new ArrayList<>();
        List<String> shapeKey = new ArrayList<>();
        Map<String, Integer> shapeId = new HashMap<>();
        StringBuilder out = new StringBuilder();
        List<String[]> rows = new ArrayList<>();
        for (Object block : (Iterable<?>) blockReg) {
            String name = String.valueOf(call(call(blockReg, "getKey", block), "toString"));
            StringBuilder chain = new StringBuilder();
            for (Class<?> k = block.getClass(); k != null && k != blockC && !k.getSimpleName().equals("BlockBehaviour"); k = k.getSuperclass()) {
                if (chain.length() > 0) chain.append('>');
                chain.append(k.getSimpleName());
            }
            Iterable<?> states = (Iterable<?>) call(call(block, "getStateDefinition"), "getPossibleStates");
            for (Object st : states) {
                int id = (Integer) call(stateReg, "getId", st);
                boolean rtick = bool(call(st, "isRandomlyTicking")), air = bool(call(st, "isAir"));
                boolean solid = false, occl = false, bm = false;
                try { solid = bool(call(st, "isSolid")); } catch (Throwable t) { }
                try { occl = bool(call(st, "canOcclude")); } catch (Throwable t) { }
                try { bm = bool(call(st, "blocksMotion")); } catch (Throwable t) { }
                Object fs = call(st, "getFluidState");
                String fluid = "", famount = "0", ffall = "f";
                if (!bool(call(fs, "isEmpty"))) {
                    Object ft = call(fs, "getType");
                    fluid = waterF.isInstance(ft) ? "water" : (lavaF.isInstance(ft) ? "lava" : ft.getClass().getSimpleName());
                    famount = String.valueOf(call(fs, "getAmount"));
                    try { ffall = b(bool(call(fs, "getValue", fallingProp))); } catch (Throwable t) { }
                }
                String sf = "", sc = "", sr = "";
                for (Object d : dirs) {
                    try { sf += bool(call(st, "isFaceSturdy", emptyGetter, zero, d, supports[0])) ? "1" : "0"; } catch (Throwable t) { sf += "0"; }
                    try { sc += bool(call(st, "isFaceSturdy", emptyGetter, zero, d, supports[1])) ? "1" : "0"; } catch (Throwable t) { sc += "0"; }
                    try { sr += bool(call(st, "isFaceSturdy", emptyGetter, zero, d, supports[2])) ? "1" : "0"; } catch (Throwable t) { sr += "0"; }
                }
                boolean repl = false;
                try { repl = bool(call(st, "canBeReplaced")); } catch (Throwable t) { }
                int ld = 0;
                try { ld = (Integer) call(st, "getLightDampening"); } catch (Throwable t) { }
                int cs = -1;
                try {
                    Object shape = call(st, "getCollisionShape", emptyGetter, zero);
                    String key = shape == shapesBlock ? "full" : (shape == shapesEmpty || bool(call(shape, "isEmpty"))) ? "empty" : boxes(shape);
                    Integer sid = shapeId.get(key);
                    if (sid == null) { sid = shapeObjs.size(); shapeObjs.add(key.equals("full") ? shapesBlock : key.equals("empty") ? shapesEmpty : shape); shapeKey.add(key); shapeId.put(key, sid); }
                    cs = sid;
                } catch (Throwable t) { }
                rows.add(new String[]{"S", String.valueOf(id), name, chain.toString(), b(rtick), b(air), b(solid), b(occl), b(bm), fluid, famount, ffall, b(simpleWl.isInstance(block)), String.valueOf(cs), sf, sc, sr, b(lbcC.isInstance(block)), b(repl), String.valueOf(ld)});
            }
        }
        rows.sort(Comparator.comparingInt(r -> Integer.parseInt(r[1])));
        for (String[] r : rows) out.append(String.join("\t", r)).append('\n');
        for (int i = 0; i < shapeKey.size(); i++) {
            String k = shapeKey.get(i);
            out.append("H\t").append(i).append('\t').append(k.equals("empty") ? 0 : k.equals("full") ? 1 : 2).append('\t').append(k.equals("empty") || k.equals("full") ? "" : k).append('\n');
        }
        for (int i = 0; i < shapeKey.size(); i++) {
            if (shapeKey.get(i).equals("empty") || shapeKey.get(i).equals("full")) continue;
            for (int j = 0; j < shapeKey.size(); j++) {
                if (shapeKey.get(j).equals("empty") || shapeKey.get(j).equals("full")) continue;
                for (int d = 0; d < 6; d++)
                    if (bool(call(shapesC, "mergedFaceOccludes", shapeObjs.get(i), shapeObjs.get(j), dirs[d]))) out.append("O\t").append(i).append('\t').append(j).append('\t').append(d).append('\n');
            }
        }
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
