-- pgbench script: one helper iteration = the fan-out compute of a tick for the current state, written to a scratch table (what a pipelined helper connection would do).
insert into par.helper_out select v.viewer_conn, string_agg(pk.data, '\x'::bytea order by pk.eid) from mc.visible v join par.pkt pk on pk.eid = v.target_eid group by v.viewer_conn;
delete from par.helper_out;
