-- Experiment 9: verify the structural rules empirically (PG16): which statement shapes can get workers?  Each case reports "Workers Launched" of the plan actually executed.
\set ON_ERROR_STOP on
\pset format unaligned
set jit = off; set max_parallel_workers_per_gather = 3; set parallel_setup_cost = 0; set parallel_tuple_cost = 0; set min_parallel_table_scan_size = 0;
select version();
\echo --- 1. plain SELECT
explain (analyze, costs off, timing off, summary off) select count(*) from par.vis_i v join par.pkt pk on pk.eid = v.target_eid;
\echo --- 2. INSERT ... SELECT (no data-modifying CTE)
explain (analyze, costs off, timing off, summary off) insert into par.helper_out select v.viewer_conn, string_agg(pk.data, '\x'::bytea order by pk.eid) from par.vis_i v join par.pkt pk on pk.eid = v.target_eid group by v.viewer_conn;
delete from par.helper_out;
\echo --- 3. CREATE TABLE AS
explain (analyze, costs off, timing off, summary off) create temp table t3 as select count(*) c from par.vis_i v join par.pkt pk on pk.eid = v.target_eid;
\echo --- 4. data-modifying CTE around the same SELECT (the shape of the statements of the tick)
explain (analyze, costs off, timing off, summary off) with ins as (insert into par.helper_out select v.viewer_conn, string_agg(pk.data, '\x'::bytea order by pk.eid) from par.vis_i v join par.pkt pk on pk.eid = v.target_eid group by v.viewer_conn returning 1) select count(*) from ins;
delete from par.helper_out;
\echo --- 5/6/7/8: inside PL/pgSQL (auto_explain logs the nested plans; read the server log)
load 'auto_explain';
set auto_explain.log_min_duration = 0; set auto_explain.log_nested_statements = on; set auto_explain.log_analyze = on; set auto_explain.log_timing = off; set auto_explain.log_format = text;
do $$
declare n bigint; r record; arr bigint[];
begin
  perform count(*) from par.vis_i v join par.pkt pk on pk.eid = v.target_eid;                                    -- case 5: PERFORM
  select count(*) into n from par.vis_i v join par.pkt pk on pk.eid = v.target_eid;                              -- case 6: SELECT INTO
  n := (select count(*) from par.vis_i v join par.pkt pk on pk.eid = v.target_eid);                              -- case 7: scalar assignment
  for r in select v.viewer_conn from par.vis_i v join par.pkt pk on pk.eid = v.target_eid loop exit; end loop;   -- case 8: FOR loop (cursor)
  execute 'select count(*) from par.vis_i v join par.pkt pk on pk.eid = v.target_eid';                           -- case 9: EXECUTE without INTO
  execute 'select count(*) from par.vis_i v join par.pkt pk on pk.eid = v.target_eid' into n;                    -- case 10: EXECUTE ... INTO
end $$;
