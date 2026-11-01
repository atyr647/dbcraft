-- The parallel plan of the fan-out at the current state (forced costs, 3 workers).
set max_parallel_workers_per_gather = 3; set parallel_setup_cost = 0; set parallel_tuple_cost = 0; set min_parallel_table_scan_size = 0; set jit = off;
explain (analyze, costs off, buffers off, verbose off)
select v.viewer_conn, string_agg(pk.data, '\x'::bytea order by pk.eid) from mc.visible v join par.pkt pk on pk.eid = v.target_eid group by v.viewer_conn;
