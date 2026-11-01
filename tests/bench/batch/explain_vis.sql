-- EXPLAIN ANALYZE of the batched visibility statement at 2,000 players in steady state, 100 of them having just crossed a chunk border.  Rolled back.
begin;
select ibench.setup(2000, 100);
select count(*) from mc.visibility_batched();                       -- the initial build, everybody dirty
analyze mc.player; analyze mc.visible;
update mc.player set chunk_x = chunk_x + 1, vis_dirty = true where entity_id % 20 = 0;
\echo ---- the statement of mc.visibility_batched (r = 10, d = the 100 dirty entity ids), without the packet-building and output CTEs
explain (analyze, buffers, costs off, timing off)
with d as (select array_agg(entity_id) as ids from mc.player where vis_dirty and conn_id is not null),
on_ as materialized (select entity_id as eid, conn_id as conn, chunk_x as cx, chunk_z as cz from mc.player where conn_id is not null),
dd as materialized (select eid, conn, cx, cz from on_, d where eid = any (d.ids)),
want as materialized (
    select a.eid as viewer_eid, b.eid as target_eid, a.conn as viewer_conn from dd a join on_ b on b.eid <> a.eid and abs(a.cx - b.cx) <= 10 and abs(a.cz - b.cz) <= 10
    union
    select a.eid, b.eid, a.conn from dd b join on_ a on a.eid <> b.eid and abs(a.cx - b.cx) <= 10 and abs(a.cz - b.cz) <= 10),
ins as (select w.viewer_eid, w.target_eid, w.viewer_conn from want w
         where (select true from mc.visible v where v.viewer_eid = w.viewer_eid and v.target_eid = w.target_eid) is null),
cand as materialized (
    select v.viewer_eid, v.target_eid from mc.visible v, d where v.viewer_eid = any (d.ids)
    union
    select v.viewer_eid, v.target_eid from mc.visible v, d where v.target_eid = any (d.ids)),
del as (select v.viewer_conn, v.target_eid from mc.visible v join cand c on v.viewer_eid = c.viewer_eid and v.target_eid = c.target_eid
         where not exists (select 1 from want w where w.viewer_eid = v.viewer_eid and w.target_eid = v.target_eid))
select (select count(*) from ins), (select count(*) from del);
rollback;
