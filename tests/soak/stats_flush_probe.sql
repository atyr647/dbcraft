-- Does a long-running PL/Python CALL make its table statistics visible to autovacuum?  (docs/SOAK.md)
-- A backend normally flushes its pending statistics when it goes idle; a procedure that loops with plpy.commit() never does.
-- Run:  psql -f tests/soak/stats_flush_probe.sql   (own scratch table; the CALL runs 8 seconds; compare the counters the second session sees)
drop table if exists public.stats_probe;
create table public.stats_probe (id int primary key, v int) with (autovacuum_enabled = false);
insert into public.stats_probe select g, 0 from generate_series(1, 100) g;
create or replace procedure public.stats_probe_run(p_flush boolean, p_seconds int) language plpython3u as $$
import time
end = time.time() + p_seconds
while time.time() < end:
    plpy.execute("update public.stats_probe set v = v + 1")
    if p_flush:
        plpy.execute("select pg_stat_force_next_flush()")
    plpy.commit()
    time.sleep(0.05)
$$;
