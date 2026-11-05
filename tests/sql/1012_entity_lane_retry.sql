-- The negative cache of lane attempts (sql/940: mc.entity.lane_nogo / lane_retry, dbcraft.entity_lane_retry; docs/WHY-MOBS-COST.md section 10).  A mob that walks on ground that is not uniform stays in the
-- exact sweep; the verdict "no lane for this goal" is remembered for 8 ticks (until the goal changes, or a block changes within 2 chunks) instead of being tested by every statement of every tick.
-- What is proved here (DIFFERENTIAL: the same history with dbcraft.entity_lane_retry = 1, the old behaviour, and 8):
--   A  rough ground (500 scattered blocks) with 80 mobs, 400 ticks, a block placed and removed in the middle: the exact position of every mob after every 20th tick is the same to 1e-9 (a lane is
--      the closed form of the sweep), the cache is used (mobs carry a verdict, far fewer lane attempts), and what the viewer is told reconstructs to the same positions
--   B  the invalidation: removing the obstacle (a block change within 2 chunks) makes a mob that was refused a lane a candidate in the same tick: it gets its lane at once, not after the 8 ticks
--   C  a new goal voids the verdict (lane_nogo is the goal end it is about)
\! python3 tools/load_world_ref.py >/dev/null
select mc.block_class_refresh();
select set_config('dbcraft.entity_ai', 'wander', false);
select set_config('dbcraft.entity_spawner', 'off', false);
delete from mc.chunk where dimension = 'minecraft:overworld' and cx between -8 and 8 and cz between -8 and 8;
select mc.generate_flat('minecraft:overworld', cx, cz) from generate_series(-8, 8) cx, generate_series(-8, 8) cz;
update mc.server_property set value = '4' where key = 'view-distance';
select mc.entity_build_mask('minecraft:overworld', cx, cz, sy) from generate_series(-8, 8) cx, generate_series(-8, 8) cz, generate_series(-4, -3) sy;
select mc.entity_floor_build('minecraft:overworld', cx, cz) from generate_series(-8, 8) cx, generate_series(-8, 8) cz;

create table t.pos (run text, tick int, id int, x float8, z float8);
create table t.pk (run text, tick int, conn int, pkt bytea);
-- the packets of a play_out row (varint length, id, body)
create or replace function t.split(b bytea) returns setof bytea language plpgsql as $$
declare off int := 0; r record;
begin
    while off < octet_length(b) loop
        select * into r from proto.varint_read(b, off);
        return next substring(b from off + 1 for (r.nxt - off) + r.val);
        off := r.nxt + r.val;
    end loop;
end $$;
create table t.stat (run text, nogo int, lanes int, nolane_ticks int);

create or replace function t.clear() returns void language plpgsql as $$
begin
    delete from mc.entity; delete from mc.entity_lane; delete from mc.play_out; delete from mc.entity_cell_viewer; delete from mc.entity_viewer_cell; delete from mc.player;
    delete from mc.entity_tick_log; update mc.entity_clock set last_tick = null;
    perform setval('mc.entity_id_seq', 9000);
end $$;

-- 500 blocks scattered over the ground of +-40 blocks (deterministic), the mobs and one viewer
create or replace function t.world(p_blocks boolean) returns void language plpgsql as $$
begin
    perform t.clear();
    perform setseed(0.42);
    perform mc.set_block('minecraft:overworld', x, -60, z, case when p_blocks then 'minecraft:stone' else 'minecraft:air' end)
       from (select (-40 + floor(random() * 80))::int as x, (-40 + floor(random() * 80))::int as z from generate_series(1, 500)) b;
    perform mc.entity_floor_build('minecraft:overworld', cx, cz) from generate_series(-8, 8) cx, generate_series(-8, 8) cz;
    insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values (md5('p1')::uuid, 'P1', 1, 901, 0.5, -60, 0.5, 0, 0, 1);
    insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, goal_until, yaw)
    select 7000 + i, md5('e' || i)::uuid, 'minecraft:cow', mc.entity_type_id('minecraft:cow'), x, -60.0, z, true, 0, 0, floor(x / 16)::int, floor(z / 16)::int, 1 + (i % 7), (i * 37 % 360)::real
      from (select i, -35 + ((i * 7919) % 7000) / 100.0 as x, -35 + ((i * 104729) % 7000) / 100.0 as z from generate_series(1, 80) i) q;
end $$;

create or replace function t.history(p_run text, p_retry int) returns void language plpgsql as $$
declare k int; nl int := 0;
begin
    perform t.world(true);
    perform set_config('dbcraft.entity_lane_retry', p_retry::text, false);
    perform set_config('dbcraft.entity_walk_prob', '0.9', false);
    for k in 1..400 loop
        if k = 150 then perform mc.set_block('minecraft:overworld', 5, -60, 5, 'minecraft:stone'); perform mc.set_block('minecraft:overworld', 6, -60, 5, 'minecraft:stone'); end if;
        if k = 250 then perform mc.set_block('minecraft:overworld', 5, -60, 5, 'minecraft:air'); perform mc.set_block('minecraft:overworld', 6, -60, 5, 'minecraft:air'); end if;
        perform mc.entity_tick(k);
        insert into t.pk select p_run, k, o.conn_id, p.pkt from mc.play_out o cross join lateral t.split(o.data) p(pkt);
        delete from mc.play_out;
        nl := nl + (select count(*)::int from mc.entity where lane_until = 0);
        if k % 20 = 0 then insert into t.pos select p_run, k, e.id, e.x, e.z from mc.entity_live e; end if;
    end loop;
    insert into t.stat select p_run, (select count(*)::int from mc.entity where lane_retry > 0), (select count(*)::int from mc.entity_lane), nl;
end $$;

select t.history('warm', 1);                -- (a first history on a fresh database differs in lane timing: floors and masks are built on first touch)
delete from t.pos; delete from t.pk; delete from t.stat;
select t.history('old', 1);
select t.history('new', 8);

select t.is_true('A: the history is not vacuous (80 mobs, 20 samples each, and the viewer got packets)', (select count(*) = 1600 from t.pos where run = 'old') and (select count(*) > 100 from t.pk where run = 'old'));
select t.is_true('A: the exact position of every mob after every 20th tick is the same with and without the cache (to 1e-9)',
                 not exists (select 1 from t.pos a join t.pos b on b.run = 'new' and b.tick = a.tick and b.id = a.id where a.run = 'old' and (abs(a.x - b.x) > 1e-9 or abs(a.z - b.z) > 1e-9)));
select t.is_true('A: ... and the cache was used: mobs carry a verdict at the end of the new run, none in the old one', (select nogo from t.stat where run = 'new') > 0 and (select nogo from t.stat where run = 'old') = 0);
select t.is_true('A: ... the rough ground refused lanes to a real part of the mobs (otherwise the comparison proves nothing): more than 5,000 mob-ticks outside lanes in the old run (of 32,000)', (select nolane_ticks from t.stat where run = 'old') > 5000);
select t.is_true('A: what the viewer is told: the packets of the two runs (as a multiset per tick and viewer) agree in at least 99 %; they differ where a lane starts a few ticks later (the first lane step and the generic tracker may split a movement differently)',
                 (select count(*) from (select tick, conn, pkt, count(*) from t.pk where run = 'old' group by 1, 2, 3 intersect select tick, conn, pkt, count(*) from t.pk where run = 'new' group by 1, 2, 3) s)
                 >= 0.99 * (select count(*) from (select tick, conn, pkt, count(*) from t.pk where run = 'old' group by 1, 2, 3) q));

------------------------------------------------------------------------------------------------ B  a block change voids the verdicts
select t.world(false);                                           -- flat ground
select set_config('dbcraft.entity_lane_retry', '1000', false);   -- (a verdict would stand for 1000 ticks)
select mc.set_block('minecraft:overworld', 20, -60, 5, 'minecraft:stone');
select mc.set_block('minecraft:overworld', 20, -60, 6, 'minecraft:stone');
select mc.set_block('minecraft:overworld', 21, -60, 5, 'minecraft:stone');
select mc.set_block('minecraft:overworld', 21, -60, 6, 'minecraft:stone');
delete from mc.entity;
insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, goal_until, yaw, gx, gz, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz)
values (7501, md5('b1')::uuid, 'minecraft:cow', mc.entity_type_id('minecraft:cow'), 19.5, -60.0, 5.5, true, 0, 0, 1, 0, 40, 90, 0.08, 0, 1, 1, 0, round(19.5 * 4096), round(-60 * 4096.0), round(5.5 * 4096));
select mc.entity_floor_build('minecraft:overworld', 1, 0);
select mc.entity_auto_try(2, array[7501]);
select t.eq('B: a walk into the pillars is refused a lane, and the verdict is stored (lane_nogo = the goal end)', (select lane_nogo from mc.entity where id = 7501), 40::bigint);
select t.is_true('B: ... for 1000 ticks', (select lane_retry from mc.entity where id = 7501) = 1002);
select mc.set_block('minecraft:overworld', 20, -60, 5, 'minecraft:air');
select mc.set_block('minecraft:overworld', 20, -60, 6, 'minecraft:air');
select mc.set_block('minecraft:overworld', 21, -60, 5, 'minecraft:air');
select mc.set_block('minecraft:overworld', 21, -60, 6, 'minecraft:air');
select t.eq('B: the block change within 2 chunks voided the verdict (lane_retry = 0)', (select lane_retry from mc.entity where id = 7501), 0::bigint);
select mc.entity_floor_build('minecraft:overworld', 1, 0);
select mc.entity_auto_try(3, array[7501]);
select t.eq('B: ... and the mob gets its lane in the same tick', (select count(*)::int from mc.entity_lane where id = 7501), 1);

------------------------------------------------------------------------------------------------ C  a new goal voids the verdict
update mc.entity set lane_nogo = 40, lane_retry = 5000 where id = 7501;
delete from mc.entity_lane;
update mc.entity set lane_until = 0, goal_until = 90 where id = 7501;                  -- another goal end: the verdict is about goal 40, not this one
select mc.entity_auto_try(4, array[7501]);
select t.eq('C: a verdict about another goal does not stop the mob from getting a lane', (select count(*)::int from mc.entity_lane where id = 7501), 1);
select set_config('dbcraft.entity_lane_retry', '8', false);
