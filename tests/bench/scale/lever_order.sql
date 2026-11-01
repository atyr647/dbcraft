-- Lever: physical row order.  The same 50,048 flat chunks inserted (a) tile by tile in spiral order (neighbours land on neighbouring pages),
-- (b) in a pseudo-random tile order (what many players exploring at once produce), (c) shuffled and then CLUSTERed on the primary keys.
-- Tile j of the shuffled run is spiral(j * 7919 mod T): a permutation of the same tiles because 7919 is prime and does not divide T = 782.
create or replace procedure scale.grow_flat_shuffled(p_target int, p_dim text default 'minecraft:overworld') language plpgsql as $$
declare t int := ceil(p_target / 64.0); i int; j int; s record; cxs int[]; czs int[];
begin
  select v into i from scale.state where k = 'tile_' || p_dim;
  i := coalesce(i, 0);
  while i < t loop
    j := (i::bigint * 7919 % t)::int;
    select * into s from scale.spiral(j);
    select array_agg(s.tx * 8 + a), array_agg(s.tz * 8 + b) into cxs, czs from generate_series(0, 7) a, generate_series(0, 7) b;
    perform mc.generate_batch(p_dim, cxs, czs);
    i := i + 1;
    insert into scale.state values ('tile_' || p_dim, i) on conflict (k) do update set v = excluded.v;
    commit;
  end loop;
end $$;

-- start a world over: remove every chunk (cascades to sections, light, cache) and reset the tile counter
create or replace procedure scale.reset_world(p_dim text default 'minecraft:overworld') language plpgsql as $$
begin
  delete from scale.state where k = 'tile_' || p_dim;
  truncate mc.chunk cascade;
  commit;
end $$;

-- (b2) the adversarial order: every batch of 64 chunks is scattered over the whole world (chunk k of the world is generated at step k * 7919 mod N)
create or replace procedure scale.grow_flat_scattered(p_target int, p_dim text default 'minecraft:overworld') language plpgsql as $$
declare n int := (ceil(p_target / 64.0) * 64)::int; i int; s record; cxs int[]; czs int[];
begin
  select v into i from scale.state where k = 'tile_' || p_dim;
  i := coalesce(i, 0);
  while i * 64 < n loop
    select array_agg(c.cx), array_agg(c.cz) into cxs, czs
      from generate_series(0, 63) r,
           lateral (select ((i * 64 + r)::bigint * 7919 % n)::int pos) p,
           lateral scale.spiral(p.pos / 64) sp,
           lateral (select sp.tx * 8 + (p.pos % 64) / 8 as cx, sp.tz * 8 + (p.pos % 64) % 8 as cz) c;
    perform mc.generate_batch(p_dim, cxs, czs);
    i := i + 1;
    insert into scale.state values ('tile_' || p_dim, i) on conflict (k) do update set v = excluded.v;
    commit;
  end loop;
end $$;
