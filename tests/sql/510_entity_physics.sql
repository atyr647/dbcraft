-- Entity physics (sql/500-510) against vanilla 26.3's recorded per-tick item trajectories (tools/entity/rcon.py record; free fall, rest, a throw that slides on the ground, a throw into a wall).
-- The recordings are data from Mojang's server and are gitignored: without them the vanilla comparison is skipped with a notice.
\! python3 tools/load_world_ref.py >/dev/null

------------------------------------------------------------------------------------------------ pieces that need no recording
-- LpVec3: bytes of real captured velocities survive decode + encode
select t.eq('lpvec3 captured ' || h, encode(proto.lpvec3(r.x, r.y, r.z), 'hex'), h)
from (values ('f9ff7ffeebed'), ('f928851efffe'), ('5100800afffe'), ('61668ccb4cca'), ('00')) v(h), lateral proto.lpvec3_read(decode(h, 'hex')) r;
select t.eq('lpvec3 zero is one byte', encode(proto.lpvec3(0, 0, 0), 'hex'), '00');
select t.eq('lpvec3 tiny is zero', encode(proto.lpvec3(1e-5, -1e-5, 0), 'hex'), '00');
select t.is_true('lpvec3 large vector (scale needs the continuation VarInt) round trips within the quantisation',
                 (select abs(r.x - 123.0) < 123.0 / 32766 * 2 and abs(r.y + 77.5) < 123.0 / 32766 * 2 from proto.lpvec3_read(proto.lpvec3(123.0, -77.5, 0.25)) r));
select t.is_true('block classes: stone solid, air and water not, ice slippery',
                 (select solid from mc.block_class where name = 'minecraft:stone') and not (select solid from mc.block_class where name = 'minecraft:air')
                 and not (select solid from mc.block_class where name = 'minecraft:water') and (select friction from mc.block_class where name = 'minecraft:ice') > 0.9);

------------------------------------------------------------------------------------------------ the world: a flat default overworld around the origin
delete from mc.entity;
delete from mc.solid_mask;
delete from mc.chunk where dimension = 'minecraft:overworld' and cx between -1 and 2 and cz between -1 and 2;     -- a fresh world around the origin (the test may run twice)
select mc.generate_flat('minecraft:overworld', cx, cz) from generate_series(-1, 2) cx, generate_series(-1, 2) cz;
select mc.entity_build_mask('minecraft:overworld', 0, 0, -4);
select mc.entity_build_mask('minecraft:overworld', 0, 0, 0);
select t.is_true('the flat floor is solid: the section with the grass layer has solid cells',
                 (select solid_cnt > 0 from mc.solid_mask where dimension = 'minecraft:overworld' and cx = 0 and cz = 0 and sy = -4));
select t.eq('the floor section is solid up to y = -61 (bedrock, 2 dirt, grass = 4 layers of 256 cells)', (select solid_cnt::int from mc.solid_mask where dimension = 'minecraft:overworld' and cx = 0 and cz = 0 and sy = -4), 4 * 256);
select t.eq('a section above the floor is all passable', (select solid_cnt::int from mc.solid_mask where dimension = 'minecraft:overworld' and cx = 0 and cz = 0 and sy = 0), 0);
select mc.entity_build_mask('minecraft:overworld', 900, 900, 0);
select t.is_true('a section that does not exist is passable and remembered (ver -1, no solid cells)', (select ver = -1 and solid_cnt = 0 from mc.solid_mask where dimension = 'minecraft:overworld' and cx = 900 and cz = 900 and sy = 0));

------------------------------------------------------------------------------------------------ the vanilla comparison
drop table if exists t.traj;
create table t.traj (name text, tick int, x float8, y float8, z float8, vx float8, vy float8, vz float8, og boolean);
\copy t.traj from program 'python3 tools/entity/traj_to_tsv.py'
select case when exists (select 1 from t.traj) then 'vanilla recordings found: ' || (select count(*) from t.traj) || ' ticks' else 'NOTE: no vanilla entity recordings in tests/fixtures/captured: the comparison with vanilla is SKIPPED (tools/entity/rcon.py record ...)' end as note \gset
\echo :note

-- replay one recording through mc.entity_physics; id_phase = the entity id mod 4 of the recorded entity (it decides when a resting item wakes: (age + id) % 4 = 0)
create or replace function t.replay(p_name text, p_phase int) returns table (tick int, dpos float8, dvel float8, og_ok boolean, processed boolean) language plpgsql as $$
declare r0 t.traj; eid int := 1000 + p_phase; n int; tk record; e mc.entity; item int;
begin
    select protocol_id into item from ref.registry where registry = 'minecraft:entity_type' and name = 'minecraft:item';
    delete from mc.entity;
    select * into r0 from t.traj where name = p_name and t.traj.tick = 0;
    insert into mc.entity (id, uuid, type, type_id, x, y, z, vx, vy, vz, on_ground, born_tick, phys_tick, cx, cz)
    values (eid, gen_random_uuid(), 'minecraft:item', item, r0.x, r0.y, r0.z, r0.vx, r0.vy, r0.vz, r0.og, 0, 0, floor(r0.x / 16)::int, floor(r0.z / 16)::int);
    for tk in select * from t.traj where name = p_name and t.traj.tick > 0 order by t.traj.tick loop
        perform mc.entity_physics(tk.tick);
        select * into e from mc.entity where id = eid;
        tick := tk.tick;
        dpos := greatest(abs(e.x - tk.x), abs(e.y - tk.y), abs(e.z - tk.z));
        processed := e.phys_tick = tk.tick;                               -- sleeping rows are skipped: their velocity is only reconstructed at the next wake tick
        -- below a horizontal speed of ~3e-4 blocks/tick vanilla itself no longer applies the movement (squared length <= 1e-7): the velocity is unobservable and deep sleep zeroes it
        dvel := case when processed and (tk.vx * tk.vx + tk.vz * tk.vz) > 1e-7 then greatest(abs(e.vx - tk.vx), abs(e.vy - tk.vy), abs(e.vz - tk.vz)) else 0 end;
        og_ok := e.on_ground = tk.og;
        return next;
    end loop;
end $$;

select t.is_true('fall: max position deviation vs vanilla over 100 ticks <= 1e-9 (' || coalesce(max(dpos), 0)::text || ')', coalesce(max(dpos), 0) <= 1e-9) from t.replay('fall', 3) where exists (select 1 from t.traj);
select t.is_true('fall: on_ground agrees on every tick', coalesce(bool_and(og_ok), true)) from t.replay('fall', 3) where exists (select 1 from t.traj);
select t.is_true('rest: max position deviation vs vanilla <= 1e-9 (' || coalesce(max(dpos), 0)::text || ')', coalesce(max(dpos), 0) <= 1e-9) from t.replay('rest', 3) where exists (select 1 from t.traj);
select t.is_true('rest: velocity agrees on every processed tick (<= 1e-12)', coalesce(max(dvel), 0) <= 1e-12) from t.replay('rest', 3) where exists (select 1 from t.traj);
select t.is_true('rest: on_ground agrees on every tick', coalesce(bool_and(og_ok), true)) from t.replay('rest', 3) where exists (select 1 from t.traj);
select t.is_true('slide: max position deviation vs vanilla over 120 ticks <= 1e-6 (' || coalesce(max(dpos), 0)::text || ')', coalesce(max(dpos), 0) <= 1e-6) from t.replay('slide', 0) where exists (select 1 from t.traj);
select t.is_true('slide: velocity agrees on every processed tick (<= 1e-6)', coalesce(max(dvel), 0) <= 1e-6) from t.replay('slide', 0) where exists (select 1 from t.traj);
select t.is_true('slide: on_ground agrees on every tick', coalesce(bool_and(og_ok), true)) from t.replay('slide', 0) where exists (select 1 from t.traj);
-- the wall of the 'wall' recording (stone at x = 6, y -60..-58, z -2..8) and the row at z = 12, placed through the real world API
select mc.set_block('minecraft:overworld', 6, y, z, 'minecraft:stone') from generate_series(-60, -58) y, generate_series(-2, 8) z;
select mc.set_block('minecraft:overworld', x, -60, 12, 'minecraft:stone') from generate_series(3, 9) x;
select t.is_true('after set_block the cached mask is stale (older than the chunk version) until the physics step rebuilds it',
                 (select m.ver < c.version from mc.solid_mask m join mc.chunk c on c.dimension = m.dimension and c.cx = m.cx and c.cz = m.cz where m.dimension = 'minecraft:overworld' and m.cx = 0 and m.cz = 0 and m.sy = -4));
select t.is_true('wall: max position deviation vs vanilla <= 1e-9 (' || coalesce(max(dpos), 0)::text || ')', coalesce(max(dpos), 0) <= 1e-9) from t.replay('wall', 0) where exists (select 1 from t.traj);
select t.is_true('wall: velocity agrees on every processed tick (<= 1e-9)', coalesce(max(dvel), 0) <= 1e-9) from t.replay('wall', 0) where exists (select 1 from t.traj);
select t.is_true('wall: on_ground agrees on every tick', coalesce(bool_and(og_ok), true)) from t.replay('wall', 0) where exists (select 1 from t.traj);
select t.is_true('the physics step rebuilt the stale mask: it is current and has the wall in it (1024 floor cells + 27 wall cells + 7 row cells)',
                 (select m.ver = c.version and m.solid_cnt = 1024 + 27 + 7 from mc.solid_mask m join mc.chunk c on c.dimension = m.dimension and c.cx = m.cx and c.cz = m.cz where m.dimension = 'minecraft:overworld' and m.cx = 0 and m.cz = 0 and m.sy = -4));

delete from mc.entity;
