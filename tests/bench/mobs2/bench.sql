-- MOBS2 benchmark: one entity tick per iteration (what mc.entity_tick does inline, and what the entity connection B does in split mode), same scenarios as the vanilla run of
-- tools/entity/vanilla_mobs.py.  CPU time of the backend (/proc/self/schedstat, on-CPU nanoseconds: load from other processes does not inflate it much) and wall time per tick.
--
-- usage: psql -X -v mobs=2000 -v where=view -v ticks=100 [-v items=0] [-v walk=0.6] [-v viewers=1] -f tests/bench/mobs2/bench.sql
--   mobs     cows (all the same type, announced already: the measured ticks are the steady state)
--   where    view: +-area blocks around the viewer (area 40, 72 from 5,000 mobs), every mob tracked      ring: square ring 100..140 blocks from the viewer: simulated, seen by nobody
--   items    stone items at rest in the +-40 area (already asleep and announced)
--   walk     share of new goals that are walks (dbcraft.entity_walk_prob; default 0.6 = the prototype's wander; 1.0 = every mob walks all the time)
--   viewers  players standing at the origin (1)         warm: warm-up ticks (default 30)
-- Prints one line: label | cpu avg/p50/p99 | wall avg/p50/p99 | phases | wal/tick | rows and bytes out.
\set ON_ERROR_STOP on
\timing off
\if :{?items}
\else
\set items 0
\endif
\if :{?walk}
\else
\set walk 0.6
\endif
\if :{?viewers}
\else
\set viewers 1
\endif
\if :{?warm}
\else
\set warm 30
\endif
\if :{?label}
\else
\set label ''
\endif
\if :{?reset}
\else
\set reset 0
\endif
\if :{?scatter}
\else
\set scatter 0
\endif
select set_config('dbcraft.entity_spawner', 'off', false);
select set_config('dbcraft.entity_walk_prob', :'walk', false);
update mc.server_property set value = '5' where key = 'view-distance';
-- reset=1: the chunks of the mob area are regenerated flat first.  Mobs get lanes only on a uniform floor: a world that other scenarios scribbled in (the scoreboard's edit scenario leaves 2,000 stone
-- and gold blocks in +-45) keeps most mobs out of their lanes (about 1,400 awake instead of 300 and 3-4x the cost), which is NOT a property of the simulation distance.
delete from mc.chunk where :reset = 1 and dimension = 'minecraft:overworld' and cx between -12 and 11 and cz between -12 and 11;
delete from mc.entity_floor where :reset = 1;
select count(*) as chunks_generated from (select mc.generate_flat('minecraft:overworld', a.x, b.z)
  from generate_series(-12, 11) a(x), generate_series(-12, 11) b(z)
 where not exists (select 1 from mc.chunk c where c.dimension = 'minecraft:overworld' and c.cx = a.x and c.cz = b.z)) g \gset
-- scatter=N: N single stone blocks on the ground in +-45 (what the scoreboard's edit scenario leaves behind): the mob scenarios then run on a floor that is not uniform
select count(*) as blocks_scattered from (select mc.set_block('minecraft:overworld', (-45 + floor(random() * 91))::int, -60, (-45 + floor(random() * 91))::int, 'minecraft:stone') from generate_series(1, :scatter)) b \gset
select count(*) as masks_built from (select mc.entity_build_mask('minecraft:overworld', a.x, b.z, c.sy)
  from generate_series(-12, 11) a(x), generate_series(-12, 11) b(z), generate_series(-4, -3) c(sy)
 where not exists (select 1 from mc.solid_mask m2 where m2.dimension = 'minecraft:overworld' and m2.cx = a.x and m2.cz = b.z and m2.sy = c.sy)) w \gset
select count(*) as floors_built from (select mc.entity_floor_build('minecraft:overworld', a.x, b.z)
  from generate_series(-12, 11) a(x), generate_series(-12, 11) b(z)
 where to_regclass('mc.entity_floor') is not null and not exists (select 1 from mc.entity_floor f where f.dimension = 'minecraft:overworld' and f.cx = a.x and f.cz = b.z and f.tops is not null)) w \gset
truncate mc.play_out, mc.entity_cell_viewer, mc.entity_viewer_cell, mc.entity_tick_log;
delete from mc.entity;
delete from mc.player;
create schema if not exists tickbench;
create or replace function tickbench.sched() returns bigint[] language sql volatile as $$
  select string_to_array(split_part(pg_read_file('/proc/self/schedstat'), E'\n', 1), ' ')::bigint[] $$;
select setseed(0.37);
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode)
select gen_random_uuid(), 'p' || i, i, nextval('mc.entity_id_seq'), 0.5 + (i - 1) * 0.01, -60, 0.5, 0, 0, 1 from generate_series(1, :viewers) i;
insert into mc.entity (id, uuid, type, type_id, x, y, z, vx, vy, vz, on_ground, born_tick, phys_tick, deep_sleep, cx, cz, gx, gz, goal_until, yaw, data,
                       last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz)
select id, gen_random_uuid(), tp, mc.entity_type_id(tp), x, y, z, 0, 0, 0, true, born, 0, asleep, floor(x / 16)::int, floor(z / 16)::int, 0, 0, goal, yaw,
       case when tp = 'minecraft:item' then '{"item":"minecraft:stone","count":1}'::jsonb else '{}'::jsonb end,
       1, floor(x / 16)::int, floor(z / 16)::int, round(x * 4096), round(y * 4096), round(z * 4096)
from (
    select nextval('mc.entity_id_seq')::int as id, 'minecraft:item' as tp, (-40 + random() * 80) as x, -59.75 as y, (-40 + random() * 80) as z, -1000 as born, true as asleep, 0 as goal, 0::real as yaw
      from generate_series(1, :items)
    union all
    select nextval('mc.entity_id_seq')::int, 'minecraft:cow', q.x, -60.0, q.z, -floor(random() * 60)::int, false, 1 + (random() * 60)::int, (random() * 360)::real
      from (select case when :'where' = 'ring' then (case when r.u1 < 0.5 then (case when r.u2 < 0.5 then -1 else 1 end) * (100 + r.u3 * 40) else -140 + r.u3 * 280 end) else (-r.area + r.u3 * 2 * r.area) end as x,
                   case when :'where' = 'ring' then (case when r.u1 < 0.5 then -140 + r.u4 * 280 else (case when r.u2 < 0.5 then -1 else 1 end) * (100 + r.u4 * 40) end) else (-r.area + r.u4 * 2 * r.area) end as z
              -- one set of random numbers per mob: random() in a sub-select that does not depend on the row is evaluated ONCE (the first version of the ring put all 2,000 mobs into one chunk)
              from (select case when :mobs >= 5000 then 72 else 40 end as area, random() as u1, random() as u2, random() as u3, random() as u4 from generate_series(1, :mobs) g) r) q
) e;
vacuum (full, analyze) mc.entity; vacuum (full, analyze) mc.entity_lane; analyze mc.player;       -- (a compact start: the earlier runs of this database left bloated tables behind)
create temp table _t (tick int, cpu float8, wall float8, ai float8, phys float8, trk float8, pick float8, awake int, rows_out int, bytes_out bigint, wal bigint);
-- one transaction per tick (COMMIT in the loop), as the server runs it: in one big transaction every update of a row inserted by the same transaction would also run its foreign-key check
create procedure pg_temp.run(p_from int, p_to int, p_rec boolean) language plpgsql as $$
declare a bigint[]; b bigint[]; t0 timestamptz; l0 pg_lsn; l1 pg_lsn; r record; tk bigint;
begin
    for tk in p_from..p_to loop
        truncate mc.play_out;
        l0 := pg_current_wal_lsn(); a := tickbench.sched(); t0 := clock_timestamp();
        perform mc.entity_tick(tk);
        b := tickbench.sched(); l1 := pg_current_wal_lsn();
        if p_rec then
            select * into r from mc.entity_tick_log where tick = tk;
            insert into _t select tk, (b[1] - a[1]) / 1e6, extract(epoch from clock_timestamp() - t0) * 1000, r.ms_ai, r.ms_physics, r.ms_tracker, r.ms_pickup, r.awake,
                                  (select count(*) from mc.play_out), (select coalesce(sum(octet_length(data)), 0) from mc.play_out), (l1 - l0)::bigint;
        end if;
        commit;
    end loop;
end $$;
-- warm-up, then VACUUM ANALYZE (what autovacuum + autoanalyze do within a minute on a real server: the transient of mobs entering their lanes leaves dead index entries and the statistics were taken when the lane table was empty: without the ANALYZE the plans were the wrong ones for 250 ticks and a 500-cow tick cost 11 ms instead of 3.5), then the measured ticks
call pg_temp.run(1, :warm, false);
vacuum analyze mc.entity, mc.entity_lane;
-- (autovacuum_naptime = 10s in docker/postgresql.conf: a vacuum every 200 ticks or so; the measured window is 100 ticks after one)
call pg_temp.run(:warm + 1, :warm + :ticks, true);
select format('%s mobs=%s items=%s where=%s walk=%s viewers=%s | cpu ms avg %s p50 %s p99 %s | wall avg %s p99 %s | ai %s phys %s trk %s pick %s | awake %s lanes %s | out rows %s KB %s | wal KB %s | load %s',
              :'label', :mobs, :items, :'where', :'walk', :viewers,
              round(avg(cpu)::numeric, 2), round((percentile_cont(0.5) within group (order by cpu))::numeric, 2), round((percentile_cont(0.99) within group (order by cpu))::numeric, 2),
              round(avg(wall)::numeric, 2), round((percentile_cont(0.99) within group (order by wall))::numeric, 2),
              round(avg(ai)::numeric, 2), round(avg(phys)::numeric, 2), round(avg(trk)::numeric, 2), round(avg(pick)::numeric, 2), round(avg(awake)), (select count(*) from mc.entity_lane),
              round(avg(rows_out)), round(avg(bytes_out) / 1024), round(avg(wal) / 1024), (select split_part(pg_read_file('/proc/loadavg'), ' ', 1))) as result from _t;
