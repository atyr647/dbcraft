-- Experiment 2: the fan-out with the packets already materialised (as the real statement does with its MATERIALIZED CTE): par.pkt = 500 packets (a work table).
\set ON_ERROR_STOP on
\pset format unaligned
\pset fieldsep ' | '
drop table if exists par.pkt;
create table par.pkt as select * from par.pk;
create unique index on par.pkt(eid);
analyze par.pkt;
create temp table q(id int, name text, sql text);
insert into q values
 (1, 'fan-out: visible x pkt, string_agg(order by) per viewer', 'select v.viewer_conn, string_agg(pk.data, ''\x''::bytea order by pk.eid) from mc.visible v join par.pkt pk on pk.eid = v.target_eid group by v.viewer_conn'),
 (2, 'same, no ORDER BY inside the aggregate',                   'select v.viewer_conn, string_agg(pk.data, ''\x''::bytea) from mc.visible v join par.pkt pk on pk.eid = v.target_eid group by v.viewer_conn'),
 (3, 'same, array_agg of the packets (no concatenation)',        'select v.viewer_conn, array_agg(pk.data order by pk.eid) from mc.visible v join par.pkt pk on pk.eid = v.target_eid group by v.viewer_conn'),
 (4, 'join only: count and bytes',                               'select count(*), sum(octet_length(pk.data)) from mc.visible v join par.pkt pk on pk.eid = v.target_eid');
select q.id, q.name, s.median_ms as serial_ms, p.median_ms as par3_ms, round(s.median_ms / nullif(p.median_ms, 0), 2) as speedup, par.workers_used(q.sql, 3) as workers
  from q, lateral par.bench(q.sql, 0) s, lateral par.bench(q.sql, 3) p order by q.id;
-- unforced (default planner costs, default thresholds): does Postgres choose a parallel plan on its own for these sizes?
select 'default costs, 3 workers allowed: ' || par.workers_used(sql, 3) from q where id = 1;
