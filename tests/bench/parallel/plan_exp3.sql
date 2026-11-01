set jit = off; set enable_partitionwise_aggregate = on; set enable_partitionwise_join = on;
\echo === B parallel (partitioned by viewer_conn)
set max_parallel_workers_per_gather = 3; set parallel_setup_cost = 0; set parallel_tuple_cost = 0; set min_parallel_table_scan_size = 0;
explain (analyze, costs off, timing on, summary on)
select v.viewer_conn, string_agg(pk.data, '\x'::bytea order by pk.eid) from par.vis_p v join par.pkt pk on pk.eid = v.target_eid group by v.viewer_conn;
\echo === C serial (index on viewer_conn, target_eid)
set max_parallel_workers_per_gather = 0;
explain (analyze, costs off, timing on, summary on)
select v.viewer_conn, string_agg(pk.data, '\x'::bytea order by v.target_eid) from par.vis_i v join par.pkt pk on pk.eid = v.target_eid group by v.viewer_conn;
