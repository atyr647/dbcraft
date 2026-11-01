-- Micro-benchmarks for the PostgreSQL build comparison (docs/PERF-RUNTIME.md).  Every function returns the backend's ON-CPU milliseconds per unit of work,
-- read from /proc/self/schedstat (wall time is useless here: other jobs load the 4 CPUs).  Needs a superuser (pg_read_file).
create schema if not exists rt;

create or replace function rt.cpu_ns() returns bigint language sql volatile as $$
  select split_part(split_part(pg_read_file('/proc/self/schedstat'), E'\n', 1), ' ', 1)::bigint $$;

-- Cached chunk packet bodies of a 21 x 21 = 441 chunk area (what a join into a warm world reads), per 441-chunk batch.
create or replace function rt.join441(reps int default 10) returns float8 language plpgsql volatile as $$
declare a bigint; n bigint;
begin
  perform count(*) from (select mc.chunk_packet_body('minecraft:overworld', x, z) from generate_series(40, 60) x, generate_series(40, 60) z) q;   -- warm the plan cache
  a := rt.cpu_ns();
  for i in 1..reps loop
    perform count(length(b)) from (select mc.chunk_packet_body('minecraft:overworld', x, z) b from generate_series(40, 60) x, generate_series(40, 60) z) q;
  end loop;
  return (rt.cpu_ns() - a) / 1e6 / reps;
end $$;

-- One set_block per call at random positions of a generated band of the overworld (the shape of a player's break/place), per call.
create or replace function rt.setblock(n int default 3000) returns float8 language plpgsql volatile as $$
declare a bigint; blocks text[] := array['minecraft:stone','minecraft:dirt','minecraft:gravel','minecraft:sand']; ok boolean;
begin
  perform setseed(0.5);
  for i in 1..200 loop perform mc.set_block('minecraft:overworld', 300 * 16 + (random() * 319)::int, -64 + (random() * 19)::int, 300 * 16 + (random() * 319)::int, blocks[1 + (random() * 3)::int]); end loop;   -- warm
  a := rt.cpu_ns();
  for i in 1..n loop
    ok := mc.set_block('minecraft:overworld', 300 * 16 + (random() * 319)::int, -64 + (random() * 19)::int, 300 * 16 + (random() * 319)::int, blocks[1 + (random() * 3)::int]);
  end loop;
  return (rt.cpu_ns() - a) / 1e6 / n * 1000;      -- microseconds per call
end $$;

create sequence if not exists rt.gen_seq;
-- mc.generate_batch of 64 chunks (an 8 x 8 block) at fresh far-away coordinates every call: ms per batch.
create or replace function rt.gen64() returns float8 language plpgsql volatile as $$
declare a bigint; k bigint := nextval('rt.gen_seq'); bx int := 2000 + (k % 100)::int * 8; bz int := 2000 + (k / 100)::int * 8;
begin
  a := rt.cpu_ns();
  perform mc.generate_batch('minecraft:overworld', array(select bx + x from generate_series(0, 7) x, generate_series(0, 7) z), array(select bz + z from generate_series(0, 7) x, generate_series(0, 7) z));
  return (rt.cpu_ns() - a) / 1e6;
end $$;
