-- Parallel-query experiments: a timing harness and the standalone read-only computations of the tick.  Bench database only (schema `par`), never part of sql/.
-- usage: psql -X -f harness.sql   (after tests/bench/tick/run.sh has filled the tables), then see exp*.sql
create schema if not exists par;

-- Runs a query n times with `workers` parallel workers allowed (0 = serial) and the planner costs forced to zero, so that a parallel plan is always chosen if one
-- exists.  EXECUTE without INTO runs with no row limit, so workers can be used.  Returns the median/p10/p90 wall time in ms and the number of parallel workers
-- actually used in the last run (from EXPLAIN ANALYZE of the same statement).
create or replace function par.bench(q text, workers int, n int default 21, forced boolean default true)
returns table(median_ms numeric, p10_ms numeric, p90_ms numeric) language plpgsql as $$
declare t0 timestamptz; ts numeric[] := '{}'; i int;
begin
  perform set_config('max_parallel_workers_per_gather', workers::text, false);
  if forced then
    perform set_config('parallel_setup_cost', '0', false); perform set_config('parallel_tuple_cost', '0', false);
    perform set_config('min_parallel_table_scan_size', '0', false); perform set_config('min_parallel_index_scan_size', '0', false);
  else
    perform set_config('parallel_setup_cost', '1000', false); perform set_config('parallel_tuple_cost', '0.1', false);
    perform set_config('min_parallel_table_scan_size', '1024', false);
  end if;
  execute q;                                   -- warm-up
  for i in 1..n loop
    t0 := clock_timestamp(); execute q;
    ts := ts || (extract(epoch from clock_timestamp() - t0) * 1000)::numeric;
  end loop;
  select round((percentile_cont(.5) within group (order by x))::numeric, 3), round((percentile_cont(.1) within group (order by x))::numeric, 3),
         round((percentile_cont(.9) within group (order by x))::numeric, 3) into median_ms, p10_ms, p90_ms from unnest(ts) x;
  return next;
end $$;

-- how many workers a statement really gets (parses the EXPLAIN ANALYZE text)
create or replace function par.workers_used(q text, workers int) returns text language plpgsql as $$
declare l text; planned text := '-'; launched text := '-';
begin
  perform set_config('max_parallel_workers_per_gather', workers::text, false);
  perform set_config('parallel_setup_cost', '0', false); perform set_config('parallel_tuple_cost', '0', false);
  perform set_config('min_parallel_table_scan_size', '0', false);
  for l in execute 'explain (analyze, costs off, timing off, summary off) ' || q loop
    if l ~ 'Workers Planned' then planned := substring(l from 'Workers Planned: (\d+)'); end if;
    if l ~ 'Workers Launched' then launched := substring(l from 'Workers Launched: (\d+)'); end if;
  end loop;
  return 'planned ' || planned || ', launched ' || launched;
end $$;

-- the same packet expression as the movement broadcast (sql/431): one packet per player as if every player had moved (dx 3, dy 1, dz -2, rotation changed)
create or replace view par.pk as
select p.entity_id as eid,
       proto.varint(octet_length(q.b) + 1) || set_byte('\x00'::bytea, 0, q.id) || q.b
       || proto.varint(octet_length(h.b) + 1) || set_byte('\x00'::bytea, 0, 79) || h.b as data
  from mc.player p
  cross join lateral (select 47 as id,
        proto.varint(p.entity_id) || set_byte('\x00'::bytea, 0, (case when p.on_ground then 1 else 0 end) | 2) || proto.varint(1)
        || proto.i16(3) || proto.i16(1) || proto.i16(-2)
        || set_byte('\x00'::bytea, 0, mc.angle_byte(p.yaw)) || set_byte('\x00'::bytea, 0, mc.angle_byte(p.pitch)) as b) q
  cross join lateral (select proto.varint(p.entity_id) || set_byte('\x00'::bytea, 0, mc.angle_byte(p.yaw)) as b) h
 where p.conn_id is not null;
