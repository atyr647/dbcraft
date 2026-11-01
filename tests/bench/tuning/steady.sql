-- Steady-state load for tuning: the synthetic gateway of tests/bench/integration (ibench.*) driven at a fixed 20 Hz, one transaction per step like the real
-- gateway (COPY the tick's input, call mc.server_tick(), drain the output), recording a latency row per tick.
-- Needs tests/bench/integration/bench.sql loaded first (ibench.setup / ibench.gen / ibench.drain).  Used by tests/bench/tuning/run.sh.
--
-- Measured per tick (all milliseconds, from clock_timestamp()):
--   gen_ms     inserting the tick's inbound frames (the gateway's COPY) incl. its commit
--   tick_ms    mc.server_tick() only
--   drain_ms   ibench.drain() (what the gateway does with net.outbox)
--   commit_ms  the COMMIT of the tick/drain transaction (with synchronous_commit=on this contains the WAL flush)
--   lat_ms     tick_ms + drain_ms + commit_ms: what the gateway waits for each tick; the number that must stay under 50
--   late_ms    how far past its 20 Hz deadline the tick finished (0 when on time); the schedule is absolute, so a late tick shortens the next sleep
-- Results are kept in memory and written to tune.lat at the end so that measuring adds no writes of its own.
create schema if not exists tune;

drop table if exists tune.lat;
create table tune.lat (
    seq int primary key, cur_tick bigint, t_start float8,        -- t_start: epoch seconds when the tick transaction began
    gen_ms float8, tick_ms float8, drain_ms float8, commit_ms float8, lat_ms float8, late_ms float8);

-- The synthetic clients of ibench.gen only move.  A real client also answers keep-alives (the server kicks it after 30 s of silence: a run longer than that with
-- silent bots ends in a mass kick) and confirms teleports, so those answers are added here, one tick after the server's request like a real round trip.
create or replace function tune.gen(p_frac float8) returns void language plpgsql as $$
declare i_ka int := net.pkt('play', 'serverbound', 'minecraft:keep_alive'); i_tp int := net.pkt('play', 'serverbound', 'minecraft:accept_teleportation');
begin
    perform ibench.gen(p_frac);
    insert into net.inbox (conn_id, payload)
    select conn_id, proto.varint(i_ka) || proto.i64(keepalive_id) from mc.player where conn_id is not null and keepalive_id is not null;
    insert into net.inbox (conn_id, payload)
    select conn_id, proto.varint(i_tp) || proto.varint(awaiting_teleport) || proto.f64(x) || proto.f64(y) || proto.f64(z) || proto.f32(yaw) || proto.f32(pitch)
      from mc.player where conn_id is not null and awaiting_teleport is not null;
end $$;

create or replace procedure tune.run(p_ticks int, p_hz float8 default 20, p_frac float8 default 1.0, p_skip int default 0)
language plpgsql as $$
declare
    period float8 := 1.0 / p_hz;
    t0 timestamptz := clock_timestamp();
    a_tick bigint[] := '{}'; a_t float8[] := '{}'; a_gen float8[] := '{}'; a_tk float8[] := '{}'; a_dr float8[] := '{}'; a_cm float8[] := '{}'; a_late float8[] := '{}';
    t_g0 timestamptz; t_g1 timestamptz; t_a timestamptz; t_b timestamptz; t_c timestamptz; t_d timestamptz; cur bigint; deadline timestamptz; slp float8; i int;
begin
    for i in 1 .. p_ticks loop
        deadline := t0 + make_interval(secs => i * period);
        t_g0 := clock_timestamp();
        perform tune.gen(p_frac);
        commit;
        t_g1 := clock_timestamp();
        t_a := clock_timestamp();
        cur := mc.server_tick();
        t_b := clock_timestamp();
        perform ibench.drain();
        t_c := clock_timestamp();
        commit;
        t_d := clock_timestamp();
        if i > p_skip then
            a_tick := a_tick || cur;
            a_t    := a_t    || extract(epoch from t_a)::float8;
            a_gen  := a_gen  || extract(epoch from t_g1 - t_g0)::float8 * 1000;
            a_tk   := a_tk   || extract(epoch from t_b - t_a)::float8 * 1000;
            a_dr   := a_dr   || extract(epoch from t_c - t_b)::float8 * 1000;
            a_cm   := a_cm   || extract(epoch from t_d - t_c)::float8 * 1000;
            a_late := a_late || greatest(0, extract(epoch from t_d - deadline)::float8 * 1000);
        end if;
        slp := extract(epoch from deadline - clock_timestamp())::float8;
        if slp > 0.0005 then perform pg_sleep(slp); end if;
    end loop;
    insert into tune.lat
    select n, a_tick[n], a_t[n], a_gen[n], a_tk[n], a_dr[n], a_cm[n], a_tk[n] + a_dr[n] + a_cm[n], a_late[n]
      from generate_series(1, coalesce(cardinality(a_tick), 0)) n;
    commit;
end $$;

-- A set of counters, as one jsonb document, for before/after differences.
create or replace function tune.snapshot() returns jsonb language sql volatile as $$
  select jsonb_build_object(
    'bgwriter', (select to_jsonb(b) - 'stats_reset' from pg_stat_bgwriter b),
    'wal',      (select to_jsonb(w) - 'stats_reset' from pg_stat_wal w),
    'db',       (select to_jsonb(d) - 'stats_reset' - 'datname' - 'datid' from pg_stat_database d where datname = current_database()),
    'tables',   (select coalesce(jsonb_object_agg(schemaname || '.' || relname, jsonb_build_object(
                    'ins', n_tup_ins, 'upd', n_tup_upd, 'del', n_tup_del, 'hot', n_tup_hot_upd, 'live', n_live_tup, 'dead', n_dead_tup,
                    'vac', vacuum_count, 'autovac', autovacuum_count, 'autoan', autoanalyze_count,
                    'seq_scan', seq_scan, 'idx_scan', coalesce(idx_scan, 0),
                    'size', pg_table_size(relid), 'idx_size', pg_indexes_size(relid))), '{}')
                 from pg_stat_user_tables where schemaname in ('mc', 'net')),
    'indexes',  (select coalesce(jsonb_object_agg(schemaname || '.' || indexrelname, jsonb_build_object('scans', idx_scan, 'size', pg_relation_size(indexrelid), 'table', relname)), '{}')
                 from pg_stat_user_indexes where schemaname in ('mc', 'net')),
    'wal_lsn',  pg_current_wal_lsn()::text,
    'settings', (select jsonb_object_agg(name, setting) from pg_settings
                 where name in ('fsync','synchronous_commit','shared_buffers','wal_level','max_wal_size','min_wal_size','checkpoint_timeout','checkpoint_completion_target',
                                'full_page_writes','wal_compression','wal_buffers','bgwriter_delay','bgwriter_lru_maxpages','bgwriter_lru_multiplier','jit','work_mem',
                                'effective_cache_size','autovacuum_naptime','autovacuum_vacuum_cost_limit','huge_pages','commit_delay','max_parallel_workers_per_gather',
                                'track_io_timing','track_counts','track_activities','wal_writer_delay','random_page_cost','plan_cache_mode','max_connections'))) $$;
