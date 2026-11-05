-- Chunk cursors: a connection's wanted chunks that all exist and follow a known order are ONE row, not one row per chunk (docs/PERF-STORM.md, "Round 3").
--
-- Why.  A joiner at view distance 10 wants the 480 chunks of its square after the first 49 (net.hook_chunks), a walker that crosses a chunk border wants the 23-47 chunks that
-- entered its square (net.stream_chunks).  As rows of mc.chunk_wanted that is a 4 ms insert per join (heap and three indexes, 4,800 buffer hits), 7 ms a tick for a crowd of 500
-- walkers (1,063 rows a tick), and the same rows are found again one by one by mc.deliver_ready_chunks.  Every one of those chunks exists, and the order they are sent in
-- (nearest first, ties by x then z) is the order of the SPIRAL of the square: all positions (dx, dz) with |dx|, |dz| <= r sorted by dx*dx + dz*dz, dx, dz.  So the wanted set is
--
--     "the spiral positions of radius r around (cx, cz) after ordinal next_o, except those inside the old square (ocx, ocz, orr)"
--
-- and mc.chunk_cursor holds exactly that: one row per connection.  mc.chunk_spiral is the spiral, precomputed for every radius that can occur.
--
-- What is the same as with rows (tests/sql/1020_chunk_cursor.sql proves it against the previous implementation on random scripts of joins, walks over borders, teleports,
-- view distance changes, leaving connections and generation, per tick and per connection, bytes and order):
--   * a cursor exists only for a connection that has NO other wanted rows and whose chunks all exist when it is made, so it is exactly the set of rows the previous code would have inserted;
--   * anything that would add rows for the connection (a border crossing, a view change) first turns the cursor into the rows it stands for (mc.chunk_cursor_flush), and the delivery step
--     does the same when it finds that the client's view is not the one the cursor was made for, or that one of the chunks it is about to send does not exist (any more);
--   * the delivery takes the nearest m positions of a cursor exactly as it takes the nearest m rows (same budgets, same round robin), and removes what it sent by moving next_o;
--   * the row of mc.chunk_wanted with the dimension 'cursor' (one per cursor) keeps everything that looks at "is something wanted" (the quiet tick, the trim of the queue, the sweep of
--     connections that are gone) working without knowing about cursors; it is never a chunk (no chunk has that dimension).

-- the spiral: radius, ordinal (1 = the centre), offset, squared distance.  Static, 92,000 rows for the radii 1 .. 40.
create table if not exists mc.chunk_spiral (
    r  int not null,
    o  int not null,
    dx int not null,
    dz int not null,
    d  int not null,
    primary key (r, o) include (dx, dz, d)          -- covering: a window of the spiral is an index-only scan
);
-- (r, d, o): the first ordinal with a squared distance of at least d is the first entry of an index-only scan, not the minimum over a range
drop index if exists mc.chunk_spiral_d;
create index if not exists chunk_spiral_do on mc.chunk_spiral (r, d, o);
insert into mc.chunk_spiral (r, o, dx, dz, d)
select r.r, row_number() over (partition by r.r order by q.dx * q.dx + q.dz * q.dz, q.dx, q.dz), q.dx, q.dz, q.dx * q.dx + q.dz * q.dz
  from generate_series(1, 40) r(r) cross join lateral (select dx, dz from generate_series(-r.r, r.r) dx cross join generate_series(-r.r, r.r) dz) q
 where not exists (select 1 from mc.chunk_spiral);

-- one row per connection: the square (centre cx, cz and radius r: the client's view when the cursor was made), the square it entered from (null: none, a join), and how far it was sent
create unlogged table if not exists mc.chunk_cursor (
    conn_id   int primary key,
    dimension text not null,
    cx        int not null,
    cz        int not null,
    r         int not null,
    ocx       int,
    ocz       int,
    orr       int,
    next_o    int not null
);

-- A cursor becomes the rows it stands for: every position after next_o (outside the old square), in the order the delivery would have taken them (the rows' dist is the squared distance
-- to the centre, as the previous code inserted it), and its marker row goes.  The connections may be given in any order; a connection without a cursor is skipped.
create or replace function mc.chunk_cursor_flush(p_conns int[]) returns int language plpgsql volatile as $$
declare n int;
begin
    with cu as (delete from mc.chunk_cursor where conn_id = any (p_conns) returning *),
         ins as (insert into mc.chunk_wanted (conn_id, dimension, cx, cz, dist)
                 select cu.conn_id, cu.dimension, cu.cx + s.dx, cu.cz + s.dz, s.d
                   from cu join mc.chunk_spiral s on s.r = cu.r and s.o > cu.next_o
                  where cu.orr is null or abs(cu.cx + s.dx - cu.ocx) > cu.orr or abs(cu.cz + s.dz - cu.ocz) > cu.orr
                 on conflict (conn_id, dimension, cx, cz) do nothing returning 1),
         mk as (delete from mc.chunk_wanted w using cu where w.conn_id = cu.conn_id and w.dimension = 'cursor' returning 1)
    select count(*) into n from cu;
    return n;
end $$;
