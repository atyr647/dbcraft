-- The EMPTY entity tick (docs/WHY-MOBS-COST.md): dbcraft.entity-mode = inline (or split) with NO entity at all.  What does the hook of mc.server_tick cost, and which statements run?
-- usage: psql -X -v players=50 -v mode=inline -v ticks=200 [-v profile=1] -f tests/bench/mobs2/empty.sql       (a database made by tests/bench/entity/setup_db.sh; players and entities are deleted)
-- Prints CPU (on-CPU nanoseconds of the backend, /proc/self/schedstat) and wall of the hook per tick; with profile=1 also functions, statements and tables per tick.
--   a  the hook of mc.server_tick on the player connection:  if mc.entity_mode() <> 'off' then mc.entity_step(tick)    (inline: the whole entity tick; split: the events of the entity connection)
--   b  split only: the entity tick of the entity connection B
\set ON_ERROR_STOP on
\timing off
\if :{?players}
\else
\set players 50
\endif
\if :{?ticks}
\else
\set ticks 200
\endif
\if :{?mode}
\else
\set mode inline
\endif
\if :{?profile}
\else
\set profile 0
\endif
\if :{?spawner}
\else
\set spawner off
\endif
select case when :profile = 1 then 'all' else 'none' end as trk \gset
select set_config('track_functions', :'trk', false), set_config('pg_stat_statements.track', :'trk', false) \gset
select set_config('dbcraft.entity_spawner', :'spawner', false) \gset
update mc.server_property set value = :'mode' where key = 'dbcraft.entity-mode';
truncate mc.play_out, mc.entity_cell_viewer, mc.entity_viewer_cell, mc.entity_tick_log;
delete from mc.entity;
delete from mc.player;
create schema if not exists tickbench;
create or replace function tickbench.sched() returns bigint[] language sql volatile as $$
  select string_to_array(split_part(pg_read_file('/proc/self/schedstat'), E'\n', 1), ' ')::bigint[] $$;
update mc.server_property set value = '10' where key = 'view-distance';
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode)
select gen_random_uuid(), 'p' || i, i, nextval('mc.entity_id_seq'), ((i % 15) * 40) * 16 + 0.5, -60, ((i / 15) * 40) * 16 + 0.5, (i % 15) * 40, (i / 15) * 40, 1 from generate_series(1, :players) i;
create temp table _t (tick int, a_cpu float8, a_wall float8, b_cpu float8, b_wall float8, wal bigint);
create procedure pg_temp.run(p_from int, p_to int, p_rec boolean) language plpgsql as $$
declare x timestamptz; y timestamptz; z timestamptz; m text; s0 bigint[]; s1 bigint[]; s2 bigint[]; l0 pg_lsn; l1 pg_lsn;
begin
    for tk in p_from..p_to loop
        l0 := pg_current_wal_lsn(); s0 := tickbench.sched(); x := clock_timestamp();
        m := mc.entity_mode();
        if m <> 'off' then perform mc.entity_step(tk); end if;
        y := clock_timestamp(); s1 := tickbench.sched();
        if m = 'split' then perform mc.entity_tick(tk); end if;
        z := clock_timestamp(); s2 := tickbench.sched(); l1 := pg_current_wal_lsn();
        if p_rec then insert into _t values (tk, (s1[1] - s0[1]) / 1e3, extract(epoch from y - x) * 1e6, (s2[1] - s1[1]) / 1e3, extract(epoch from z - y) * 1e6, (l1 - l0)::bigint); end if;
        commit;
    end loop;
end $$;
call pg_temp.run(1, 40, false);
vacuum analyze mc.entity, mc.entity_lane, mc.entity_viewer_cell, mc.entity_cell_viewer;
\if :profile
select pg_stat_statements_reset() is not null as x \gset
select pg_stat_reset() is not null as x \gset
\endif
call pg_temp.run(41, 40 + :ticks, true);
\if :profile
select pg_stat_force_next_flush() is null as x \gset
\endif
select format('%s players=%s | hook cpu us avg %s p50 %s min %s (wall avg %s p50 %s) | entity connection cpu us avg %s p50 %s | wal B/tick %s', :'mode', :players,
              round(avg(a_cpu)::numeric), round((percentile_cont(0.5) within group (order by a_cpu))::numeric), round(min(a_cpu)::numeric), round(avg(a_wall)::numeric), round((percentile_cont(0.5) within group (order by a_wall))::numeric),
              round(avg(b_cpu)::numeric), round((percentile_cont(0.5) within group (order by b_cpu))::numeric), round(avg(wal)::numeric)) as result from _t;
update mc.server_property set value = 'off' where key = 'dbcraft.entity-mode';
\if :profile
\pset format aligned
\pset footer off
select 'FUNCTIONS (per tick)' as section;
select funcname, round(calls::numeric / :ticks, 2) as calls_tick, round((total_time / :ticks * 1000)::numeric, 1) as total_us, round((self_time / :ticks * 1000)::numeric, 1) as self_us
  from pg_stat_user_functions where schemaname in ('mc', 'proto', 'net') order by total_time desc limit 24;
select 'STATEMENTS (nested ones included, per tick)' as section;
select round((total_exec_time / :ticks * 1000)::numeric, 1) as us_tick, round(calls::numeric / :ticks, 2) as calls_tick, round((mean_exec_time * 1000)::numeric, 1) as us_call,
       round(rows::numeric / :ticks, 1) as rows_tick, round(wal_bytes::numeric / :ticks) as wal_b_tick, round((shared_blks_hit + shared_blks_read)::numeric / :ticks, 1) as blks_tick,
       regexp_replace(left(query, 130), '\s+', ' ', 'g') as query
  from pg_stat_statements
 where query not like '%pg_stat_%' and query not like '%tickbench%' and query not like 'insert into _t%' and query not like 'call pg_temp%' and query not like 'select set_config%' and query not like 'truncate%' and query not like 'COMMIT%' and query not like 'commit%'
   and query not like 'select format(%' and query not like 'update mc.server_property%'
 order by total_exec_time desc limit 30;
select 'TABLES (tuples per tick)' as section;
select relname, round(n_tup_ins::numeric / :ticks, 1) as ins, round(n_tup_upd::numeric / :ticks, 1) as upd, round(n_tup_del::numeric / :ticks, 1) as del,
       round(seq_scan::numeric / :ticks, 2) as seqscan, round(seq_tup_read::numeric / :ticks, 1) as seq_rows, round(idx_scan::numeric / :ticks, 2) as idxscan, round(idx_tup_fetch::numeric / :ticks, 1) as idx_rows
  from pg_stat_user_tables where schemaname = 'mc' and (n_tup_ins + n_tup_upd + n_tup_del + seq_scan + idx_scan) > 0 order by n_tup_upd + n_tup_ins + n_tup_del + idx_tup_fetch + seq_tup_read desc limit 12;
\endif
