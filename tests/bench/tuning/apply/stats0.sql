-- Experiment: no column statistics for the packet payload columns.  The planner never filters or joins on them, but ANALYZE of a bytea column stores a most-common-values list and a
-- histogram of values of up to 1 KB each in pg_statistic, and (naptime 10 s) every queue table is re-analysed every 10 s: that was 16% of the WAL (8.8 MB in 75 s).
do $$ declare r record; begin
  for r in select * from (values ('net.inbox', 'payload'), ('net.outbox', 'data'), ('mc.play_in', 'body'), ('mc.play_in_work', 'body'), ('mc.play_out', 'data'),
                                 ('net.batch', 'payload'), ('net.play_inbox', 'body'), ('mc.chunk_cache', 'packet')) v(t, c) loop
    if to_regclass(r.t) is not null then execute format('alter table %s alter column %I set statistics 0', r.t, r.c); end if;
  end loop;
end $$;
