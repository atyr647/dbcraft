-- Vanilla-like mob behaviour (sql/942; the rules are in its header, read from the 26.3 jar and checked against the real server with tools/entity/vanilla_walkshare.py).  What is proved here:
--   A  the wait before a stroll: decision tick = first evaluation tick ((tick - born + id) even) + 2 * (G - 1), G ~ Geometric(1/60): mean 120 ticks, always on an evaluation tick, at least 1 tick away
--   B  the decision: a player within 32 blocks -> a stroll to a random block within +-10 (displacement exactly to that block, speed <= the stroll speed, direction uniform); a player within 2 chunks but
--      not within 32 blocks, or a spectator, or a newborn mob, or a mob that just arrived -> the next wait; nobody within 2 chunks -> dormant (no events: gend = 2^62)
--   C  rates over a long run, measured like the real server's (tools/entity/vanilla_walkshare.py: 28 % / 21 % walking within 24 blocks, 0 % at 40-130): near cows walk 12-40 % of the time,
--      cows farther than 32 blocks never move, far cows are dormant lanes that cost no events
--   D  a dormant mob wakes when a player gets within 2 chunks (lane rows and rows of mobs outside lanes), drawing a wait from that tick, and then strolls
--   E  lazy lanes agree with the tick-by-tick run (same positions and the same dormant mobs) in vanilla mode
--   F  dbcraft.entity_ai = 'wander' keeps the old behaviour (cows walk wherever they are)
\! python3 tools/load_world_ref.py >/dev/null
select mc.block_class_refresh();
select set_config('dbcraft.entity_spawner', 'off', false);
delete from mc.chunk where dimension = 'minecraft:overworld' and cx between -8 and 8 and cz between -8 and 8;
select mc.generate_flat('minecraft:overworld', cx, cz) from generate_series(-8, 8) cx, generate_series(-8, 8) cz;
select mc.entity_build_mask('minecraft:overworld', cx, cz, sy) from generate_series(-8, 8) cx, generate_series(-8, 8) cz, generate_series(-4, -3) sy;
select mc.entity_floor_build('minecraft:overworld', cx, cz) from generate_series(-8, 8) cx, generate_series(-8, 8) cz;
update mc.server_property set value = '4' where key = 'view-distance';
update mc.server_property set value = '10' where key = 'simulation-distance';
select set_config('dbcraft.entity_ai', 'vanilla', false);

create or replace function t.clear() returns void language plpgsql as $$
begin
    delete from mc.entity; delete from mc.entity_lane; delete from mc.play_out; delete from mc.entity_cell_viewer; delete from mc.entity_viewer_cell; delete from mc.player;
    delete from mc.entity_tick_log; update mc.entity_clock set last_tick = null; delete from mc.entity_view_dirty;
    perform setval('mc.entity_id_seq', 9000);
end $$;
create or replace function t.player(p_conn int, p_x float8, p_z float8, p_gm int default 1) returns void language sql as $$
    insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode)
    values (md5('p' || p_conn)::uuid, 'P' || p_conn, p_conn, 900 + p_conn, p_x, -60, p_z, floor(p_x / 16)::int, floor(p_z / 16)::int, p_gm)
$$;
create or replace function t.cow(p_id int, p_x float8, p_z float8, p_goal bigint default 1, p_born bigint default 0) returns void language sql as $$
    insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, goal_until, yaw, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz)
    values (p_id, md5('e' || p_id)::uuid, 'minecraft:cow', mc.entity_type_id('minecraft:cow'), p_x, -60.0, p_z, true, p_born, 0, floor(p_x / 16)::int, floor(p_z / 16)::int, p_goal, 0, 1,
            floor(p_x / 16)::int, floor(p_z / 16)::int, round(p_x * 4096), round(-60 * 4096.0), round(p_z * 4096))
$$;

------------------------------------------------------------------------------------------------ A  the wait
select t.is_true('A: the wait: mean 120 ticks over 40,000 draws (2 * Geometric(1/60), evaluated every second tick)',
                 (select avg(mc.entity_stroll_wait(i, 1000 + j, 0) - (1000 + j)) between 117 and 123 from generate_series(1, 200) i, generate_series(1, 200) j));
select t.is_true('A: ... always on an evaluation tick ((tick - born + id) even) and at least 1 tick after the tick it is drawn for',
                 not exists (select 1 from generate_series(1, 300) i, generate_series(1, 30) j,
                              lateral (select mc.entity_stroll_wait(i, 500 + j, j % 7) as td) w where (w.td - (j % 7) + i) % 2 <> 0 or w.td < 500 + j + 1));
select t.is_true('A: ... a geometric spread: 1 % of the waits are shorter than 3 ticks... (about 3 % of the draws end at the first evaluation) and 5 % are longer than 360 ticks',
                 (select count(*) filter (where td - 2000 <= 3)::float8 / count(*) between 0.01 and 0.06 and count(*) filter (where td - 2000 > 360)::float8 / count(*) between 0.03 and 0.09
                    from (select mc.entity_stroll_wait(i, 2000, 0) as td from generate_series(1, 20000) i) q));

------------------------------------------------------------------------------------------------ B  the decision
select t.clear();
select t.player(1, 10.5, 0.5);                                                    -- chunk (0, 0)
select mc.entity_viewers_refresh(1);
create temp table gd as select i as id, g.* from generate_series(1, 2000) i,
       lateral mc.entity_goal_v(i, 5000, 0, 0.088, 0, false, 0.5, -60, 0.5, 0, 0, 2) g;
select t.is_true('B: a player within 32 blocks: every mob decides to stroll (2,000 of 2,000 but the offsets (0, 0): 1 in 441)', (select count(*) filter (where gx <> 0 or gz <> 0) >= 1985 and count(*) filter (where dormant) = 0 from gd));
select t.is_true('B: ... the target is a block within +-10 of the mob: the displacement gx * dur is within +-10.5 and ends exactly on a block centre',
                 (select bool_and(abs(gx * dur) <= 10.5 + 1e-9 and abs(gz * dur) <= 10.5 + 1e-9 and abs((0.5 + gx * dur) - (floor(0.5 + gx * dur) + 0.5)) < 1e-9 and abs((0.5 + gz * dur) - (floor(0.5 + gz * dur) + 0.5)) < 1e-9) from gd where gx <> 0 or gz <> 0));
select t.is_true('B: ... the offsets are uniform: every column -10..10 of the target is hit (2,000 draws), and the walk is about 7.65 blocks on average (the mean distance in a square of +-10)',
                 (select count(distinct round(gx * dur)) >= 20 and avg(sqrt((gx * dur) ^ 2 + (gz * dur) ^ 2)) between 7.0 and 8.2 from gd where gx <> 0 or gz <> 0));
select t.is_true('B: ... the speed is the stroll speed or below (octile path length over the displacement: at most 1.4143 times slower), the duration at least 2 ticks',
                 (select bool_and(sqrt(gx ^ 2 + gz ^ 2) <= 0.088 + 1e-9 and sqrt(gx ^ 2 + gz ^ 2) >= 0.088 / 1.4143 - 1e-3 and dur >= 2) from gd where gx <> 0 or gz <> 0));
select t.is_true('B: ... the yaw faces the walk (atan2(-dx, dz))', (select bool_and(abs(((degrees(atan2(-gx, gz)) - yaw + 540)::numeric % 360) - 180) < 1e-3) from gd where gx <> 0 or gz <> 0));
select t.is_true('B: the mob that has just arrived (it walked): the next WAIT, standing, not dormant, ends on an evaluation tick',
                 (select bool_and(gx = 0 and gz = 0 and not dormant and (5000 + dur + i) % 2 = 0 and dur >= 1) from (select i, g.* from generate_series(1, 300) i, lateral mc.entity_goal_v(i, 5000, 0, 0.088, 0, true, 0.5, -60, 0.5, 0, 0, 2) g) q));
select t.is_true('B: a newborn (born at most 1 tick ago) waits first, as vanilla does (the stroll chance is 1/60 per evaluation, not 1 at birth)',
                 (select bool_and(gx = 0 and gz = 0 and not dormant) from (select i, g.* from generate_series(1, 300) i, lateral mc.entity_goal_v(i, 5000, 0, 0.088, 4999, false, 0.5, -60, 0.5, 0, 0, 2) g) q));
-- the player at 40 blocks (chunk 2): within 2 chunks of the mob's chunk, not within 32 blocks: no stroll, no dormancy
select t.clear();
select t.player(1, 40.5, 0.5);
select mc.entity_viewers_refresh(1);
select t.is_true('B: a player within 2 chunks but 40 blocks away: no stroll (noActionTime is not reset beyond 32 blocks) and not dormant (a player could come closer without changing chunk)',
                 (select bool_and(gx = 0 and gz = 0 and not dormant and dur >= 1) from (select i, g.* from generate_series(1, 300) i, lateral mc.entity_goal_v(i, 5000, 0, 0.088, 0, false, 0.5, -60, 0.5, 0, 0, 2) g) q));
select t.clear();
select t.player(1, 10.5, 0.5, 3);                                                 -- a spectator
select mc.entity_viewers_refresh(1);
select t.is_true('B: a spectator within 10 blocks does not count (EntitySelector.NO_SPECTATORS): no stroll', (select bool_and(gx = 0 and gz = 0) from (select i, g.* from generate_series(1, 300) i, lateral mc.entity_goal_v(i, 5000, 0, 0.088, 0, false, 0.5, -60, 0.5, 0, 0, 2) g) q));
select t.clear();
select t.player(1, 100.5, 0.5);                                                   -- chunk 6
select mc.entity_viewers_refresh(1);
select t.is_true('B: nobody within 2 chunks: DORMANT (standing, a long segment, flagged)', (select bool_and(dormant and gx = 0 and gz = 0 and dur = 1000000) from (select i, g.* from generate_series(1, 300) i, lateral mc.entity_goal_v(i, 5000, 0, 0.088, 0, false, 0.5, -60, 0.5, 0, 0, 2) g) q));
select t.clear();
select t.is_true('B: nobody connected at all: dormant too', (select bool_and(dormant) from (select i, g.* from generate_series(1, 50) i, lateral mc.entity_goal_v(i, 5000, 0, 0.088, 0, false, 0.5, -60, 0.5, 0, 0, 2) g) q));

create or replace procedure t.run2(p_from int, p_ticks int) language plpgsql as $$
begin
    for tk in p_from .. p_from + p_ticks loop perform mc.entity_tick(tk); delete from mc.play_out; commit; end loop;
end $$;

------------------------------------------------------------------------------------------------ C  rates over a long run (the experiment of tools/entity/vanilla_walkshare.py)
select t.clear();
select t.player(1, 0.5, 0.5);
select t.cow(7000 + i, 16 * cos(a) * 1.0, 16 * sin(a)) from (select i, (i * 2.399963) as a from generate_series(1, 40) i) q;                                         -- 16 blocks away: near
select t.cow(7100 + i, 55 * cos(a), 55 * sin(a)) from (select i, (i * 2.399963) as a from generate_series(1, 40) i) q;                                                   -- 55 blocks: mid (chunks 3-4)
select t.cow(7200 + i, 110 * cos(a), 110 * sin(a)) from (select i, (i * 2.399963) as a from generate_series(1, 40) i) q;                                                 -- 110 blocks: far
create temp table samples (sec int, id int, x float8, z float8);
create or replace procedure t.run(p_from int, p_secs int) language plpgsql as $$
declare tk int := p_from * 20;
begin
    for s in p_from..p_secs loop
        for k in 1..20 loop tk := tk + 1; perform mc.entity_tick(tk); delete from mc.play_out; commit; end loop;
        perform mc.entity_auto_catchup(tk, array(select id from mc.entity_lane));
        insert into samples select s, e.id, e.x, e.z from mc.entity_live e; commit;
    end loop;
end $$;
call t.run(0, 25);
select t.is_true('C: the far cows (110 blocks: nobody within 2 chunks) are dormant lanes after their first decision (no events any more)', (select count(*) >= 38 from mc.entity_lane l where l.dormant and l.id >= 7200));
select t.is_true('C: ... the mid cows (55 blocks) are dormant exactly when no player is within 2 chunks of them (more than 2 chunks from the player''s chunk)', (select count(*) > 5 and bool_and(l.dormant = (greatest(abs(l.cx), abs(l.cz)) > 2)) from mc.entity_lane l where l.id between 7100 and 7199));
call t.run(26, 150);
select t.is_true('C: near cows (16 blocks from the player) walk 12-40 % of the time (vanilla: 28 % in 100 s, 21 % in 240 s: they wander off the 32-block disc and stop)',
                 (select count(*) filter (where sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2) > 0.5)::float8 / count(*) between 0.12 and 0.40 from samples a join samples b on b.id = a.id and b.sec = a.sec + 1 where a.id < 7100));
select t.is_true('C: cows beyond 32 blocks of the only player never move (55 and 110 blocks away: vanilla measured 0.0 % at 40-130 blocks)',
                 (select max(sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)) < 1e-9 from samples a join samples b on b.id = a.id and b.sec = a.sec + 1 where a.id >= 7100 and a.sec < 148));

------------------------------------------------------------------------------------------------ D  waking
select t.clear();
select t.player(1, 0.5, 0.5);
select t.cow(7299, -120, 0.5, 9991, 9990);
select t.cow(7200 + i, 110 - 12 + (i * 7919 % 240) / 10.0, -12 + (i * 104729 % 240) / 10.0, 9991, 9990) from generate_series(1, 40) i;       -- a patch of 24 x 24 blocks around (110, 0): 100 blocks from the player
call t.run2(9990, 560);
select t.is_true('D: before: the far cows are dormant and standing', (select count(*) filter (where dormant) >= 38 from mc.entity_lane where id >= 7200));
create temp table far0 as select e.id, e.x, e.z, coalesce(l.dormant, false) as dorm from mc.entity_live e left join mc.entity_lane l on l.id = e.id where e.id >= 7200;
update mc.player set x = 100.5, chunk_x = 6, z = 0.5, chunk_z = 0 where conn_id = 1;      -- the player walks (jumps) to the far cows: within 2 chunks of most of them
select mc.entity_tick(10551);
select t.is_true('D: a player within 2 chunks wakes the dormant lanes within reach of his chunk: not dormant, a wait drawn from this tick (goal_until = mc.entity_stroll_wait)',
                 (select count(*) >= 36 and bool_and(not dormant and l.goal_until = mc.entity_stroll_wait(l.id, 10551, l.born) and l.gend = l.goal_until) from mc.entity_lane l join far0 f on f.id = l.id
                   where f.dorm and abs(l.cx - 6) <= 2 and abs(l.cz - 0) <= 2));
select t.is_true('D: ... a dormant cow farther than 2 chunks from the player (at x = -120) stays dormant', (select dormant and goal_until < 4611686018427387904 + 1 and gend = 4611686018427387904 from mc.entity_lane where id = 7299));

call t.run2(10552, 600);
select t.is_true('D: ... the woken cows stroll: most of the cows within 2 chunks of the player moved within 600 ticks (P(no stroll in 600 ticks) = 0.7 %)',
                 (select count(*) filter (where sqrt((e.x - f.x) ^ 2 + (e.z - f.z) ^ 2) > 0.5)::float8 / count(*) > 0.6
                    from mc.entity_live e join far0 f using (id) where f.dorm));
-- a mob outside lanes: the row itself is dormant (goal_until = 2^62) and wakes with the viewer
select t.clear();
select t.cow(7301, 100.5, 0.5, 4611686018427387904);
update mc.entity set deep_sleep = true where id = 7301;
select t.player(1, 3.5, 0.5);
select mc.entity_viewers_refresh(5);
select t.is_true('D: a dormant row far away (no player within 2 chunks) stays dormant', (select goal_until = 4611686018427387904 from mc.entity where id = 7301));
update mc.player set x = 98.5, chunk_x = 6 where conn_id = 1;
select mc.entity_viewers_refresh(6);
select t.eq('D: ... and wakes when a player arrives within 2 chunks: goal_until = the wait drawn from that tick', (select goal_until from mc.entity where id = 7301), mc.entity_stroll_wait(7301, 6, 0));

------------------------------------------------------------------------------------------------ E  lazy against tick-by-tick, vanilla mode
create table t.fin (run text, id int, x float8, z float8, dormant boolean);
create or replace function t.hist(p_run text, p_lazy text) returns void language plpgsql as $$
declare tk int;
begin
    perform t.clear();
    perform set_config('dbcraft.entity_lazy', p_lazy, false);
    perform t.player(1, 0.5, 0.5);
    perform t.cow(7400 + i, -100 + (i * 7919 % 2000) / 10.0, -100 + (i * 104729 % 2000) / 10.0, 1 + i % 5) from generate_series(1, 120) i;
    for tk in 1..700 loop perform mc.entity_tick(tk); delete from mc.play_out; if tk = 300 then update mc.player set x = 70.5, chunk_x = 4 where conn_id = 1; end if; end loop;
    perform mc.entity_auto_catchup(700, array(select id from mc.entity_lane));
    insert into t.fin select p_run, e.id, e.x, e.z, coalesce(l.dormant, w.goal_until = 4611686018427387904) from mc.entity_live e join mc.entity w on w.id = e.id left join mc.entity_lane l on l.id = e.id;
end $$;
select t.hist('warm', 'off'); delete from t.fin;
select t.hist('eager', 'off');
select t.hist('lazy', 'on');
select t.is_true('E: 120 cows over 700 ticks (the ones nobody sees for 600 ticks despawn: the survivors are compared) while the viewer walks 70 blocks: positions and dormancy are the same with lazy lanes and tick by tick (to 1e-9)',
                 (select count(*) > 20 from t.fin where run = 'eager') and (select count(*) from t.fin where run = 'eager') = (select count(*) from t.fin where run = 'lazy') and not exists (select 1 from t.fin a join t.fin b on b.run = 'lazy' and b.id = a.id where a.run = 'eager' and (abs(a.x - b.x) > 1e-9 or abs(a.z - b.z) > 1e-9 or a.dormant is distinct from b.dormant)));
select t.is_true('E: ... and the run is not vacuous: some cows moved, some are dormant, some are not',
                 (select count(*) filter (where dormant) between 5 and 100 from t.fin where run = 'eager') and (select count(*) filter (where not dormant) > 3 from t.fin where run = 'eager'));

------------------------------------------------------------------------------------------------ F  the old behaviour is reachable
select t.clear();
select set_config('dbcraft.entity_ai', 'wander', false);
select t.cow(7500 + i, 110 + i, 0.5, 1 + i) from generate_series(1, 20) i;               -- far from everybody: in the old model they wander anyway
call t.run2(1, 400);
select mc.entity_auto_catchup(401, array(select id from mc.entity_lane));
select t.is_true('F: dbcraft.entity_ai = wander: cows far from every player walk (the old model, 60 % of the goals): at least 17 of 20 moved within 400 ticks',
                 (select count(*) >= 17 from mc.entity_live e where e.id >= 7500 and abs(e.x - (110 + (e.id - 7500))) + abs(e.z - 0.5) > 0.5));
select set_config('dbcraft.entity_ai', 'vanilla', false);
