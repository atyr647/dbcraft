-- Cost of a light recompute for a flat chunk with one raised column (CPU time).
\set ON_ERROR_STOP on
\ir cpu_timer.sql
set jit = off;
create sequence if not exists public.dbcraft_bench_edit_run;
select set_config('perf.base', (900000 + (nextval('public.dbcraft_bench_edit_run') % 100) * 5000)::text, false);
do $$
declare dim text := 'minecraft:overworld'; t0 numeric; n int := 100; b int := current_setting('perf.base')::int; i int;
  t_full numeric; t_skip numeric; t_ins numeric; t_sel numeric; t_old numeric; hm smallint[]; r bytea; cnt int;
begin
  perform mc.generate_flat_area(dim, b, 0, b + n - 1, 0);
  for i in 0 .. n - 1 loop perform mc.chunk_packet(dim, b + i, 0); end loop;
  for i in 0 .. n - 1 loop perform mc.set_block(dim, (b + i) * 16 + 3, -55, 3, 'minecraft:stone'); end loop;       -- raises one column of every chunk
  select hm_world_surface into hm from mc.chunk where dimension = dim and cx = b and cz = 0;
  -- full recompute: invalidate the key, then compute
  t0 := bench.cpu_ms(); for i in 0 .. n - 1 loop
     update mc.chunk set light_ws = null where dimension = dim and cx = b + i and cz = 0;
     perform mc.compute_light(dim, b + i, 0); end loop; t_full := bench.cpu_ms() - t0;
  t0 := bench.cpu_ms(); for i in 0 .. n - 1 loop perform mc.compute_light(dim, b + i, 0); end loop; t_skip := bench.cpu_ms() - t0;
  t0 := bench.cpu_ms(); for i in 0 .. n - 1 loop update mc.chunk set light_ws = null where dimension = dim and cx = b + i and cz = 0; end loop; t_old := bench.cpu_ms() - t0;
  t0 := bench.cpu_ms(); for i in 0 .. n - 1 loop r := mc.sky_layer(hm, 0); end loop; t_sel := bench.cpu_ms() - t0;
  raise notice 'L1 compute_light, full recompute (incl. key invalidation) : % ms', round(t_full / n, 3);
  raise notice 'L2   the key invalidation alone (one chunk row update)    : % ms', round(t_old / n, 3);
  raise notice 'L3 compute_light, key matches (early exit)                : % ms', round(t_skip / n, 3);
  raise notice 'L4 one general sky_layer on this heightmap                : % ms', round(t_sel / n, 3);
end $$;
