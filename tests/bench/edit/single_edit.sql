-- CPU time of the single-edit path (mc.set_block) and of reading a block, per call: 4,000 random edits in 100 generated flat chunks, three repetitions.
--   psql -X -d DB -f tests/bench/edit/single_edit.sql
\set ON_ERROR_STOP on
\ir cpu_timer.sql
set jit = off;
create sequence if not exists public.dbcraft_bench_edit_run;
select set_config('perf.base', (800000 + (nextval('public.dbcraft_bench_edit_run') % 100) * 5000)::text, false);
do $$
declare dim text := 'minecraft:overworld'; b int := current_setting('perf.base')::int; i int; r int; t0 numeric; n int := 4000; tw numeric[] := '{}'; tr numeric[] := '{}';
  xs int[]; ys int[]; zs int[]; bl text[];
  pool text[] := array['minecraft:stone','minecraft:dirt','minecraft:gravel','minecraft:sand','minecraft:glass','minecraft:oak_planks'];
begin
  perform mc.generate_flat_area(dim, b, 0, b + 99, 0);
  for r in 1 .. 3 loop
    select array_agg(b * 16 + (random() * 1599)::int), array_agg(-64 + (random() * 19)::int), array_agg((random() * 15)::int), array_agg(pool[1 + (random() * 5)::int]) into xs, ys, zs, bl from generate_series(1, n);
    t0 := bench.cpu_ms(); for i in 1 .. n loop perform mc.set_block(dim, xs[i], ys[i], zs[i], bl[i]); end loop; tw := tw || ((bench.cpu_ms() - t0) * 1000 / n);
    t0 := bench.cpu_ms(); for i in 1 .. n loop perform mc.get_block(dim, xs[i], ys[i], zs[i]); end loop; tr := tr || ((bench.cpu_ms() - t0) * 1000 / n);
  end loop;
  raise notice 'set_block: % us per edit (three runs, CPU time)   get_block: % us per read', (select array_agg(round(x::numeric, 1)) from unnest(tw) x), (select array_agg(round(x::numeric, 1)) from unnest(tr) x);
end $$;
