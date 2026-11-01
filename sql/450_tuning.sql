-- Tuning, part 1: database-level defaults and log retention.  The reasons, the measurements and the server-level settings (which cannot be set from SQL) are in docs/TUNING.md
-- and docker/postgresql.conf.  Safe to apply any number of times; applies to NEW sessions of this database.
--
-- Only settings that ALTER DATABASE ... SET accepts are here.  A role-level override wins over these (alter role ... set ...), so the gateway role can be exempted.
do $$
declare db text := current_database();
begin
    -- What the design assumes (docs/TUNING.md, "database-level defaults"):
    -- * synchronous_commit = off: a COMMIT returns before its WAL record is flushed; the WAL writer flushes every wal_writer_delay (200 ms by default, 3 rounds at most
    --   before it must), so after an operating-system crash or power loss the last few hundred milliseconds of committed ticks can be lost.  The database is never
    --   corrupted (fsync stays on) and a PostgreSQL crash alone loses nothing that reached the operating system.  Block edits and player moves of the last ~0.5 s are
    --   what is at risk; the world on disk is always a consistent earlier state.  Players cannot tell: the client resends its position the next tick.
    execute format('alter database %I set synchronous_commit = off', db);
    -- * jit = off: the tick runs hundreds of short statements; JIT compilation costs far more than it saves (docs/EVALUATION.md: 28 ms became 2.9 s with it forced).
    execute format('alter database %I set jit = off', db);
    -- * no parallel query: the statements are short, and a parallel plan costs worker start-up on every execution.
    execute format('alter database %I set max_parallel_workers_per_gather = 0', db);
    -- * a session that sits idle inside a transaction holds back vacuum for every table in the database (a forgotten psql window made the per-tick updates 17x slower
    --   in tests/bench/db).  After 60 s the server ends such a session.  The gateway is not affected: between ticks it is running a CALL, not waiting for a client.
    --   A session that needs longer (an interactive admin) can `set idle_in_transaction_session_timeout = 0` for itself.
    execute format('alter database %I set idle_in_transaction_session_timeout = ''60s''', db);
end $$;

-- Retention for the tables that grow forever.  tick_log, server_tick_log and error_log are diagnostics (about 100 bytes per tick each, 17 MB a day at 20 ticks a second);
-- chat_log is moderation history and is only pruned when asked to.  Returns what was deleted.  Call it from cron / a maintenance session, outside the tick:
--   select * from mc.prune_logs();                       -- diagnostics older than 7 days
--   select * from mc.prune_logs('1 day', '90 days');     -- and chat older than 90 days
create or replace function mc.prune_logs(p_keep interval default interval '7 days', p_chat_keep interval default null)
returns table (tick_log bigint, server_tick_log bigint, error_log bigint, chat_log bigint) language plpgsql as $$
declare a bigint; b bigint; c bigint; d bigint := 0;
begin
    delete from mc.tick_log where at < now() - p_keep;               get diagnostics a = row_count;
    delete from mc.server_tick_log where at < now() - p_keep;        get diagnostics b = row_count;
    delete from mc.error_log where at < now() - p_keep;              get diagnostics c = row_count;
    if p_chat_keep is not null then
        delete from mc.chat_log where at < now() - p_chat_keep;      get diagnostics d = row_count;
    end if;
    return query select a, b, c, d;
end $$;
comment on function mc.prune_logs(interval, interval) is 'Delete diagnostics older than p_keep (default 7 days) and, when p_chat_keep is given, chat older than that. Run outside the tick.';
