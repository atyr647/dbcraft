-- Helpers for the world-size scaling benchmark (docs/PERF-SCALE.md).  Objects live in schema "scale"; the benchmark database is throwaway.
create schema if not exists scale;
create table if not exists scale.state (k text primary key, v bigint);
create table if not exists scale.samples (size_chunks int, series text, op text, phase text, us numeric);
create table if not exists scale.sizes (size_chunks int, series text, rel text, rows bigint, heap_bytes bigint, toast_bytes bigint, index_bytes bigint);
create table if not exists scale.keys (n int primary key, cx int, cz int, x int, y int, z int);

-- the i-th tile of a square spiral around the origin (tile 0 = (0,0)), the order in which an exploring player would extend the world
create or replace function scale.spiral(i int, out tx int, out tz int) language plpgsql immutable as $$
declare k int; t int; m int;
begin
  if i = 0 then tx := 0; tz := 0; return; end if;
  k := ceil((sqrt(i + 1) - 1) / 2.0)::int;           -- ring number: ring k holds the tiles with max(|tx|,|tz|) = k
  t := 2 * k + 1; m := t * t - 1;                    -- last tile index of ring k
  if i > m - (t - 1) then            tx := k - (m - i);                      tz := k;                       -- top side, going west
  elsif i > m - 2 * (t - 1) then     tx := -k;                               tz := k - (m - (t - 1) - i);   -- left side, going south
  elsif i > m - 3 * (t - 1) then     tx := -k + (m - 2 * (t - 1) - i);       tz := -k;                      -- bottom side, going east
  else                               tx := k;                                tz := -k + (m - 3 * (t - 1) - i); end if;   -- right side, going north
end $$;

-- generate flat chunks tile by tile (tile = 8 x 8 chunks) in spiral order until the spiral holds p_target chunks; commits after every tile.
-- Counting tiles (not rows) keeps the target exact when other chunks (the benchmark's far-away generation tests) exist.
create or replace procedure scale.grow_flat(p_target int, p_dim text default 'minecraft:overworld') language plpgsql as $$
declare i int; s record; cxs int[]; czs int[];
begin
  select v into i from scale.state where k = 'tile_' || p_dim;
  i := coalesce(i, 0);
  while i * 64 < p_target loop
    select * into s from scale.spiral(i);
    select array_agg(s.tx * 8 + a), array_agg(s.tz * 8 + b) into cxs, czs from generate_series(0, 7) a, generate_series(0, 7) b;
    perform mc.generate_batch(p_dim, cxs, czs);
    i := i + 1;
    insert into scale.state values ('tile_' || p_dim, i) on conflict (k) do update set v = excluded.v;
    commit;
  end loop;
end $$;
