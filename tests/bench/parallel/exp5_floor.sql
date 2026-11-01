-- Experiment 5: the fixed cost of a parallel query = launching workers (fork), shared-memory setup, teardown.  A trivial query (count over 2,000 rows, microseconds of real work)
-- at 0..3 workers; the difference is pure parallel overhead.  31 runs each; p10 approximates the quiet-machine floor, median the loaded one.
\set ON_ERROR_STOP on
\pset format unaligned
\pset fieldsep ' | '
select 'workers ' || w || ' | median ' || b.median_ms || ' ms | p10 ' || b.p10_ms || ' ms | p90 ' || b.p90_ms || ' ms'
  from generate_series(0, 3) w, lateral par.bench('select count(*) from net.conn', w, 31) b order by w;
