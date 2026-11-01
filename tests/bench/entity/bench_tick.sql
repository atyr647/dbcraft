-- Whole entity tick under load: P simulated players walking over a 100 x 100 chunk flat world + a mix of entities, mc.entity_tick for T measured ticks (after 4 warm-up ticks).
-- usage: psql [-v spawner=on] [-v area=790] -v players=500 -v rest=0 -v mobs=0 -v falling=0 -v ticks=100 -f tests/bench/entity/bench_tick.sql
--   area    entities are placed uniformly in +-area blocks (with players=1 the player stands at the origin: the setup of the vanilla comparison)
--   rest    items at rest (already asleep and announced: the steady state)      mobs    cows (87.5%) and zombies (12.5%), 80% of them walking, goals staggered
--   falling items dropped from y -50..-30 at the start (a one-off burst)         players random walkers: they cross chunk borders and so change their view
-- Prints per-tick milliseconds (avg / p50 / p99 / max) per phase, entities processed, play_out rows and bytes, WAL bytes, HOT-update ratio.  Connection: PG* environment.
\set ON_ERROR_STOP on
\timing off
\if :{?spawner}
\else
\set spawner off
\endif
\if :{?area}
\else
\set area 790
\endif
select set_config('dbcraft.entity_spawner', :'spawner', false);
update mc.server_property set value = '10' where key = 'view-distance';
select count(*) as chunks_generated from (select mc.generate_flat('minecraft:overworld', a.x, b.z)
  from generate_series(-50, 49) a(x), generate_series(-50, 49) b(z)
 where not exists (select 1 from mc.chunk c where c.dimension = 'minecraft:overworld' and c.cx = a.x and c.cz = b.z)) g;
select count(*) as masks_built from (select mc.entity_build_mask('minecraft:overworld', a.x, b.z, c.sy)
  from generate_series(-50, 49) a(x), generate_series(-50, 49) b(z), generate_series(-4, -3) c(sy)
 where not exists (select 1 from mc.solid_mask m2 where m2.dimension = 'minecraft:overworld' and m2.cx = a.x and m2.cz = b.z and m2.sy = c.sy)) w;

truncate mc.play_out, mc.entity_cell_viewer, mc.entity_viewer_cell, mc.entity_tick_log;
delete from mc.entity;
delete from mc.player;
select setseed(0.37);
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode)
select gen_random_uuid(), 'p' || i, i, nextval('mc.entity_id_seq'), x, -60, z, floor(x / 16)::int, floor(z / 16)::int, 0
  from (select i, case when :players = 1 then 0.5 else -790 + random() * 1580 end as x, case when :players = 1 then 0.5 else -790 + random() * 1580 end as z from generate_series(1, :players) i) q;

-- entities: announced already (last_sent_tick > 0, sent state = current), so the measured ticks are the steady state, not the announcement burst
insert into mc.entity (id, uuid, type, type_id, x, y, z, vx, vy, vz, on_ground, born_tick, phys_tick, deep_sleep, cx, cz, gx, gz, goal_until, yaw, data,
                       last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz)
select id, gen_random_uuid(), tp, mc.entity_type_id(tp), x, y, z, 0, 0, 0, grounded, born, 0, asleep, floor(x / 16)::int, floor(z / 16)::int, gx, gz, goal, yaw,
       case when tp = 'minecraft:item' then '{"item":"minecraft:stone","count":1}'::jsonb else '{}'::jsonb end,
       1, floor(x / 16)::int, floor(z / 16)::int, round(x * 4096), round(y * 4096), round(z * 4096)
from (
    select nextval('mc.entity_id_seq')::int as id, 'minecraft:item' as tp, (-:area + random() * 2 * :area) as x, -60.0 as y, (-:area + random() * 2 * :area) as z, true as grounded, -1000 as born, true as asleep,
           0.0 as gx, 0.0 as gz, 0 as goal, 0::real as yaw from generate_series(1, :rest)
    union all
    select nextval('mc.entity_id_seq')::int, 'minecraft:item', (-:area + random() * 2 * :area), -50 + random() * 20, (-:area + random() * 2 * :area), false, 0, false, 0.0, 0.0, 0, 0::real from generate_series(1, :falling)
    union all
    select nextval('mc.entity_id_seq')::int, case when random() < 0.875 then 'minecraft:cow' else 'minecraft:zombie' end, (-:area + random() * 2 * :area), -60.0, (-:area + random() * 2 * :area), true, 0, false,
           0.0, 0.0, 1 + (random() * 60)::int, (random() * 360)::real from generate_series(1, :mobs)
) e;
analyze mc.entity; analyze mc.player;

create temp table _t (tick int, ms_total float8, ms_ai float8, ms_phys float8, ms_trk float8, ms_pick float8, awake int, rows_out int, bytes_out bigint, wal bigint, ms_players float8);
create function pg_temp.run(p_ticks int) returns void language plpgsql as $$
declare t0 timestamptz; l0 pg_lsn; l1 pg_lsn; r record; tk bigint;
begin
    for tk in 1..(p_ticks + 4) loop
        t0 := clock_timestamp();
        update mc.player set x = x + (random() - 0.5) * 0.5, z = z + (random() - 0.5) * 0.5;
        update mc.player set chunk_x = floor(x / 16)::int, chunk_z = floor(z / 16)::int where chunk_x <> floor(x / 16)::int or chunk_z <> floor(z / 16)::int;
        truncate mc.play_out;
        l0 := pg_current_wal_lsn();
        perform mc.entity_tick(tk);
        l1 := pg_current_wal_lsn();
        select * into r from mc.entity_tick_log where tick = tk;
        if tk > 4 then
            insert into _t select tk, r.ms_total, r.ms_ai, r.ms_physics, r.ms_tracker, r.ms_pickup, r.awake,
                                  (select count(*) from mc.play_out), (select coalesce(sum(octet_length(data)), 0) from mc.play_out), (l1 - l0)::bigint,
                                  extract(epoch from clock_timestamp() - t0) * 1000 - r.ms_total;
        end if;
    end loop;
end $$;
select pg_temp.run(:ticks);

select 'entities: ' || (select count(*) from mc.entity) || ' (asleep ' || (select count(*) from mc.entity where deep_sleep) || '), players ' || (select count(*) from mc.player) as population;
select phase, round(avg(v)::numeric, 2) as avg_ms, round((percentile_cont(0.5) within group (order by v))::numeric, 2) as p50, round((percentile_cont(0.99) within group (order by v))::numeric, 2) as p99, round(max(v)::numeric, 2) as max_ms
from (select 'total entity tick' as phase, ms_total as v from _t union all select '  viewers+ai+spawn+despawn', ms_ai from _t union all select '  physics', ms_phys from _t
      union all select '  tracker (announce, movement, fan-out)', ms_trk from _t union all select '  pickup', ms_pick from _t) q
group by phase order by case phase when 'total entity tick' then 0 when '  viewers+ai+spawn+despawn' then 1 when '  physics' then 2 when '  tracker (announce, movement, fan-out)' then 3 else 4 end;
select round(avg(awake)) as avg_entities_processed_per_tick, round(avg(rows_out)) as play_out_rows_per_tick, round(avg(bytes_out)) as play_out_bytes_per_tick,
       round(avg(wal)) as wal_bytes_per_tick, round(avg(ms_players)::numeric, 2) as ms_moving_the_players_not_counted from _t;
select 'HOT updates of mc.entity: ' || n_tup_hot_upd || ' of ' || n_tup_upd || ' (' || round(100.0 * n_tup_hot_upd / greatest(n_tup_upd, 1)) || '%), dead tuples now ' || n_dead_tup as hot
  from pg_stat_user_tables where relid = 'mc.entity'::regclass;
