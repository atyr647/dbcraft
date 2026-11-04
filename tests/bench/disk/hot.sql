-- CPU time of the hot paths touched by the storage change.  psql -X -d DB -f disk_hot.sql  (prints NOTICE lines "H<n> name: v unit")
\set ON_ERROR_STOP on
set jit = off;
create schema if not exists bench;
create or replace function bench.cpu_ms() returns numeric language sql volatile as $$
  select (split_part(pg_read_file('/proc/self/schedstat'), ' ', 1))::numeric / 1000000.0 $$;
create sequence if not exists public.dbcraft_bench_disk_run;
select set_config('perf.base', (900000 + (nextval('public.dbcraft_bench_disk_run') % 200) * 6000)::text, false);
do $$
declare dim text := 'minecraft:overworld'; b int := current_setting('perf.base')::int; i int; r int; t0 numeric; n int := 3000; tw numeric[] := '{}'; tr numeric[] := '{}';
  xs int[]; ys int[]; zs int[]; bl text[]; k int; cx int := b + 3000; tj numeric[] := '{}'; tc numeric[] := '{}'; tb numeric[] := '{}'; ts numeric[] := '{}'; secs int; m int;
  tg numeric[] := '{}'; ta numeric[] := '{}';
  pool text[] := array['minecraft:stone','minecraft:dirt','minecraft:gravel','minecraft:sand','minecraft:glass','minecraft:oak_planks'];
begin
  t0 := bench.cpu_ms(); perform mc.generate_flat_area(dim, b, 0, b + 99, 0); tg := tg || ((bench.cpu_ms() - t0) * 1000 / 100);
  t0 := bench.cpu_ms(); select count(*) into k from net.hook_chunks(-1, cx, 3000, 10); tj := tj || (bench.cpu_ms() - t0);
  for i in 1 .. 5 loop t0 := bench.cpu_ms(); select count(*) into k from net.hook_chunks(-1, cx, 3000, 10); tc := tc || (bench.cpu_ms() - t0); end loop;
  for r in 1 .. 2 loop
    select array_agg(b * 16 + (random() * 1599)::int), array_agg(-64 + (random() * 19)::int), array_agg((random() * 15)::int), array_agg(pool[1 + (random() * 5)::int]) into xs, ys, zs, bl from generate_series(1, n);
    t0 := bench.cpu_ms(); for i in 1 .. n loop perform mc.set_block(dim, xs[i], ys[i], zs[i], bl[i]); end loop; tw := tw || ((bench.cpu_ms() - t0) * 1000 / n);
    t0 := bench.cpu_ms(); for i in 1 .. n loop perform mc.get_block(dim, xs[i], ys[i], zs[i]); end loop; tr := tr || ((bench.cpu_ms() - t0) * 1000 / n);
  end loop;
  for r in 1 .. 3 loop
    select array_agg(b * 16 + 1600 + (random() * 399)::int), array_agg(-64 + (random() * 63)::int), array_agg((random() * 15)::int),
           array_agg(pool[1 + (random() * 5)::int]) into xs, ys, zs, bl from generate_series(1, 10000);
    secs := (select count(distinct (x >> 4, y >> 4, z >> 4)) from unnest(xs, ys, zs) t(x, y, z));
    t0 := bench.cpu_ms(); m := mc.set_blocks(dim, xs, ys, zs, bl); ts := ts || ((bench.cpu_ms() - t0) * 1000 / secs);
  end loop;
  -- fill: a 48x20x48 box (9 chunks, 12 sections) back and forth, per call
  for r in 1 .. 3 loop
    t0 := bench.cpu_ms(); perform mc.fill(dim, (b + 200) * 16, -60, 0, (b + 200) * 16 + 47, -41, 47, 'minecraft:stone'); ta := ta || (bench.cpu_ms() - t0);
    t0 := bench.cpu_ms(); perform mc.fill(dim, (b + 200) * 16, -60, 0, (b + 200) * 16 + 47, -41, 47, 'minecraft:glass'); ta := ta || (bench.cpu_ms() - t0);
  end loop;
  t0 := bench.cpu_ms();
  for i in 1 .. 100 loop perform mc.set_block(dim, b * 16 + i * 16 + 3, -62, 3, 'minecraft:gold_block'); perform mc.chunk_packet(dim, b + i, 0); end loop;
  tb := tb || ((bench.cpu_ms() - t0) * 1000 / 100);
  raise notice 'H0 generate_flat_area per chunk: % us', round(tg[1], 0);
  raise notice 'H1 join unexplored: % ms', tj[1];
  raise notice 'H2 join cached: % ms', (select min(x) from unnest(tc) x);
  raise notice 'H3 set_block: % us', (select array_to_string(array_agg(round(x, 1)), ' ') from unnest(tw) x);
  raise notice 'H3 get_block: % us', (select array_to_string(array_agg(round(x, 1)), ' ') from unnest(tr) x);
  raise notice 'H4 edit_rebuild: % us', round(tb[1], 0);
  raise notice 'H5 set_blocks_per_section: % us', (select array_to_string(array_agg(round(x, 0)), ' ') from unnest(ts) x);
  raise notice 'H6 fill_12_sections: % ms', (select array_to_string(array_agg(round(x, 1)), ' ') from unnest(ta) x);
end $$;
