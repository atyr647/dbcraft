-- Experiment 1: best case speedup of each read-only computation of the 500-player tick when run standalone as one SELECT with workers = 0 vs 3 (planner costs forced to 0,
-- so a parallel plan is used whenever one is possible).  Median of 21 runs each.
\set ON_ERROR_STOP on
\pset format unaligned
\pset fieldsep ' | '
create temp table q(id int, name text, sql text);
insert into q values
 (1, 'floor: count(*) of 500 players',                'select count(*) from mc.player'),
 (2, 'packet build for 500 movers (par.pk)',          'select count(*), sum(octet_length(data)) from par.pk'),
 (3, 'fan-out: visible x pk, string_agg per viewer',  'select v.viewer_conn, string_agg(pk.data, ''\x''::bytea order by pk.eid) from mc.visible v join par.pk pk on pk.eid = v.target_eid group by v.viewer_conn'),
 (4, 'fan-out without ORDER BY in the aggregate',     'select v.viewer_conn, string_agg(pk.data, ''\x''::bytea) from mc.visible v join par.pk pk on pk.eid = v.target_eid group by v.viewer_conn'),
 (5, 'fan-out join only, count',                      'select count(*), sum(octet_length(pk.data)) from mc.visible v join par.pk pk on pk.eid = v.target_eid'),
 (6, 'visibility join, all 500 dirty (join-storm like)', 'select count(*) from mc.player a join mc.player b on b.entity_id <> a.entity_id and abs(a.chunk_x - b.chunk_x) <= 10 and abs(a.chunk_z - b.chunk_z) <= 10 and b.conn_id is not null where a.conn_id is not null');
select 'visible rows: ' || count(*) from mc.visible;
select 'players: ' || count(*) from mc.player where conn_id is not null;
select 'pk bytes per tick: ' || sum(octet_length(data)) from par.pk;
select q.id, q.name, s.median_ms as serial_ms, p.median_ms as par3_ms, round(s.median_ms / nullif(p.median_ms, 0), 2) as speedup, par.workers_used(q.sql, 3) as workers
  from q, lateral par.bench(q.sql, 0) s, lateral par.bench(q.sql, 3) p order by q.id;
