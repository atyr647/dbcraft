-- Experiment 4: make each viewer an independent unit of work (a correlated aggregate per connection, driven by a parallel scan of net.conn), so workers do join + sort +
-- string_agg completely and only one small row per viewer travels to the leader.  Uses par.vis_i (index on viewer_conn, target_eid) and par.pkt.
\set ON_ERROR_STOP on
\pset format unaligned
\pset fieldsep ' | '
create temp table q(id int, name text, sql text);
insert into q values
 (1, 'baseline: hash join + sort + group aggregate',                    'select v.viewer_conn, string_agg(pk.data, ''\x''::bytea order by pk.eid) from par.vis_i v join par.pkt pk on pk.eid = v.target_eid group by v.viewer_conn'),
 (2, 'per-viewer correlated aggregate over net.conn',                    'select c.conn_id, (select string_agg(pk.data, ''\x''::bytea order by pk.eid) from par.vis_i v join par.pkt pk on pk.eid = v.target_eid where v.viewer_conn = c.conn_id) from net.conn c'),
 (3, 'per-viewer LATERAL subquery over net.conn',                        'select c.conn_id, l.blob from net.conn c cross join lateral (select string_agg(pk.data, ''\x''::bytea order by pk.eid) as blob from par.vis_i v join par.pkt pk on pk.eid = v.target_eid where v.viewer_conn = c.conn_id) l'),
 (4, 'per-viewer, packets looked up by index (no join node)',            'select c.conn_id, (select string_agg((select data from par.pkt pk where pk.eid = v.target_eid), ''\x''::bytea order by v.target_eid) from par.vis_i v where v.viewer_conn = c.conn_id) from net.conn c');
select 'connections: ' || count(*) from net.conn;
select q.id, q.name, s.median_ms as serial_ms, p.median_ms as par3_ms, round(s.median_ms / nullif(p.median_ms, 0), 2) as speedup, par.workers_used(q.sql, 3) as workers
  from q, lateral par.bench(q.sql, 0) s, lateral par.bench(q.sql, 3) p order by q.id;
