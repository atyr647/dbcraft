-- Chunk-path benchmark used by docs/PERF-CHUNKS.md.   psql -X -f tests/bench/world/perf_chunks.sql   (prints NOTICE lines)
-- Works in far-away chunk ranges of the overworld so it never touches the chunks other tests use; each run picks a fresh range (current_setting('perf.base')::int).
-- Numbers depend on the machine and on what else is running (record uptime next to them).
\set ON_ERROR_STOP on
set jit = off;
select set_config('perf.base', (1000 + (extract(epoch from clock_timestamp())::bigint % 100000) * 4)::int::text, false);

create or replace function pg_temp.ms(t0 timestamptz) returns numeric language sql as $$ select round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 2) $$;

\echo == A. generate + package unvisited flat chunks (n = 200, a row of chunks)
do $$ declare t0 timestamptz; n int := 200; b int := current_setting('perf.base')::int; i int; m numeric;
begin
  t0 := clock_timestamp();
  for i in 0 .. n - 1 loop perform mc.generate_flat('minecraft:overworld', b + i, 0); end loop;
  m := pg_temp.ms(t0); raise notice 'A1 generate_flat, one call per chunk       : % ms total, % ms per chunk', m, round(m / n, 3);
  t0 := clock_timestamp();
  for i in 0 .. n - 1 loop perform mc.chunk_packet('minecraft:overworld', b + i, 0); end loop;
  m := pg_temp.ms(t0); raise notice 'A2 chunk_packet cold (build + cache)       : % ms total, % ms per chunk', m, round(m / n, 3);
  t0 := clock_timestamp();
  for i in 0 .. n - 1 loop perform mc.chunk_packet('minecraft:overworld', b + i, 0); end loop;
  m := pg_temp.ms(t0); raise notice 'A3 chunk_packet cached                     : % ms total, % us per chunk', m, round(m * 1000 / n, 1);
end $$;

\echo == B. first-time join: net.hook_chunks into an unexplored world (view distance 10 -> radius 11 -> 23x23 = 529 chunks), then again warm
do $$ declare t0 timestamptz; n int; cx int := current_setting('perf.base')::int + 5000;
begin
  t0 := clock_timestamp(); select count(*) into n from net.hook_chunks(-1, cx, 3000, 10);
  raise notice 'B1 join at view distance 10, unexplored : % chunks in % ms', n, pg_temp.ms(t0);
  t0 := clock_timestamp(); select count(*) into n from net.hook_chunks(-1, cx, 3000, 10);
  raise notice 'B2 same join, everything cached         : % chunks in % ms', n, pg_temp.ms(t0);
  t0 := clock_timestamp(); select count(*) into n from net.hook_chunks(-1, cx + 1, 3000, 10);
  raise notice 'B3 one chunk step east, 23 new chunks   : % chunks in % ms', n, pg_temp.ms(t0);
end $$;

\echo == C. single edits: set_block at random positions over the generated row (y -64..-45), then the same through mc.blocks
do $$ declare t0 timestamptz; n int := 5000; b int := current_setting('perf.base')::int; i int; m numeric;
begin
  t0 := clock_timestamp();
  for i in 1 .. n loop
    perform mc.set_block('minecraft:overworld', b * 16 + (random() * 3199)::int, -64 + (random() * 19)::int, (random() * 15)::int,
                         (array['minecraft:stone','minecraft:dirt','minecraft:gravel','minecraft:sand'])[1 + (random() * 3)::int]);
  end loop;
  m := pg_temp.ms(t0); raise notice 'C1 set_block                               : % ms total, % us per edit', m, round(m * 1000 / n, 1);
  t0 := clock_timestamp();
  for i in 1 .. n loop perform mc.get_block('minecraft:overworld', b * 16 + (random() * 3199)::int, -64 + (random() * 19)::int, (random() * 15)::int); end loop;
  m := pg_temp.ms(t0); raise notice 'C2 get_block                               : % ms total, % us per read', m, round(m * 1000 / n, 1);
  -- an edit followed by the packet the client would get (cache invalidation + rebuild of a real, edited chunk)
  t0 := clock_timestamp();
  for i in 1 .. 500 loop
    perform mc.set_block('minecraft:overworld', b * 16 + i * 16 + 3, -62, 3, 'minecraft:gold_block');
    perform mc.chunk_packet('minecraft:overworld', b + i, 0);
  end loop;
  m := pg_temp.ms(t0); raise notice 'C3 set_block + chunk_packet rebuild (x500)   : % ms total, % ms per edit+rebuild', m, round(m / 500, 3);
end $$;

\echo == D. batched edits: mc.set_blocks(10000) spread over sections
do $$ declare t0 timestamptz; b int := current_setting('perf.base')::int; xs int[]; ys int[]; zs int[]; bl text[]; ch int; secs int; m numeric; n int := 10000;
begin
  -- 25 chunks x 4 sections = 100 sections
  select array_agg(b * 16 + (random() * 399)::int), array_agg(-64 + (random() * 63)::int), array_agg((random() * 15)::int),
         array_agg((array['minecraft:stone','minecraft:glass','minecraft:oak_planks','minecraft:sand'])[1 + (random() * 3)::int])
    into xs, ys, zs, bl from generate_series(1, n);
  secs := (select count(distinct (x >> 4, y >> 4, z >> 4)) from unnest(xs, ys, zs) t(x, y, z));
  t0 := clock_timestamp(); ch := mc.set_blocks('minecraft:overworld', xs, ys, zs, bl); m := pg_temp.ms(t0);
  raise notice 'D1 set_blocks 10k edits in % sections    : % ms (% changed, % ms per section)', secs, m, ch, round(m / secs, 3);
end $$;
