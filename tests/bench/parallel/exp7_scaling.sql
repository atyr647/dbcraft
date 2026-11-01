-- Experiment 7: scaling of CPU-bound work with the number of workers, with a tiny result (no tuple shipping): the packet build of 2,000 movers aggregated to one row.
-- Also a 10x heavier version (the same expression over a 10x row multiplier) to show where the fixed startup cost stops mattering.
\set ON_ERROR_STOP on
\pset format unaligned
\pset fieldsep ' | '
select 'workers ' || w || ' | pk build x1 (2,000 rows): median ' || b.median_ms || ' ms, p10 ' || b.p10_ms || ' ms'
  from generate_series(0, 3) w, lateral par.bench('select sum(octet_length(data)) from par.pk', w, 21) b order by w;
select 'workers ' || w || ' | pk build x10 (20,000 rows): median ' || b.median_ms || ' ms, p10 ' || b.p10_ms || ' ms | ' || par.workers_used('select sum(octet_length(data)) from par.pk p cross join generate_series(1, 10) g', w)
  from generate_series(0, 3) w, lateral par.bench('select sum(octet_length(data)) from par.pk p cross join generate_series(1, 10) g', w, 11) b order by w;
