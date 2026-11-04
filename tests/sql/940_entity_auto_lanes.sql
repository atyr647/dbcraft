-- Autonomous entity lanes (sql/940): the lane row is the whole state of a walking or standing mob, tracker steps write nothing, goals are drawn inside the lane, borders are crossed inside it.
--   A  mc.entity_cell_exit against brute force; mc.entity_goal against the AI of mc.entity_ai_ids
--   B  mc.entity_auto_base (the viewers' delta base from the closed form) against a STATEFUL simulation of the steps, on random lanes (walking and standing)
--   C  EQUIVALENCE: the same 60 cows with autonomous lanes ON and OFF (the lanes of sql/541): positions to 1e-9 over 400 ticks, and what the viewer was told (appearance + all deltas) is the same
--   D  a step writes nothing (the lane row keeps its xmin), the entity row is not touched while the lane lasts; the next goal is drawn inside the lane
--   E  a border crossing nobody notices keeps the lane; one that changes who sees the mob ends it and the viewers get exactly remove / appear
--   F  a block placed near a lane ends it (entity row = state of the last tick, delta base of the steps that ran); a gap in the tick numbers re-anchors the lanes: nothing drifts
--   G  a standing mob sends its last position once and nothing after it
\! python3 tools/load_world_ref.py >/dev/null
select mc.block_class_refresh();

------------------------------------------------------------------------------------------------ A
select t.eq('A: mc.entity_cell_exit equals brute force (the first k >= 1 whose position x + g * k is outside the cell) on 3,000 random walks',
            (select count(*)::int from (
               select x, g, cell, mc.entity_cell_exit(x, g, cell) as k,
                      (select min(kk) from generate_series(1, 400) kk where floor((x + g * kk) / 16)::int <> cell) as bf
                 from (select 16 * c + random() * 16 as x, (random() - 0.5) * 0.3 as g, c as cell from generate_series(-5, 5) c, generate_series(1, 273) i) q
                where abs(g) > 0.001) r where r.bf is distinct from r.k and not (r.bf is null and r.k >= 400)), 0);
select t.eq('A: ... and 1000000 for a walk without velocity', mc.entity_cell_exit(5.5, 0, 0), 1000000::bigint);
select t.eq('A: ... a walk that starts on the last representable spot before the border leaves at k = 1', mc.entity_cell_exit(15.99999, 0.1, 0), 1::bigint);

create or replace function t.goal_ai(p_id int, p_tick bigint, p_yaw real) returns table (gx float8, gz float8, goal_until bigint, yaw real) language plpgsql as $$
begin
    delete from mc.entity; delete from mc.entity_lane;
    insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, goal_until, yaw, deep_sleep)
    values (p_id, gen_random_uuid(), 'minecraft:cow', mc.entity_type_id('minecraft:cow'), 0.5, -60, 0.5, true, 0, 0, 0, 0, p_tick, p_yaw, true);
    perform mc.entity_ai_ids(p_tick);
    return query select e.gx, e.gz, e.goal_until, e.yaw from mc.entity e where e.id = p_id;
end $$;
select setseed(0.31);
select t.eq('A: mc.entity_goal draws exactly what the AI of mc.entity_ai_ids draws (gx, gz, goal end, yaw), 300 random (entity, tick, yaw), with walk probability 0.6 and 1.0',
            (select count(*)::int from (select i, tk, w, a.*, g.*
                      from (select (1000 + random() * 100000)::int as i, (1 + random() * 100000)::bigint as tk, (random() * 360)::real as y0, (case when random() < 0.5 then 0.6 else 1.0 end) as w from generate_series(1, 300)) q(i, tk, y0, w)
                      cross join lateral (select set_config('dbcraft.entity_walk_prob', w::text, false)) sc
                      cross join lateral t.goal_ai(i, tk, y0) a
                      cross join lateral mc.entity_goal(i, tk, y0, (select walk_speed from mc.entity_type_param where type = 'minecraft:cow'), w) g0
                      cross join lateral (select g0.gx as ggx, g0.gz as ggz, tk + g0.dur as gu, g0.yaw as gyaw) g(ggx, ggz, gu, gyaw)
                     where a.gx is distinct from g.ggx or a.gz is distinct from g.ggz or a.goal_until is distinct from g.gu or a.yaw is distinct from g.gyaw) d), 0);
select set_config('dbcraft.entity_walk_prob', '0.6', false);

------------------------------------------------------------------------------------------------ B
-- the stateful reference: run every step of a segment one by one and update the base after each (sql/541's rule: the position base moves when the squared delta is >= 128 or on the
-- 60-tick phase, the yaw base when the angle byte changed); steps run at t > t0 with t = slot (mod every) before the segment end, standing segments only at t0 + 1
create or replace function t.sim_base(t0 bigint, every int, slot int, x0 float8, z0 float8, y float8, gx float8, gz float8, yaw real, lend bigint, born bigint, sqx bigint, sqy bigint, sqz bigint, syaw real, last bigint, p_last bigint)
returns table (bx bigint, "by" bigint, bz bigint, byaw real, blast bigint) language plpgsql as $$
declare walking boolean := gx <> 0 or gz <> 0; qx bigint; qy bigint; qz bigint; due boolean;
begin
    bx := sqx; "by" := sqy; bz := sqz; byaw := syaw; blast := last;
    for tk in t0 + 1 .. least(p_last, lend - 1) loop
        due := case when walking then ((tk % every) + every) % every = slot else tk = t0 + 1 end;
        continue when not due;
        qx := mc.quant(x0 + gx * (tk - t0)); qy := mc.quant(y); qz := mc.quant(z0 + gz * (tk - t0));
        if (qx - bx) ^ 2 + (qy - "by") ^ 2 + (qz - bz) ^ 2 >= 128 or (tk - born) % 60 = 0 then bx := qx; "by" := qy; bz := qz; blast := tk; end if;
        if abs(mc.angle_byte(yaw) - mc.angle_byte(byaw)) >= 1 then byaw := yaw; end if;
    end loop;
    return next;
end $$;
select setseed(0.52);
create table t.lanes as
select i, 100 + (random() * 50)::int as t0, 3 as every, floor(random() * 3)::int as slot,
       -100 + random() * 200 as x0, -100 + random() * 200 as z0, -60.0 as y,
       case when i % 4 = 0 then 0.0 else (random() - 0.5) * 0.2 end as gx, case when i % 4 = 0 then 0.0 else (random() - 0.5) * 0.2 end as gz,
       (random() * 360)::real as yaw, (random() * 360)::real as syaw, 150 + (random() * 100)::int as lend, -(random() * 60)::int as born
  from generate_series(1, 2000) i;
update t.lanes set gx = 0.0, gz = 0.0 where abs(gx) < 0.02 and abs(gz) < 0.02 and i % 4 <> 0;
alter table t.lanes add column sqx bigint, add column sqy bigint, add column sqz bigint, add column last bigint;
update t.lanes set sqx = mc.quant(x0) + (random() * 600 - 300)::int, sqy = mc.quant(y), sqz = mc.quant(z0) + (random() * 600 - 300)::int, last = t0 - (random() * 5)::int;
select t.eq('B: the closed-form delta base equals the stateful step-by-step simulation for 2,000 random lanes (a quarter standing) and 6 observation ticks each',
            (select count(*)::int from t.lanes l cross join lateral generate_series(0, 5) k
                cross join lateral mc.entity_auto_base(l.t0, l.every, l.slot, l.x0, l.z0, l.y, l.gx, l.gz, l.yaw, l.lend, l.born, l.sqx, l.sqy, l.sqz, l.syaw, l.last, l.t0 + k * 17) a
                cross join lateral t.sim_base(l.t0, l.every, l.slot, l.x0, l.z0, l.y, l.gx, l.gz, l.yaw, l.lend, l.born, l.sqx, l.sqy, l.sqz, l.syaw, l.last, l.t0 + k * 17) s
               where a.bx is distinct from s.bx or a."by" is distinct from s."by" or a.bz is distinct from s.bz or a.byaw is distinct from s.byaw or a.blast is distinct from s.blast), 0);
select t.is_true('B: ... the sample contained lanes where steps had run and lanes where none had (so the comparison means something)',
                 (select count(*) filter (where a.blast is distinct from l.last) > 3000 and count(*) filter (where a.blast is not distinct from l.last) > 300 from t.lanes l cross join lateral generate_series(0, 5) k
                    cross join lateral mc.entity_auto_base(l.t0, l.every, l.slot, l.x0, l.z0, l.y, l.gx, l.gz, l.yaw, l.lend, l.born, l.sqx, l.sqy, l.sqz, l.syaw, l.last, l.t0 + k * 17) a));

------------------------------------------------------------------------------------------------ world for C..G
create or replace function t.clear() returns void language plpgsql as $$
begin
    delete from mc.entity; delete from mc.entity_lane; delete from mc.play_out; delete from mc.entity_cell_viewer; delete from mc.entity_viewer_cell; delete from mc.player;
    delete from mc.entity_floor; delete from mc.solid_mask;
    perform mc.entity_build_mask('minecraft:overworld', cx, cz, sy) from generate_series(-6, 6) cx, generate_series(-6, 6) cz, generate_series(-4, -1) sy;
    update mc.entity_clock set last_tick = null;
end $$;
select set_config('dbcraft.entity_spawner', 'off', false);
select set_config('dbcraft.entity_auto', 'on', false);
update mc.server_property set value = '3' where key = 'view-distance';
delete from mc.chunk where dimension = 'minecraft:overworld' and cx between -6 and 6 and cz between -6 and 6;
select mc.generate_flat('minecraft:overworld', cx, cz) from generate_series(-6, 6) cx, generate_series(-6, 6) cz;

-- decode the movement packets of a viewer stream
create or replace function t.moves(b bytea) returns table (eid int, kind text, a bigint, bb bigint, c bigint) language plpgsql as $$
declare o int := 0; o2 int; ln int; pid int; r record; nm text; e int; q int;
begin
    while o < length(b) loop
        select * into r from proto.varint_read(b, o); ln := r.val; o2 := r.nxt;
        select * into r from proto.varint_read(b, o2); pid := r.val; q := r.nxt;
        nm := replace(net.pkt_name('play', 'clientbound', pid), 'minecraft:', '');
        select * into r from proto.varint_read(b, q); e := r.val; q := r.nxt;
        if nm = 'add_entity' then
            q := q + 16; select * into r from proto.varint_read(b, q); q := r.nxt;
            eid := e; kind := 'add'; a := round(proto.f64_read(b, q) * 4096); bb := round(proto.f64_read(b, q + 8) * 4096); c := round(proto.f64_read(b, q + 16) * 4096); return next;
        elsif nm in ('move_entity_pos', 'move_entity_pos_rot') then
            select * into r from proto.varint_read(b, q); q := r.nxt;
            select * into r from proto.varint_read(b, q); q := r.nxt;
            eid := e; kind := 'move'; a := proto.i16_read(b, q); bb := proto.i16_read(b, q + 2); c := proto.i16_read(b, q + 4); return next;
        elsif nm = 'entity_position_sync' then
            -- [entity][LpVec3 velocity][x y z doubles]...: position as doubles
            declare l record; begin
                select * into l from proto.lpvec3_read(b, q);
                eid := e; kind := 'sync'; a := round(proto.f64_read(b, l.nxt) * 4096); bb := round(proto.f64_read(b, l.nxt + 8) * 4096); c := round(proto.f64_read(b, l.nxt + 16) * 4096); return next;
            end;
        elsif nm = 'remove_entities' then
            select * into r from proto.varint_read(b, q); eid := r.val; kind := 'remove'; return next;          -- [count][id ...]: the first id
        end if;
        o := o2 + ln;
    end loop;
end $$;
create table t.stream (mode text, tick int, seq bigint generated always as identity, data bytea);

-- 60 cows around a viewer at the origin; deterministic ids, uuids and positions
create or replace function t.run(p_mode text, p_ticks int) returns void language plpgsql as $$
begin
    perform t.clear();
    perform set_config('dbcraft.entity_auto', p_mode, false);
    perform setseed(0.5);
    insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values ('00000000-0000-0000-0000-00000000000a', 'A', 1, 901, 0.5, -60, 0.5, 0, 0, 0);
    insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, goal_until, yaw)
    select 7000 + i, md5(i::text)::uuid, 'minecraft:cow', mc.entity_type_id('minecraft:cow'), x, -60, z, true, -floor(random() * 30)::int, 0, floor(x / 16)::int, floor(z / 16)::int, 1 + i % 4, 0
      from (select i, -30 + random() * 60 as x, -30 + random() * 60 as z from generate_series(1, 60) i) q;
    perform mc.entity_floor_build('minecraft:overworld', cx, cz) from generate_series(-6, 6) cx, generate_series(-6, 6) cz;
    for tk in 1..p_ticks loop
        delete from mc.play_out;
        perform mc.entity_tick(tk);
        insert into t.stream (mode, tick, data) select p_mode, tk, data from mc.play_out where conn_id = 1 order by seq;
    end loop;
end $$;

------------------------------------------------------------------------------------------------ C
select t.run('off', 400);
create table t.live_off as select id, x, z from mc.entity_live;
select t.run('on', 400);
create table t.live_on as select id, x, z from mc.entity_live;
select t.is_true('C: autonomous lanes were used (all 60 cows have an autonomous lane at the end of the run)', (select count(*) = 60 from mc.entity_lane where auto));
select mc.entity_lane_flush_all(401);
select t.eq('C: all 60 cows are still there in both runs', (select count(*)::int from t.live_off o join t.live_on n using (id)), 60);
select t.eq('C: positions agree between autonomous lanes and the lanes of sql/541 to 1e-9 (x, z) after 400 ticks of wander (many goals and chunk borders)',
            (select count(*)::int from t.live_off o join t.live_on n using (id) where abs(o.x - n.x) > 1e-9 or abs(o.z - n.z) > 1e-9), 0);
create table t.recon as
select s.mode, m.eid, sum(m.a) filter (where m.kind in ('add', 'move')) as qx, sum(m.c) filter (where m.kind in ('add', 'move')) as qz, count(*) filter (where m.kind = 'sync') as syncs, count(*) filter (where m.kind = 'move') as moves
  from t.stream s cross join lateral t.moves(s.data) m group by s.mode, m.eid;
select t.is_true('C: the viewer got movement packets for every cow in both runs', (select count(*) = 60 and min(moves) >= 1 and sum(moves) > 1000 from t.recon where mode = 'on') and (select count(*) = 60 from t.recon where mode = 'off'));
select t.eq('C: the viewer''s reconstruction (appearance + all deltas) of every cow equals EXACTLY the delta base the entity row holds once the lanes have ended (mc.entity_lane_flush_all: the base comes from the closed form), cows without a position sync',
            (select count(*)::int from t.recon r join (select e.id, e.sent_qx, e.sent_qz from mc.entity e) e on e.id = r.eid where r.mode = 'on' and r.syncs = 0 and (r.qx <> e.sent_qx or r.qz <> e.sent_qz)), 0);
select t.is_true('C: ... and with and without autonomous lanes the told positions are the same up to the packets in flight when the run stops (a step of the other run that has not happened yet: three walking steps, 1600 units)',
                 (select count(*) = 0 from t.recon a join t.recon b on a.eid = b.eid and a.mode = 'on' and b.mode = 'off' where a.syncs = 0 and b.syncs = 0 and (abs(a.qx - b.qx) > 1600 or abs(a.qz - b.qz) > 1600)));
select t.is_true('C: ... and within one quantisation step of the real position the viewer sees in the end (the told position is at most three walking steps behind: 1600 units)',
                 (select count(*) = 0 from t.recon r join t.live_on l on l.id = r.eid where r.mode = 'on' and r.syncs = 0 and (abs(r.qx - round(l.x * 4096)) > 1600 or abs(r.qz - round(l.z * 4096)) > 1600)));
select t.is_true('C: autonomous lanes send about as many movement packets as the lanes they replace (a border crossing is no tracker event of its own: a little fewer, never more than 10 % apart)',
                 (select abs(a.n - b.n)::float8 / b.n < 0.10 from (select sum(moves) as n from t.recon where mode = 'on') a, (select sum(moves) as n from t.recon where mode = 'off') b));

------------------------------------------------------------------------------------------------ D  a step writes nothing
select t.clear();
select set_config('dbcraft.entity_auto', 'on', false);
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values ('00000000-0000-0000-0000-00000000000a', 'A', 1, 901, 0.5, -60, 0.5, 0, 0, 0);
select mc.entity_floor_build('minecraft:overworld', cx, cz) from generate_series(-6, 6) cx, generate_series(-6, 6) cz;
-- a cow at x = 2.5 walking +x at 0.05 with a goal of 80 ticks (it stays inside chunk 0 until x = 16: 270 ticks away)
insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, gx, gz, goal_until, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz, yaw)
values (5201, gen_random_uuid(), 'minecraft:cow', mc.entity_type_id('minecraft:cow'), 2.5, -60, 8.5, true, 0, 0, 0, 0, 0.05, 0, 80, 1, 0, 0, round(2.5 * 4096), round(-60 * 4096.0), round(8.5 * 4096), 0);
select mc.entity_tick(t) from generate_series(1, 4) t;
select t.is_true('D: the cow walks in an autonomous lane and its entity row is marked (lane_until, and out of the goal scan of the AI)',
                 (select l.auto and e.lane_until = 9223372036854775807 and e.goal_until = 9223372036854775807 from mc.entity e join mc.entity_lane l on l.id = e.id where e.id = 5201));
create temp table _x0 as select l.xmin::text as lxmin, e.xmin::text as exmin, l.t0 from mc.entity_lane l join mc.entity e on e.id = l.id where e.id = 5201;
select mc.entity_tick(t) from generate_series(5, 30) t;
select t.is_true('D: 26 ticks later (nine tracker steps) neither the lane row nor the entity row has been written: same xmin',
                 (select l.xmin::text = x.lxmin and e.xmin::text = x.exmin from mc.entity_lane l join mc.entity e on e.id = l.id, _x0 x where e.id = 5201));
select t.is_true('D: ... and the live position is the closed form of the lane: x = 2.5 + 0.05 * (tick - anchor)',
                 (select abs(v.x - (l.x0 + 0.05 * (30 - l.t0))) < 1e-9 from mc.entity_live v join mc.entity_lane l on l.id = v.id where v.id = 5201));
select mc.entity_tick(t) from generate_series(31, 100) t;
select t.is_true('D: after the goal ended (tick 80) the cow got its next goal inside the lane: the lane row carries a goal that ends after tick 100 (a new segment), the entity row is still the anchor',
                 (select l.gend > 80 and l.t0 >= 79 and e.phys_tick < 5 from mc.entity_lane l join mc.entity e on e.id = l.id where e.id = 5201));

------------------------------------------------------------------------------------------------ E  borders
-- E1: one viewer who sees both cells: the cow crosses from chunk 0 to chunk 1 inside the lane
select t.clear();
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values ('00000000-0000-0000-0000-00000000000a', 'A', 1, 901, 0.5, -60, 0.5, 0, 0, 0);
select mc.entity_floor_build('minecraft:overworld', cx, cz) from generate_series(-6, 6) cx, generate_series(-6, 6) cz;
insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, gx, gz, goal_until, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz, yaw)
values (5301, gen_random_uuid(), 'minecraft:cow', mc.entity_type_id('minecraft:cow'), 15.0, -60, 8.5, true, 0, 0, 0, 0, 0.1, 0, 60, 1, 0, 0, round(15.0 * 4096), round(-60 * 4096.0), round(8.5 * 4096), 0);
select mc.entity_tick(t) from generate_series(1, 10) t;
select t.is_true('E1: after the border (x = 16 at tick 10) the cow is in chunk 1 in the entity row AND in the lane, still in an autonomous lane, the entity row says chunk 1 for the viewers tables',
                 (select e.cx = 1 and l.cx = 1 and l.auto and e.sent_cx = 1 from mc.entity e join mc.entity_lane l on l.id = e.id where e.id = 5301));
-- E2: the viewer stands where he loses the cow when it crosses (view distance 3: chunk -3 sees chunks -6..0): the lane ends and the exact sweep + tracker send the removal
select t.clear();
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values ('00000000-0000-0000-0000-00000000000b', 'B', 2, 902, -3 * 16 + 0.5, -60, 8.5, -3, 0, 0);
select mc.entity_floor_build('minecraft:overworld', cx, cz) from generate_series(-6, 6) cx, generate_series(-6, 6) cz;
insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, gx, gz, goal_until, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz, yaw)
values (5302, gen_random_uuid(), 'minecraft:cow', mc.entity_type_id('minecraft:cow'), -0.5, -60, 8.5, true, 0, 0, -1, 0, 0.1, 0, 60, 1, -1, 0, round(-0.5 * 4096), round(-60 * 4096.0), round(8.5 * 4096), 0);
-- chunk -1 is within 2 chunks of B (chunk -3), chunk 0 within 3: both visible with view distance 3.  Move B one chunk further out: -4 sees -7..-1, not chunk 0
update mc.player set chunk_x = -4, x = -4 * 16 + 0.5 where conn_id = 2;
select mc.entity_viewers_refresh(1);
delete from mc.play_out;
create table t.e2 (tick int, seq bigint, data bytea);
create or replace function t.watch2(p_from int, p_to int) returns void language plpgsql as $$
begin for tk in p_from..p_to loop delete from mc.play_out; perform mc.entity_tick(tk); insert into t.e2 select tk, seq, data from mc.play_out where conn_id = 2 order by seq; end loop; end $$;
select t.watch2(1, 12);
select t.is_true('E2: the viewer who loses the cow at the border gets exactly one remove_entities for it (the cow crosses x = 0 at tick 5 or 6)',
                 (select count(*) = 1 from t.e2 e cross join lateral t.moves(e.data) m where m.kind = 'remove' and m.eid = 5302));
select t.is_true('E2: ... and no movement packet for it after the removal', (select not exists (select 1 from t.e2 e cross join lateral t.moves(e.data) m where m.kind = 'move' and m.eid = 5302 and e.tick > (select min(e2.tick) from t.e2 e2 cross join lateral t.moves(e2.data) m2 where m2.kind = 'remove'))));

------------------------------------------------------------------------------------------------ F  block events and gaps
select t.clear();
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values ('00000000-0000-0000-0000-00000000000a', 'A', 1, 901, 0.5, -60, 0.5, 0, 0, 0);
select mc.entity_floor_build('minecraft:overworld', cx, cz) from generate_series(-6, 6) cx, generate_series(-6, 6) cz;
insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, gx, gz, goal_until, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz, yaw)
values (5401, gen_random_uuid(), 'minecraft:cow', mc.entity_type_id('minecraft:cow'), 2.5, -60, 8.5, true, 0, 0, 0, 0, 0.1, 0, 120, 1, 0, 0, round(2.5 * 4096), round(-60 * 4096.0), round(8.5 * 4096), 0);
select mc.entity_tick(t) from generate_series(1, 20) t;
select t.is_true('F: the cow walks in an autonomous lane at tick 20', exists (select 1 from mc.entity_lane where id = 5401 and auto));
select mc.set_block('minecraft:overworld', 12, -60, 8, 'minecraft:stone');            -- in the cow's path, in the same chunk
select t.is_true('F: a block placed near the lane ended it: no lane row, the entity row is the state after the last entity tick (x = 2.5 + 0.1 * 19... phys_tick 20 at the anchor of that tick)',
                 (select not exists (select 1 from mc.entity_lane where id = 5401) and e.lane_until = 0 and e.phys_tick = 20 and abs(e.x - (2.5 + 0.1 * 20)) < 1e-9 from mc.entity e where e.id = 5401));
select t.is_true('F: ... its goal is back in the entity row (the AI scan sees it again) and the viewers delta base is the position of the last tracker step (tick 18: x = 2.5 + 0.1 * 18)',
                 (select e.goal_until = 120 and e.sent_qx = mc.quant(2.5 + 0.1 * 18) and e.last_sent_tick = 18 from mc.entity e where e.id = 5401));
select mc.entity_tick(t) from generate_series(21, 110) t;
select t.is_true('F: the cow stops at the stone (x = 12 - 0.45) like the exact sweep', (select abs(v.x - 11.55) < 1e-6 from mc.entity_live v where v.id = 5401));
select mc.set_block('minecraft:overworld', 12, -60, 8, 'minecraft:air');

-- a gap in the tick numbers (the entity connection jumped from 30 to 60): lanes are re-anchored, nothing drifts
select t.clear();
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values ('00000000-0000-0000-0000-00000000000a', 'A', 1, 901, 0.5, -60, 0.5, 0, 0, 0);
select mc.entity_floor_build('minecraft:overworld', cx, cz) from generate_series(-6, 6) cx, generate_series(-6, 6) cz;
insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, gx, gz, goal_until, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz, yaw)
values (5501, gen_random_uuid(), 'minecraft:cow', mc.entity_type_id('minecraft:cow'), 2.5, -60, 8.5, true, 0, 0, 0, 0, 0.05, 0, 400, 1, 0, 0, round(2.5 * 4096), round(-60 * 4096.0), round(8.5 * 4096), 0);
create table t.gap (tick int, seq bigint, data bytea);
create or replace function t.watch3(p_from int, p_to int) returns void language plpgsql as $$
begin for tk in p_from..p_to loop delete from mc.play_out; perform mc.entity_tick(tk); insert into t.gap select tk, seq, data from mc.play_out where conn_id = 1 order by seq; end loop; end $$;
select t.watch3(1, 30);
select t.watch3(61, 120);
select t.is_true('F: after the gap the lane was re-anchored (its anchor tick is the last tick that ran, 30, or a later segment) and the cow has moved by the closed form',
                 (select l.auto and l.t0 >= 30 and abs(v.x - (2.5 + 0.05 * 120)) < 1e-6 from mc.entity_lane l join mc.entity_live v on v.id = l.id where l.id = 5501));
create table t.gap_recon as
select sum(m.a) filter (where m.kind in ('add', 'move')) as qx from t.gap g cross join lateral t.moves(g.data) m where m.eid = 5501;
select t.is_true('F: what the viewer was told after the gap is the position of the last step before it plus the later deltas: within one step of the real position (no drift from the missing steps)',
                 (select abs(r.qx - round(v.x * 4096)) <= 3 * 0.05 * 4096 + 2 from t.gap_recon r, mc.entity_live v where v.id = 5501));

------------------------------------------------------------------------------------------------ G  standing
select t.clear();
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values ('00000000-0000-0000-0000-00000000000a', 'A', 1, 901, 0.5, -60, 0.5, 0, 0, 0);
select mc.entity_floor_build('minecraft:overworld', cx, cz) from generate_series(-6, 6) cx, generate_series(-6, 6) cz;
select set_config('dbcraft.entity_walk_prob', '0', false);          -- every new goal is a pause
insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, gx, gz, goal_until, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz, yaw)
values (5601, gen_random_uuid(), 'minecraft:cow', mc.entity_type_id('minecraft:cow'), 2.5, -60, 8.5, true, 0, 0, 0, 0, 0.1, 0, 30, 1, 0, 0, round(2.5 * 4096), round(-60 * 4096.0), round(8.5 * 4096), 0);
create table t.stand (tick int, seq bigint, data bytea);
create or replace function t.watch4(p_from int, p_to int) returns void language plpgsql as $$
begin for tk in p_from..p_to loop delete from mc.play_out; perform mc.entity_tick(tk); insert into t.stand select tk, seq, data from mc.play_out where conn_id = 1 order by seq; end loop; end $$;
select t.watch4(1, 200);
select t.is_true('G: the cow walked for 30 ticks (it moved) and then stood: it is in a lane with velocity 0', (select l.auto and l.gx = 0 and l.gz = 0 from mc.entity_lane l where l.id = 5601));
select t.is_true('G: the viewer got the walk (movement packets until tick 30) and, after the last goal change, no packet that moves it up to tick 200',
                 (select count(*) filter (where s.tick <= 36 and m.kind = 'move') >= 5 and count(*) filter (where s.tick > 36 and m.kind = 'move' and (m.a <> 0 or m.bb <> 0 or m.c <> 0)) = 0 from t.stand s cross join lateral t.moves(s.data) m where m.eid = 5601));
select t.is_true('G: ... and the told position is the real one (the last look delivered the end of the walk): exactly, to one quantisation step',
                 (select abs(r.q - round(v.x * 4096)) <= 1 from (select sum(m.a) filter (where m.kind in ('add', 'move')) as q from t.stand s cross join lateral t.moves(s.data) m where m.eid = 5601) r, mc.entity_live v where v.id = 5601));
select set_config('dbcraft.entity_walk_prob', '0.6', false);

------------------------------------------------------------------------------------------------ H  switching off
select t.clear();
select set_config('dbcraft.entity_auto', 'off', false);
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values ('00000000-0000-0000-0000-00000000000a', 'A', 1, 901, 0.5, -60, 0.5, 0, 0, 0);
select mc.entity_floor_build('minecraft:overworld', cx, cz) from generate_series(-6, 6) cx, generate_series(-6, 6) cz;
insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, gx, gz, goal_until, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz, yaw)
values (5701, gen_random_uuid(), 'minecraft:cow', mc.entity_type_id('minecraft:cow'), 2.5, -60, 8.5, true, 0, 0, 0, 0, 0.05, 0, 400, 1, 0, 0, round(2.5 * 4096), round(-60 * 4096.0), round(8.5 * 4096), 0);
select mc.entity_tick(t) from generate_series(1, 10) t;
select t.is_true('H: with dbcraft.entity_auto = off the cow walks in a lane of sql/541 (auto = false) and the entity row carries its goal', (select not l.auto and e.goal_until = 400 from mc.entity_lane l join mc.entity e on e.id = l.id where e.id = 5701));
select set_config('dbcraft.entity_auto', 'on', false);

------------------------------------------------------------------------------------------------ L  lazy lanes: replay in closed form = tick-by-tick simulation
-- 400 cows in cells 1..4, the viewer far away at chunk (-6, -6) (view distance 3: nothing within 4 chunks of him is lazy, the cows are 6 or more away).  Run A: dbcraft.entity_lazy = off (every
-- lane simulated every tick); run B: lazy lanes (replayed in their slot, every 32nd tick).  After the same ticks, B's lanes are caught up to the last tick: every lane row must be the same, bit
-- for bit.  The cows are born at tick 100000 minus up to 29 and the runs are shorter than 370 ticks: no cow reaches tick - born = 400, the position sync that ends a lane in the tick-by-tick run
-- (the tracker needs an absolute packet; a lane nobody watches needs none, and it also keeps the tick of the sweep that follows an ended lane out of the comparison).
select set_config('dbcraft.entity_walk_prob', '0.6', false);
-- a bigger flat world than C..G need: a lane that reaches the edge of the known floor ends in the exact sweep, and that happens at the tick it expired in one run but only when the lazy lane is
-- replayed (up to 31 ticks later) in the other: the comparison below is about lanes that stay on a floor
select mc.generate_flat('minecraft:overworld', a.cx, b.cz) from generate_series(-6, 12) a(cx), generate_series(-6, 12) b(cz)
 where not exists (select 1 from mc.chunk c where c.dimension = 'minecraft:overworld' and c.cx = a.cx and c.cz = b.cz);
create or replace function t.lz_setup(p_lazy text, p_n int) returns void language plpgsql as $$
begin
    -- (t.clear rebuilds 676 masks: 25 seconds; the world is flat and untouched here)
    delete from mc.entity; delete from mc.entity_lane; delete from mc.play_out; delete from mc.entity_cell_viewer; delete from mc.entity_viewer_cell; delete from mc.player; delete from mc.entity_tick_log;
    update mc.entity_clock set last_tick = null;
    perform set_config('dbcraft.entity_auto', 'on', false);
    perform set_config('dbcraft.entity_lazy', p_lazy, false);
    perform setseed(0.77);
    insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values ('00000000-0000-0000-0000-00000000000a', 'A', 1, 901, -6 * 16 + 0.5, -60, -6 * 16 + 0.5, -6, -6, 0);
    insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, goal_until, yaw, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz)
    select 8000 + i, md5(i::text)::uuid, 'minecraft:cow', mc.entity_type_id('minecraft:cow'), x, -60, z, true, 100000 - floor(random() * 30)::int, 0, floor(x / 16)::int, floor(z / 16)::int, 1 + i % 9, (random() * 360)::real,
           1, floor(x / 16)::int, floor(z / 16)::int, round(x * 4096), round(-60 * 4096.0), round(z * 4096)
      from (select i, 24 + random() * 48 as x, 24 + random() * 48 as z from generate_series(1, p_n) i) q;
    perform mc.entity_floor_build('minecraft:overworld', cx, cz) from generate_series(-6, 12) cx, generate_series(-6, 12) cz;
end $$;
create or replace function t.lz_run(p_from int, p_to int) returns void language plpgsql as $$
begin for tk in p_from..p_to loop delete from mc.play_out; perform mc.entity_tick(tk); end loop; end $$;
create or replace function t.lz_snap(p_name text, p_tick bigint) returns void language plpgsql as $$
begin
    perform mc.entity_auto_catchup(p_tick, array(select id from mc.entity_lane));
    execute format('create table t.%I as select l.id, l.t0, l.x0, l.z0, l.y, l.gx, l.gz, l.gend, l.goal_until, l.yaw, l.cx, l.cz, l.sqx, l.sqy, l.sqz, l.syaw, l.last_tick, e.cx as ecx, e.cz as ecz from mc.entity_lane l join mc.entity e on e.id = l.id where l.auto', p_name);
end $$;
select t.lz_setup('off', 400);
select t.lz_run(1, 353);
select t.is_true('L: A (every lane simulated every tick): all 400 cows are in autonomous lanes, none lazy', (select count(*) = 400 and count(*) filter (where lazy) = 0 from mc.entity_lane where auto));
select t.lz_snap('lz_a', 353);
select t.lz_setup('on', 400);
select t.lz_run(1, 353);
select t.is_true('L: B: nearly all 400 cows are in lazy lanes (nobody is within reach of the viewer)', (select count(*) = 400 and count(*) filter (where lazy) >= 390 from mc.entity_lane where auto));
select t.is_true('L: ... lazy lanes are behind between their slots: some lanes have an expired segment at tick 353 (so the comparison below needs the replay)',
                 (select count(*) > 20 from mc.entity_lane where auto and goal_until <= 353));
select t.is_true('L: ... and no tracker step was computed for a lane nobody watches after the first ticks (the tick log counts none; the tests below show the steps that do run when somebody is near)', (select coalesce(sum(awake), 0) = 0 from mc.entity_tick_log where tick > 100));
select t.lz_snap('lz_b', 353);
select t.eq('L: after the catch-up to tick 353 all 400 lane rows are the same as in the tick-by-tick run: anchor, velocity, goal, cell, the viewers'' base, to the last bit (about 7 goals each)',
            (select count(*)::int from t.lz_a a join t.lz_b b using (id) where (a.t0, a.x0, a.z0, a.y, a.gx, a.gz, a.gend, a.goal_until, a.yaw, a.cx, a.cz, a.sqx, a.sqy, a.sqz, a.syaw, a.last_tick, a.ecx, a.ecz)
                                                                              is distinct from (b.t0, b.x0, b.z0, b.y, b.gx, b.gz, b.gend, b.goal_until, b.yaw, b.cx, b.cz, b.sqx, b.sqy, b.sqz, b.syaw, b.last_tick, b.ecx, b.ecz)), 0);
select t.eq('L: ... both runs have all 400 lanes', (select count(*)::int from t.lz_a a join t.lz_b b using (id)), 400);
select t.is_true('L: ... and the lanes really moved (gend far beyond the start for nearly all)', (select count(*) > 380 from t.lz_a where gend > 250));

-- M: a viewer teleports next to the lazy cows; everything he is told must be the same as in the tick-by-tick run (appearance with the delta base, and every packet afterwards)
create or replace function t.lz_view(p_mode text, p_name text) returns void language plpgsql as $$
begin
    perform t.lz_setup(p_mode, 400);
    perform t.lz_run(1, 200);
    update mc.player set chunk_x = 2, chunk_z = 2, x = 2 * 16 + 0.5, z = 2 * 16 + 0.5 where conn_id = 1;
    for tk in 201..320 loop
        delete from mc.play_out; perform mc.entity_tick(tk);
        insert into t.stream (mode, tick, data) select p_name, tk, data from mc.play_out where conn_id = 1 order by seq;
    end loop;
end $$;
select t.lz_view('off', 'view_a');
select t.lz_view('on', 'view_b');
create table t.lz_pk as
select s.mode, s.tick, m.eid, m.kind, m.a, m.bb, m.c from t.stream s cross join lateral t.moves(s.data) m where s.mode in ('view_a', 'view_b');
select t.is_true('L: the viewer got appearances and movements in both runs (more than 2,000 packets)', (select count(*) > 2000 from t.lz_pk where mode = 'view_a') and (select count(*) > 2000 from t.lz_pk where mode = 'view_b'));
select t.eq('L: ... and the two streams are the same, packet for packet (tick, cow, kind, values), 120 ticks after the teleport',
            (select count(*)::int from ((select tick, eid, kind, a, bb, c from t.lz_pk where mode = 'view_a' except select tick, eid, kind, a, bb, c from t.lz_pk where mode = 'view_b')
                                        union all (select tick, eid, kind, a, bb, c from t.lz_pk where mode = 'view_b' except select tick, eid, kind, a, bb, c from t.lz_pk where mode = 'view_a')) d), 0);
select t.is_true('L: ... the cows near the viewer are not lazy afterwards (they are simulated every tick while he is there)', (select count(*) filter (where lazy and abs(cx - 2) <= 5 and abs(cz - 2) <= 5) = 0 from mc.entity_lane where auto));

-- M2: a viewer who walks up (one chunk every 8 ticks) gets the same stream as well
create or replace function t.lz_walk(p_mode text, p_name text) returns void language plpgsql as $$
begin
    perform t.lz_setup(p_mode, 400);
    perform t.lz_run(1, 100);
    for tk in 101..300 loop
        if (tk - 101) % 8 = 0 and (tk - 101) / 8 < 8 then
            update mc.player set chunk_x = -6 + ((tk - 101) / 8 + 1), chunk_z = -6 + ((tk - 101) / 8 + 1), x = (-6 + ((tk - 101) / 8 + 1)) * 16 + 0.5, z = (-6 + ((tk - 101) / 8 + 1)) * 16 + 0.5 where conn_id = 1;
        end if;
        delete from mc.play_out; perform mc.entity_tick(tk);
        insert into t.stream (mode, tick, data) select p_name, tk, data from mc.play_out where conn_id = 1 order by seq;
    end loop;
end $$;
select t.lz_walk('off', 'walk_a');
select t.lz_walk('on', 'walk_b');
create table t.lz_pk2 as
select s.mode, s.tick, m.eid, m.kind, m.a, m.bb, m.c from t.stream s cross join lateral t.moves(s.data) m where s.mode in ('walk_a', 'walk_b');
select t.is_true('L: the walking viewer got packets in both runs', (select count(*) > 1000 from t.lz_pk2 where mode = 'walk_a') and (select count(*) > 1000 from t.lz_pk2 where mode = 'walk_b'));
select t.eq('L: ... and the two streams are the same, packet for packet',
            (select count(*)::int from ((select tick, eid, kind, a, bb, c from t.lz_pk2 where mode = 'walk_a' except select tick, eid, kind, a, bb, c from t.lz_pk2 where mode = 'walk_b')
                                        union all (select tick, eid, kind, a, bb, c from t.lz_pk2 where mode = 'walk_b' except select tick, eid, kind, a, bb, c from t.lz_pk2 where mode = 'walk_a')) d), 0);

-- N: a block placed on the spot of a lane that is behind: the lane is replayed against the floor as it was, then ends exactly where the tick-by-tick run ends it
create or replace function t.lz_block(p_mode text, p_name text, p_x int, p_z int) returns void language plpgsql as $$
begin
    perform t.lz_setup(p_mode, 400);
    perform t.lz_run(1, 353);
    perform mc.set_block('minecraft:overworld', p_x, -60, p_z, 'minecraft:stone');
    perform t.lz_run(354, 360);
    perform mc.entity_auto_catchup(360, array(select id from mc.entity_lane));          -- (the entity rows of lanes that are not behind carry their cell again)
    execute format('create table t.%I as select e.id, e.x, e.z, e.phys_tick, e.lane_until, e.goal_until, e.gx, e.gz, e.yaw, e.sent_qx, e.sent_qz, e.last_sent_tick, e.cx, e.cz from mc.entity e', p_name);
    perform mc.set_block('minecraft:overworld', p_x, -60, p_z, 'minecraft:air');          -- (the next run starts in the same flat world)
end $$;
select t.lz_setup('on', 400);
select t.lz_run(1, 353);
create table t.lz_pick as select id, floor(x0)::int as bx, floor(z0)::int as bz from mc.entity_lane where auto and goal_until <= 353 order by id limit 1;
select t.is_true('L: a lane that is behind at tick 353 was found for the block', (select count(*) = 1 from t.lz_pick));
select t.lz_block('off', 'lz_blk_a', (select bx from t.lz_pick), (select bz from t.lz_pick));
select t.lz_block('on', 'lz_blk_b', (select bx from t.lz_pick), (select bz from t.lz_pick));
select t.eq('L: after the block (the lane under it was behind) and 7 more ticks every cow is in the same state as in the tick-by-tick run (position, phase, goal, base)',
            (select count(*)::int from t.lz_blk_a a join t.lz_blk_b b using (id) where (a.x, a.z, a.phys_tick, a.lane_until, a.goal_until, a.gx, a.gz, a.yaw, a.sent_qx, a.sent_qz, a.last_sent_tick, a.cx, a.cz)
                                                                                    is distinct from (b.x, b.z, b.phys_tick, b.lane_until, b.goal_until, b.gx, b.gz, b.yaw, b.sent_qx, b.sent_qz, b.last_sent_tick, b.cx, b.cz)), 0);
select t.is_true('L: ... and the block really ended the lanes around it in both runs (over 100 cows were taken over by the exact sweep at tick 353 or later: ended, then back in a lane on a floor that is still uniform)', (select count(*) filter (where a.phys_tick >= 353) > 100 and count(*) filter (where b.phys_tick >= 353) > 100 from t.lz_blk_a a join t.lz_blk_b b using (id)));

-- O: a gap in the ticks with lazy lanes (the entity connection jumped from 100 to 250): every lane is re-anchored, positions and goals as in the run without lazy lanes
create or replace function t.lz_gap(p_mode text, p_name text) returns void language plpgsql as $$
begin
    perform t.lz_setup(p_mode, 400);
    perform t.lz_run(1, 100);
    perform t.lz_run(251, 330);
    perform mc.entity_auto_catchup(330, array(select id from mc.entity_lane));
    execute format('create table t.%I as select l.id, l.t0, l.x0, l.z0, l.gx, l.gz, l.gend, l.goal_until, l.yaw, l.cx, l.cz from mc.entity_lane l where l.auto', p_name);
end $$;
select t.lz_gap('off', 'lz_gap_a');
select t.lz_gap('on', 'lz_gap_b');
-- (the first step after a gap is a first step again for every eager lane; when it cannot be expressed as a plain delta the lane is handed to the generic tracker and the exact sweep, which places the
-- mob one walking step (at most 0.1 blocks) off the closed form: that happens only in the run that computes steps, i.e. not for lazy lanes.  Goals are a pure function of (id, tick) and never differ.)
select t.eq('L: after a gap of 150 ticks the goal chain of all 400 lanes is the same with and without lazy lanes (velocity, goal end, yaw), and the positions at tick 330 agree to 0.15 blocks',
            (select count(*)::int from t.lz_gap_a a join t.lz_gap_b b using (id) where (a.gx, a.gz, a.gend, a.yaw) is distinct from (b.gx, b.gz, b.gend, b.yaw) or abs((a.x0 + a.gx * (330 - a.t0)) - (b.x0 + b.gx * (330 - b.t0))) > 0.15 or abs((a.z0 + a.gz * (330 - a.t0)) - (b.z0 + b.gz * (330 - b.t0))) > 0.15), 0);
select t.is_true('L: ... and at least 90 % of the lanes are identical to the last bit (anchor, position, segment end, cell)',
                 (select count(*) filter (where (a.t0, a.x0, a.z0, a.goal_until, a.cx, a.cz) is not distinct from (b.t0, b.x0, b.z0, b.goal_until, b.cx, b.cz)) >= 360 from t.lz_gap_a a join t.lz_gap_b b using (id)));
select t.is_true('L: ... and the lanes walked on during the gap (every cow has a goal beyond tick 250)', (select count(*) = 400 and bool_and(gend > 250) from t.lz_gap_b));

-- P: lanes within reach of a viewer are never lazy; lanes he left become lazy again at their next segment
select t.lz_setup('on', 40);
select t.lz_run(1, 100);
select t.is_true('P: 40 cows in cells 1..4 with a viewer at (-6,-6): all lazy', (select count(*) = 40 and bool_and(lazy) from mc.entity_lane where auto));
update mc.player set chunk_x = 2, chunk_z = 2, x = 2 * 16 + 0.5, z = 2 * 16 + 0.5 where conn_id = 1;
select t.lz_run(101, 101);
select t.is_true('P: the viewer moved to chunk (2,2): the cows around him are not lazy any more', (select count(*) = 40 and not bool_or(lazy) from mc.entity_lane where auto));
update mc.player set chunk_x = -6, chunk_z = -6, x = -6 * 16 + 0.5, z = -6 * 16 + 0.5 where conn_id = 1;
select t.lz_run(102, 300);
select t.is_true('P: the viewer went away: after 200 ticks (a segment is at most 80 ticks) all cows are lazy again', (select count(*) = 40 and bool_and(lazy) from mc.entity_lane where auto));
select set_config('dbcraft.entity_lazy', 'on', false);
