-- Benchmark-only helpers (schema bx); the server under test is schema mc.  Loaded by tools/pg-load.sh after pg/*.sql.
create schema if not exists bx;

-- random point reads / writes, db-native loops inside ONE transaction (the same positions as the Clojure loops: SPEC hash2)
create or replace function bx.point_get(n int, span int, seed int) returns bigint language plpgsql as $$
declare i int; s bigint := 0;
begin
  for i in 1 .. n loop
    s := s + mc.get_block(mc.hash2(i, 1, seed) % span, (mc.hash2(i, 2, seed) % 130) - 64, mc.hash2(i, 3, seed) % span);
  end loop;
  return s;
end $$;

create or replace function bx.point_set(n int, span int, seed int) returns int language plpgsql as $$
declare i int; c int := 0;
begin
  for i in 1 .. n loop
    if mc.set_block(mc.hash2(i, 1, seed) % span, (mc.hash2(i, 2, seed) % 130) - 64, mc.hash2(i, 3, seed) % span, 1 + mc.hash2(i, 4, seed) % 20) then c := c + 1; end if;
  end loop;
  return c;
end $$;

create or replace function bx.clear_cache() returns void language sql as $$ truncate mc.chunk_cache $$;

-- chunk reads without shipping the bytes to the client: total bytes assembled
create or replace function bx.payload_bytes(cx0 int, cz0 int, cx1 int, cz1 int) returns bigint language sql as $$
  select coalesce(sum(length(mc.chunk_payload(cx, cz))), 0) from generate_series(cx0, cx1) cx, generate_series(cz0, cz1) cz $$;
create or replace function bx.packet_bytes(cx0 int, cz0 int, cx1 int, cz1 int) returns bigint language sql as $$
  select coalesce(sum(length(mc.chunk_packet(cx, cz))), 0) from generate_series(cx0, cx1) cx, generate_series(cz0, cz1) cz $$;

-- hot rows: one update per tick for every player (position churn), fillfactor 60 and no index on the hot columns (dbcraft's rule)
create table if not exists bx.hot (eid int primary key, x float8 not null, y float8 not null, z float8 not null, tick bigint not null) with (fillfactor = 60);
create or replace function bx.hot_reset(n int) returns void language sql as $$
  truncate bx.hot; insert into bx.hot select i, i, 64, i, 0 from generate_series(1, n) i $$;
create or replace function bx.hot_round(r int) returns void language sql as $$
  update bx.hot set x = eid + 0.01 * r, y = 64 + 0.02 * r, z = eid + 0.03 * r, tick = r $$;
-- the same table with an index on a column that changes every tick (what NOT to do; the dbcraft docs measure the damage)
create table if not exists bx.hot_idx (eid int primary key, x float8 not null, y float8 not null, z float8 not null, tick bigint not null) with (fillfactor = 60);
create index if not exists hot_idx_tick on bx.hot_idx (tick);
create or replace function bx.hot_idx_reset(n int) returns void language sql as $$
  truncate bx.hot_idx; insert into bx.hot_idx select i, i, 64, i, 0 from generate_series(1, n) i $$;
create or replace function bx.hot_idx_round(r int) returns void language sql as $$
  update bx.hot_idx set x = eid + 0.01 * r, y = 64 + 0.02 * r, z = eid + 0.03 * r, tick = r $$;

create or replace function bx.relsize(t text) returns bigint language sql as $$ select pg_total_relation_size(t::regclass) $$;
