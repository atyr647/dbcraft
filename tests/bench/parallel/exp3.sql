-- Experiment 3: can a layout change let the whole fan-out (join + sort + string_agg per viewer) run inside the workers?
--   A. mc.visible as it is                       (parallel join and sort, serial Gather Merge + aggregate in the leader)
--   B. a copy partitioned by hash(viewer_conn)   (partitionwise aggregate: each worker aggregates whole viewers, Gather only ships one row per viewer)
--   C. serial only: an index on (viewer_conn, target_eid) so the aggregate streams in order and the 23 ms sort disappears (no parallelism needed)
\set ON_ERROR_STOP on
\pset format unaligned
\pset fieldsep ' | '
drop table if exists par.vis_p;
create table par.vis_p (viewer_eid int, target_eid int, viewer_conn int) partition by hash (viewer_conn);
do $$ begin for i in 0..7 loop execute format('create table par.vis_p%s partition of par.vis_p for values with (modulus 8, remainder %s)', i, i); end loop; end $$;
insert into par.vis_p select viewer_eid, target_eid, viewer_conn from mc.visible;
analyze par.vis_p;
drop table if exists par.vis_i;
create table par.vis_i as select viewer_eid, target_eid, viewer_conn from mc.visible;
create index on par.vis_i (viewer_conn, target_eid);
analyze par.vis_i;
select 'visible rows: ' || count(*) || ', packets: ' || (select count(*) from par.pkt) from mc.visible;
create temp table q(id int, name text, sql text);
insert into q values
 (1, 'A. mc.visible (heap, as is)',                 'select v.viewer_conn, string_agg(pk.data, ''\x''::bytea order by pk.eid) from mc.visible v join par.pkt pk on pk.eid = v.target_eid group by v.viewer_conn'),
 (2, 'B. hash-partitioned by viewer_conn x8',        'select v.viewer_conn, string_agg(pk.data, ''\x''::bytea order by pk.eid) from par.vis_p v join par.pkt pk on pk.eid = v.target_eid group by v.viewer_conn'),
 (3, 'C. heap + index (viewer_conn, target_eid)',    'select v.viewer_conn, string_agg(pk.data, ''\x''::bytea order by v.target_eid) from par.vis_i v join par.pkt pk on pk.eid = v.target_eid group by v.viewer_conn');
-- partitionwise aggregation is off by default
set enable_partitionwise_aggregate = on; set enable_partitionwise_join = on;
select q.id, q.name, s.median_ms as serial_ms, p.median_ms as par3_ms, round(s.median_ms / nullif(p.median_ms, 0), 2) as speedup, par.workers_used(q.sql, 3) as workers
  from q, lateral par.bench(q.sql, 0) s, lateral par.bench(q.sql, 3) p order by q.id;
