-- Light engine, part 1: reference data and the tables the engine keeps.  See docs/LIGHT.md.
--
-- mc.light_state / mc.light_face / mc.light_face_occ are DERIVED FROM THE VANILLA JAR (tools/gen_light.sh runs tools/java/LightDump.java, tools/load_light.py loads the
-- result; nothing of Mojang's is committed).  Per block state: BlockState.getLightEmission(), getLightDampening(), whether the state uses its occlusion shape for light
-- (canOcclude && useShapeForLightOcclusion) and the six face shapes LightEngine.getOcclusionShape(state, direction) answers; per pair of face shapes whether
-- Shapes.faceShapeOccludes(a, b) holds.  The engine (sql/222 .. 224) reads only these tables: without them (mc.light_ready() false) mc.compute_light keeps the old
-- straight-down sky model of sql/220 (mc.compute_light_flat).
create table if not exists mc.light_state (
    sid       int primary key,                   -- block state id (ref.block_state.state_id)
    name      text not null,                     -- readable state name (minecraft:oak_stairs[facing=north,...])
    emission  smallint not null,                 -- BlockState.getLightEmission()
    damp      smallint not null,                 -- BlockState.getLightDampening(): only 0, 1 and 15 occur in 26.3
    shaped    boolean not null,                  -- canOcclude && useShapeForLightOcclusion: face shapes below are not all empty
    f_down smallint not null, f_up smallint not null, f_north smallint not null, f_south smallint not null, f_west smallint not null, f_east smallint not null
);
create unique index if not exists light_state_name_key on mc.light_state (name);
create table if not exists mc.light_face (id smallint primary key, kind smallint not null, boxes text not null);                 -- kind 0 empty, 1 full square, 2 other
create table if not exists mc.light_face_occ (a smallint not null, b smallint not null, primary key (a, b));                    -- faceShapeOccludes(a, b)

create or replace function mc.light_ready() returns boolean language sql stable parallel safe as $$
  select exists (select 1 from mc.light_state limit 1) $$;
