-- Physics-only benchmark: N falling items + M resting items + K mobs spread over a 40 x 40 chunk flat world, mc.entity_physics for T ticks.
-- usage: psql -v nfall=10000 -v nrest=0 -v nmob=0 -v ticks=80 -f tests/bench/entity/bench_physics.sql      (connection: PG* environment; the database must be migrated, with sql/500-510)
-- Prints per-tick milliseconds (avg / p50 / p99 / max) for the first 30 ticks (the fall and the landing) and for the steady state after.
\set ON_ERROR_STOP on
\timing off
delete from mc.entity;
select count(*) as chunks_generated from (select mc.generate_flat('minecraft:overworld', a.x, b.z)
  from generate_series(-20, 19) a(x), generate_series(-20, 19) b(z)
 where not exists (select 1 from mc.chunk c where c.dimension = 'minecraft:overworld' and c.cx = a.x and c.cz = b.z)) g;
-- warm the collision masks of the sections the entities will touch (a one-time cost per section until it is edited: about 2 ms each); skipped where they are current
select count(*) as masks_built from (select mc.entity_build_mask('minecraft:overworld', a.x, b.z, c.sy)
  from generate_series(-20, 19) a(x), generate_series(-20, 19) b(z), generate_series(-4, -1) c(sy)
  left join mc.solid_mask m on false
 where not exists (select 1 from mc.solid_mask m2 where m2.dimension = 'minecraft:overworld' and m2.cx = a.x and m2.cz = b.z and m2.sy = c.sy)) w;
select 'world: ' || (select count(*) from mc.chunk where dimension = 'minecraft:overworld') || ' chunks' as world;

select setseed(0.42);
insert into mc.entity (id, uuid, type, type_id, x, y, z, vx, vy, vz, on_ground, born_tick, phys_tick, cx, cz, gx, gz)
select nextval('mc.entity_id_seq'), gen_random_uuid(), 'minecraft:item', (select protocol_id from ref.registry where registry = 'minecraft:entity_type' and name = 'minecraft:item'),
       x, y, z, vx, 0, vz, false, 0, 0, floor(x / 16)::int, floor(z / 16)::int, 0, 0
from (select -320 + random() * 640 as x, -59.9 + random() * 40 as y, -320 + random() * 640 as z, (random() - 0.5) * 0.3 as vx, (random() - 0.5) * 0.3 as vz
        from generate_series(1, :nfall)) r;
insert into mc.entity (id, uuid, type, type_id, x, y, z, vx, vy, vz, on_ground, born_tick, phys_tick, deep_sleep, cx, cz, gx, gz)
select nextval('mc.entity_id_seq'), gen_random_uuid(), 'minecraft:item', (select protocol_id from ref.registry where registry = 'minecraft:entity_type' and name = 'minecraft:item'),
       x, -60, z, 0, 0, 0, true, -1000, 0, false, floor(x / 16)::int, floor(z / 16)::int, 0, 0
from (select -320 + random() * 640 as x, -320 + random() * 640 as z from generate_series(1, :nrest)) r;
insert into mc.entity (id, uuid, type, type_id, x, y, z, vx, vy, vz, on_ground, born_tick, phys_tick, cx, cz, gx, gz, goal_until)
select nextval('mc.entity_id_seq'), gen_random_uuid(), tp, (select protocol_id from ref.registry where registry = 'minecraft:entity_type' and name = tp),
       x, -60, z, 0, 0, 0, true, 0, 0, floor(x / 16)::int, floor(z / 16)::int,
       case when walking then 0.1 * cos(a) else 0 end, case when walking then 0.1 * sin(a) else 0 end, 1000000
from (select case when random() < 0.875 then 'minecraft:cow' else 'minecraft:zombie' end as tp, -320 + random() * 640 as x, -320 + random() * 640 as z,
             random() < 0.8 as walking, random() * 6.28 as a from generate_series(1, :nmob)) r;

create temp table _lat (tick int, ms float8, n int);
create function pg_temp.bench_run(p_ticks int) returns void language plpgsql as $$
declare t0 timestamptz; n int;
begin
    for t in 1..p_ticks loop
        t0 := clock_timestamp();
        n := mc.entity_physics(t);
        insert into _lat values (t, extract(epoch from clock_timestamp() - t0) * 1000, n);
    end loop;
end $$;
select pg_temp.bench_run(:ticks);
select 'entities: ' || (select count(*) from mc.entity) || ' (deep asleep at the end: ' || (select count(*) from mc.entity where deep_sleep) || ')' as population;
select case when tick <= 30 then 'ticks 1-30 (falling, landing)' else 'ticks 31+ (steady)' end as phase,
       round(avg(ms)::numeric, 2) as avg_ms, round((percentile_cont(0.5) within group (order by ms))::numeric, 2) as p50_ms,
       round((percentile_cont(0.99) within group (order by ms))::numeric, 2) as p99_ms, round(max(ms)::numeric, 2) as max_ms,
       round(avg(n)) as avg_rows_processed
from _lat group by 1 order by 1;
select 'WAL-free check: n_tup_hot_upd / n_tup_upd of mc.entity = ' || n_tup_hot_upd || ' / ' || n_tup_upd as hot from pg_stat_user_tables where relid = 'mc.entity'::regclass;
