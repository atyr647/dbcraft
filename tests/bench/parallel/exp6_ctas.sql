-- Experiment 6: the "compute fan-out phase" as parallel-eligible CREATE TABLE AS statements (the only way PG16 lets a parallel plan hand its result to the later DML:
-- INSERT ... SELECT, SELECT INTO and plpgsql FOR loops run serially).  Phase = (1) build the packets of every mover, (2) fan out + concatenate per viewer.
-- Each run creates and drops its two work tables (file creation: the churn the tuning work found).  Compared: serial, 3 workers, and the same serial phase with the
-- two statements replaced by a single serial CTE statement (what the tick does today).
\set ON_ERROR_STOP on
\pset format unaligned
\pset fieldsep ' | '
create or replace function par.phase(workers int) returns void language plpgsql as $$
begin
  perform set_config('max_parallel_workers_per_gather', workers::text, true);
  perform set_config('parallel_setup_cost', '0', true); perform set_config('parallel_tuple_cost', '0', true);
  perform set_config('min_parallel_table_scan_size', '0', true);
  drop table if exists par.t_pk; drop table if exists par.t_fan;
  create unlogged table par.t_pk as select * from par.pk;
  create unlogged table par.t_fan as select v.viewer_conn, string_agg(pk.data, '\x'::bytea order by pk.eid) as data
    from mc.visible v join par.t_pk pk on pk.eid = v.target_eid group by v.viewer_conn;
end $$;
-- the same work in the shape the tick has now: one serial statement with a materialised CTE, result consumed by a (here dummy) aggregate
create or replace function par.phase_cte() returns void language plpgsql as $$
begin
  perform set_config('max_parallel_workers_per_gather', '0', true);
  perform count(*) from (
    with pk as materialized (select * from par.pk)
    select v.viewer_conn, string_agg(pk.data, '\x'::bytea order by pk.eid) from mc.visible v join pk on pk.eid = v.target_eid group by v.viewer_conn) t;
end $$;
create temp table r(name text, ms numeric[]);
do $$
declare i int; t0 timestamptz; a numeric[] := '{}'; b numeric[] := '{}'; c numeric[] := '{}';
begin
  perform par.phase(0); perform par.phase(3); perform par.phase_cte();       -- warm-up
  for i in 1..15 loop
    t0 := clock_timestamp(); perform par.phase(0);     a := a || (extract(epoch from clock_timestamp() - t0) * 1000)::numeric;
    t0 := clock_timestamp(); perform par.phase(3);     b := b || (extract(epoch from clock_timestamp() - t0) * 1000)::numeric;
    t0 := clock_timestamp(); perform par.phase_cte();  c := c || (extract(epoch from clock_timestamp() - t0) * 1000)::numeric;
  end loop;
  insert into r values ('two serial CTAS statements', a), ('two CTAS statements, 3 workers', b), ('one serial CTE statement (today)', c);
end $$;
select name || ': median ' || round((percentile_cont(.5) within group (order by x))::numeric, 2) || ' ms, p10 ' || round((percentile_cont(.1) within group (order by x))::numeric, 2) || ' ms'
  from r, unnest(ms) x group by name order by name;
select 'work table rows: pk ' || (select count(*) from par.t_pk) || ', fan ' || (select count(*) from par.t_fan) || ', fan bytes ' || (select sum(octet_length(data)) from par.t_fan);
