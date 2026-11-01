-- CPU-time timer for benchmarks on a shared machine.   \ir cpu_timer.sql   (superuser: reads /proc/self/schedstat)
-- bench.cpu_ms() is the time THIS backend has spent on a CPU, in milliseconds.  Wall-clock time of a loop includes the time the process waited for a core while
-- other jobs ran (on the shared 4-core development machine that doubled single timings from one minute to the next); on-CPU time does not.  It still includes
-- cache effects of neighbours, so interleave A and B and use medians.
create schema if not exists bench;
create or replace function bench.cpu_ms() returns numeric language sql volatile as $$
  select (split_part(pg_read_file('/proc/self/schedstat'), ' ', 1))::numeric / 1000000.0 $$;
