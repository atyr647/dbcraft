-- Entity lanes (sql/541) and the fast mob packets (sql/542): the analytic walk must give the same world as the exact sweep, end when it must, and tell viewers exactly what its state says.
--   A  floor summaries: uniform on a flat chunk, not uniform after a block is placed in it, rebuilt lazily
--   B  a walking mob gets a lane that stops at its chunk border; mc.entity_live follows the closed form
--   C  EQUIVALENCE: the same 60 mobs (cows and chasing zombies, a stone pillar making one chunk non-uniform) run 150 ticks with lanes OFF (the exact sweep) and ON: positions agree to 1e-9
--   D  a block placed in the path of a walking lane: the mob ends its lane and stops at the block, like the exact sweep
--   E  PACKETS: a viewer's reconstruction (appearance + every movement delta of the move packets) equals the delta base the entity state says it was told, exactly
--   F  the fast packet builder equals the chain of small builders on random inputs
\! python3 tools/load_world_ref.py >/dev/null
select mc.block_class_refresh();

create or replace function t.clear() returns void language plpgsql as $$
begin
    delete from mc.entity; delete from mc.entity_lane; delete from mc.play_out; delete from mc.entity_cell_viewer; delete from mc.entity_viewer_cell; delete from mc.player;
    delete from mc.entity_floor; delete from mc.solid_mask;
    -- masks built up front: an entity that sweeps a section without a mask waits one tick (sql/510), which would shift every expectation below by one tick
    perform mc.entity_build_mask('minecraft:overworld', cx, cz, sy) from generate_series(-4, 4) cx, generate_series(-4, 4) cz, generate_series(-4, -1) sy;
end $$;

-- a flat world around the origin and one viewer A at the origin (view distance 3)
select t.clear();
update mc.server_property set value = '3' where key = 'view-distance';
select set_config('dbcraft.entity_spawner', 'off', false);
delete from mc.chunk where dimension = 'minecraft:overworld' and cx between -4 and 4 and cz between -4 and 4;
select mc.generate_flat('minecraft:overworld', cx, cz) from generate_series(-4, 4) cx, generate_series(-4, 4) cz;
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values ('00000000-0000-0000-0000-00000000000a', 'A', 1, 901, 0.5, -60, 0.5, 0, 0, 0);

------------------------------------------------------------------------------------------------ A  floor summaries
select mc.entity_floor_build('minecraft:overworld', 0, 0);
select t.is_true('A: a flat chunk has a uniform floor at the top of the grass (highest solid cell y = -61)',
                 (select top_min = -61 and top_max = -61 from mc.entity_floor where dimension = 'minecraft:overworld' and cx = 0 and cz = 0));
select mc.entity_floor_build('minecraft:overworld', 99, 99);
select t.is_true('A: a chunk that does not exist has no uniform floor', (select top_min is null and top_max is null from mc.entity_floor where dimension = 'minecraft:overworld' and cx = 99 and cz = 99));
select mc.set_block('minecraft:overworld', 20, -60, 5, 'minecraft:stone');                   -- a pillar of height 1 in chunk (1, 0)
select t.is_true('A: changing a block of the chunk drops its summary (the trigger on the section)', not exists (select 1 from mc.entity_floor where dimension = 'minecraft:overworld' and cx = 1 and cz = 0));
select mc.entity_floor_build('minecraft:overworld', 1, 0);
select t.is_true('A: ... and the rebuilt summary says the floor is no longer uniform (top -61 .. -60)',
                 (select top_min = -61 and top_max = -60 from mc.entity_floor where dimension = 'minecraft:overworld' and cx = 1 and cz = 0));

------------------------------------------------------------------------------------------------ B  a lane, its end, the live position
select mc.set_block('minecraft:overworld', 20, -60, 5, 'minecraft:air');             -- remove the pillar of A: the walk below reaches into chunk (1, 0), whose floor must be uniform
select t.clear();
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values ('00000000-0000-0000-0000-00000000000a', 'A', 1, 901, 0.5, -60, 0.5, 0, 0, 0);
-- a cow at x = 12.5 walking +x at 0.125 blocks per tick with 60 ticks of goal: the border of chunk 0 is at x = 16, reached after (16 - 12.5) / 0.125 = 28 ticks
insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, gx, gz, goal_until, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz, yaw)
values (5001, gen_random_uuid(), 'minecraft:cow', mc.entity_type_id('minecraft:cow'), 12.5, -60, 0.5, true, 0, 0, 0, 0, 0.125, 0, 60, 1, 0, 0, round(12.5 * 4096), round(-60 * 4096.0), round(0.5 * 4096), 0);
select mc.entity_tick(1);
select t.is_true('B: the cow walks in a lane', (select lane_until > 0 from mc.entity where id = 5001) and exists (select 1 from mc.entity_lane where id = 5001));
select t.is_true('B: the lane ends one tick before the centre would leave chunk 0 (not at the end of the goal)', (select lane_until from mc.entity where id = 5001) between 27 and 29);
select mc.entity_tick(t) from generate_series(2, 10) t;
select t.is_true('B: mc.entity_live is the closed form: x = 12.5 + 0.125 * (tick - phys_tick) from the row, here 12.5 + 0.125 * 10 = 13.75',
                 (select abs(x - 13.75) < 1e-9 and y = -60 and in_lane from mc.entity_live where id = 5001));
select t.is_true('B: the entity row itself is NOT rewritten while the lane lasts (still the state after the first tick: phys_tick 1, x = 12.625)', (select phys_tick = 1 and abs(x - 12.625) < 1e-9 from mc.entity where id = 5001));
select mc.entity_tick(t) from generate_series(11, 40) t;
select t.is_true('B: after the border the cow is in chunk 1 and walks on (a new lane or the sweep): x = 12.5 + 0.125 * 40 = 17.5',
                 (select abs(l.x - 17.5) < 1e-9 and e.cx = 1 from mc.entity_live l join mc.entity e on e.id = l.id where l.id = 5001));

------------------------------------------------------------------------------------------------ C  equivalence with the exact sweep
select t.clear();
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values ('00000000-0000-0000-0000-00000000000a', 'A', 1, 901, 0.5, -60, 0.5, 0, 0, 0);
select mc.set_block('minecraft:overworld', 20, -60, 5, 'minecraft:stone');           -- the pillar again (t.clear dropped the summaries, not the block)
select setseed(0.41);
create table if not exists t.pop as select * from mc.entity where false;
delete from t.pop;
insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, goal_until, yaw, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz, sent_yaw)
select 6000 + i, gen_random_uuid(), tp, mc.entity_type_id(tp), x, -60, z, true, -floor(random() * 30)::int, 0, floor(x / 16)::int, floor(z / 16)::int, 1 + i % 5, 0, 1,
       floor(x / 16)::int, floor(z / 16)::int, round(x * 4096), round(-60 * 4096.0), round(z * 4096), 0
  from (select i, case when i % 8 = 0 then 'minecraft:zombie' else 'minecraft:cow' end as tp, -40 + random() * 80 as x, -40 + random() * 80 as z from generate_series(1, 60) i) q;
insert into t.pop select * from mc.entity;

create or replace function t.run(p_lanes boolean, p_ticks int) returns void language plpgsql as $$
begin
    perform set_config('dbcraft.entity_lanes', case when p_lanes then 'on' else 'off' end, false);
    delete from mc.entity; delete from mc.entity_lane; delete from mc.play_out;
    insert into mc.entity select * from t.pop;
    for tk in 1..p_ticks loop perform mc.entity_tick(tk); truncate mc.play_out; end loop;
end $$;

select t.run(false, 150);
create table t.off_run as select id, x, y, z, cx, cz, on_ground from mc.entity;
select t.run(true, 150);
select t.is_true('C: lanes were used (most mobs walked in lanes at some time: the lane table is not empty at the end)', (select count(*) from mc.entity_lane) > 10);
select t.eq('C: all 60 mobs are still there in both runs', (select count(*)::int from t.off_run), 60);
select t.eq('C: positions agree with the exact sweep to 1e-9 (x, z), y and the chunk cell exactly, over 150 ticks of wander and chase',
            (select count(*)::int from t.off_run o join mc.entity_live l on l.id = o.id where abs(o.x - l.x) > 1e-9 or abs(o.z - l.z) > 1e-9 or o.y <> l.y or o.on_ground is distinct from l.on_ground), 0);
select t.eq('C: the chunk cell of every mob equals floor(live position / 16) (cells stay exact for lane mobs)',
            (select count(*)::int from mc.entity e join mc.entity_live l on l.id = e.id where e.cx <> floor(l.x / 16)::int or e.cz <> floor(l.z / 16)::int), 0);
select t.is_true('C: mobs standing in the non-uniform chunk (1, 0) never got a lane and still match (checked above); no lane row belongs to a missing entity', not exists (select 1 from mc.entity_lane l where not exists (select 1 from mc.entity e where e.id = l.id)));

------------------------------------------------------------------------------------------------ D  a block in the path
select t.clear();
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values ('00000000-0000-0000-0000-00000000000a', 'A', 1, 901, 0.5, -60, 0.5, 0, 0, 0);
select mc.set_block('minecraft:overworld', 20, -60, 5, 'minecraft:air');                  -- remove the pillar of the test above
select mc.set_block('minecraft:overworld', 3, -60, 0, 'minecraft:air');
create or replace function t.walker(p_lanes boolean) returns table (x float8, z float8, in_lane boolean) language plpgsql as $$
begin
    perform set_config('dbcraft.entity_lanes', case when p_lanes then 'on' else 'off' end, false);
    delete from mc.entity; delete from mc.entity_lane; delete from mc.play_out; delete from mc.entity_floor; delete from mc.solid_mask;
    perform mc.set_block('minecraft:overworld', 3, -60, 0, 'minecraft:air');
    perform mc.entity_build_mask('minecraft:overworld', cx, cz, sy) from generate_series(-4, 4) cx, generate_series(-4, 4) cz, generate_series(-4, -1) sy;
    insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, gx, gz, goal_until, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz, yaw)
    values (5002, gen_random_uuid(), 'minecraft:cow', mc.entity_type_id('minecraft:cow'), 0.5, -60, 0.5, true, 0, 0, 0, 0, 0.1, 0, 90, 1, 0, 0, round(0.5 * 4096), round(-60 * 4096.0), round(0.5 * 4096), 0);
    for tk in 1..10 loop perform mc.entity_tick(tk); end loop;
    perform mc.set_block('minecraft:overworld', 3, -60, 0, 'minecraft:stone');            -- placed in the path while the cow walks (it would reach x = 3 - 0.45 at tick 20)
    for tk in 11..45 loop perform mc.entity_tick(tk); end loop;
    return query select l.x, l.z, l.in_lane from mc.entity_live l where l.id = 5002;
end $$;
create table t.walk_off as select * from t.walker(false);
create table t.walk_on as select * from t.walker(true);
select t.is_true('D: with lanes the cow was in a lane before the block and the sweep decides after it (it stopped at the block: centre x = 3 - 0.45 = 2.55)',
                 (select abs(x - 2.55) < 1e-6 from t.walk_on));
select t.is_true('D: and it ends exactly where the exact sweep ends', (select abs(a.x - b.x) < 1e-9 and abs(a.z - b.z) < 1e-9 from t.walk_on a, t.walk_off b));
select t.is_true('D: it is not in a lane any more (the chunk floor is no longer uniform)', (select not in_lane from t.walk_on));

------------------------------------------------------------------------------------------------ E  the viewer's reconstruction equals the delta base of the state
create or replace function t.moves(b bytea) returns table (eid int, kind text, a bigint, bb bigint, c bigint) language plpgsql as $$
declare o int := 0; o2 int; ln int; pid int; r record; nm text; e int; q int; nx int;
begin
    while o < length(b) loop
        select * into r from proto.varint_read(b, o); ln := r.val; o2 := r.nxt;
        select * into r from proto.varint_read(b, o2); pid := r.val; q := r.nxt;
        nm := replace(net.pkt_name('play', 'clientbound', pid), 'minecraft:', '');
        select * into r from proto.varint_read(b, q); e := r.val; q := r.nxt;
        if nm = 'add_entity' then
            q := q + 16; select * into r from proto.varint_read(b, q); q := r.nxt;              -- uuid, type
            eid := e; kind := 'add'; a := round(proto.f64_read(b, q) * 4096); bb := round(proto.f64_read(b, q + 8) * 4096); c := round(proto.f64_read(b, q + 16) * 4096); return next;
        elsif nm in ('move_entity_pos', 'move_entity_pos_rot') then
            select * into r from proto.varint_read(b, q); q := r.nxt;                           -- flags
            select * into r from proto.varint_read(b, q); q := r.nxt;                           -- ticks
            eid := e; kind := 'move'; a := proto.i16_read(b, q); bb := proto.i16_read(b, q + 2); c := proto.i16_read(b, q + 4); return next;
        elsif nm = 'entity_position_sync' then
            eid := e; kind := 'sync'; return next;
        end if;
        o := o2 + ln;
    end loop;
end $$;

select t.clear();
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values ('00000000-0000-0000-0000-00000000000a', 'A', 1, 901, 0.5, -60, 0.5, 0, 0, 0);
select set_config('dbcraft.entity_lanes', 'on', false);
select setseed(0.77);
-- 40 cows around the viewer, not announced yet: the first tick announces them (appear packets), then they walk
insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, goal_until, yaw)
select 7000 + i, gen_random_uuid(), 'minecraft:cow', mc.entity_type_id('minecraft:cow'), x, -60, z, true, -floor(random() * 30)::int, 0, floor(x / 16)::int, floor(z / 16)::int, 1 + i % 4, 0
  from (select i, -20 + random() * 40 as x, -20 + random() * 40 as z from generate_series(1, 40) i) q;
create table t.stream (tick int, seq bigint generated always as identity, data bytea);
create or replace function t.watch(p_from int, p_to int) returns void language plpgsql as $$
begin
    for tk in p_from..p_to loop
        delete from mc.play_out;
        perform mc.entity_tick(tk);
        insert into t.stream (tick, data) select tk, data from mc.play_out where conn_id = 1 order by seq;
    end loop;
end $$;
select t.watch(1, 120);
-- bring every lane entity's sent state back into the entity rows (what a lane end does), then compare with the packets
select mc.entity_lane_flush_all(121);
create table t.recon as
select m.eid, sum(m.a) filter (where m.kind in ('add', 'move')) as qx, sum(m.c) filter (where m.kind in ('add', 'move')) as qz,
       count(*) filter (where m.kind = 'move') as moves, count(*) filter (where m.kind = 'sync') as syncs
  from t.stream s cross join lateral t.moves(s.data) m group by m.eid;
select t.is_true('E: the viewer received packets for the cows (appearances and many movement packets)', (select count(*) from t.recon) = 40 and (select sum(moves) from t.recon) > 500);
select t.eq('E: for every cow, appearance + the sum of all movement deltas = the quantised position the state says the viewers were told (x, exactly)',
            (select count(*)::int from t.recon r join mc.entity e on e.id = r.eid where r.syncs = 0 and r.qx <> e.sent_qx), 0);
select t.eq('E: ... and z, exactly', (select count(*)::int from t.recon r join mc.entity e on e.id = r.eid where r.syncs = 0 and r.qz <> e.sent_qz), 0);
select t.is_true('E: the told position is at most 3 samples of walking behind the real one (walk speed <= 0.13 blocks per tick: 3 * 0.13 * 4096 = 1600 units), x and z',
                 (select count(*) = 0 from mc.entity e where abs(e.sent_qx - round(e.x * 4096)) > 1600 or abs(e.sent_qz - round(e.z * 4096)) > 1600));

------------------------------------------------------------------------------------------------ F  the fast packet builder
select t.eq('F: mc.epkt_mob_move equals the chain of small builders on 20,000 random inputs', count(*) filter (where new is distinct from old)::int, 0)
from (select mc.epkt_mob_move(e, dx, dy, dz, tk, og, rot, yaw, pitch) as new,
             case when rot then mc.pkt_move_entity_pos_rot(e, dx, dy, dz, tk, yaw, pitch, og) || mc.pkt_rotate_head(e, yaw) else mc.pkt_move_entity_pos(e, dx, dy, dz, tk, og) end as old
        from (select (random() * 3000000)::int e, (random() * 65535 - 32768)::int dx, (random() * 65535 - 32768)::int dy, (random() * 65535 - 32768)::int dz, (random() * 500)::int tk,
                     random() < 0.5 og, random() < 0.5 rot, (random() * 720 - 360)::real yaw, (random() * 180 - 90)::real pitch from generate_series(1, 20000)) q) r;
select t.is_true('F: boundary inputs (entity id 127/128/16383/16384/2097151, ticks 127/128, dx at the short limits) agree too',
                 (select count(*) filter (where mc.epkt_mob_move(e, dx, 0, -dx, tk, true, false, 0, 0) is distinct from mc.pkt_move_entity_pos(e, dx, 0, -dx, tk, true)) = 0
                    from (values (127), (128), (16383), (16384), (2097151)) a(e), (values (32767), (-32768), (0), (1)) b(dx), (values (127), (128), (0)) c(tk)));
