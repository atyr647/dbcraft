-- Break down exp6: time of each step of the CTAS phase (create, create, drop) and the plan of the fan-out CTAS on a table with no statistics.
\set ON_ERROR_STOP on
\pset format unaligned
set jit = off; set parallel_setup_cost = 0; set parallel_tuple_cost = 0; set min_parallel_table_scan_size = 0;
set max_parallel_workers_per_gather = 3;
drop table if exists par.t_pk; drop table if exists par.t_fan;
\timing on
create unlogged table par.t_pk as select * from par.pk;
create unlogged table par.t_fan as select v.viewer_conn, string_agg(pk.data, '\x'::bytea order by pk.eid) as data from mc.visible v join par.t_pk pk on pk.eid = v.target_eid group by v.viewer_conn;
drop table par.t_pk; drop table par.t_fan;
\timing off
\echo --- plan of the fan-out CTAS on a table without statistics (3 workers)
create unlogged table par.t_pk as select * from par.pk;
explain (analyze, costs off, timing off) create unlogged table par.t_fan as select v.viewer_conn, string_agg(pk.data, '\x'::bytea order by pk.eid) as data from mc.visible v join par.t_pk pk on pk.eid = v.target_eid group by v.viewer_conn;
drop table if exists par.t_pk; drop table if exists par.t_fan;
