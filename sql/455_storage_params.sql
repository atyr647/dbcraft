-- Tuning, part 2: storage-level parameters for tables other modules created.  Each setting here has a measurement in docs/TUNING.md; settings that were tried and did not help are NOT here
-- (per-table autovacuum thresholds for the queues, UNLOGGED diagnostics and chunk cache, TOAST storage modes, other fillfactors: no effect on the tick).  Idempotent.
--
-- What the tables already have, from their own CREATE statements, and is right (docs/TUNING.md, "table layout"): mc.player and net.conn fillfactor 60 with no index on a column that changes, so 97-100% of
-- their updates are HOT (in place, no index writes); mc.chunk* fillfactor 70; the per-tick queues are UNLOGGED.

-- No column statistics for packet payloads.  The planner never filters or joins on these bytea columns, but ANALYZE stores a most-common-values list and a histogram of values (up to 1 KB each) in
-- pg_statistic for every column, and every queue table is re-analysed by autovacuum every autovacuum_naptime: with the recommended 10 s that was 8.8 MB of the 55.7 MB of WAL of a 75 s run
-- (16%), and a planning-time cost for nothing.  A statistics target of 0 stops ANALYZE from collecting anything for the column (existing rows are removed at the next ANALYZE).
do $$
declare r record;
begin
    for r in select * from (values
                ('net.inbox', 'payload'), ('net.outbox', 'data'), ('net.batch', 'payload'), ('net.play_inbox', 'body'),
                ('mc.play_in', 'body'), ('mc.play_in_work', 'body'), ('mc.play_out', 'data'), ('mc.chunk_cache', 'packet')) v(tbl, col) loop
        if to_regclass(r.tbl) is not null then
            execute format('alter table %s alter column %I set statistics 0', r.tbl, r.col);
        end if;
    end loop;
end $$;
