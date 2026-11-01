-- Optional (NOT applied by tools/migrate.sh): grid-cell neighbour search for the batched visibility refresh (flag `grid` of mc.server_tick_batched; variant 4 of docs/PERF-BATCH.md).
--
-- mc.visibility_batched() finds the neighbours of each player that changed chunk by comparing it with EVERY online player (a nested loop: dirty x online distance checks,
-- about 400,000 at 2,000 players with 100 crossing).  With an index on the chunk coordinates the same join becomes a range lookup.  The index is on columns that change only
-- when a player crosses a chunk border (about 5% of the movement updates in the benchmark), so mc.player's other updates stay HOT; but it IS an index on a hot table, which is
-- why this is opt-in.  The result (pairs, packets, order) is identical to mc.visibility_batched().
create index if not exists player_cell_idx on mc.player (chunk_x, chunk_z) where conn_id is not null;

create or replace function mc.visibility_batched_grid() returns table(added int, removed int) language plpgsql as $$
declare r int := least(mc.prop_int('view-distance'), 32); d int[] := array(select entity_id from mc.player where vis_dirty and conn_id is not null);
begin
    if cardinality(d) = 0 then
        update mc.player set vis_dirty = false where vis_dirty;
        added := 0; removed := 0; return next; return;
    end if;
    with dd as materialized (select entity_id as eid, conn_id as conn, chunk_x as cx, chunk_z as cz from mc.player where entity_id = any (d) and conn_id is not null),
    want as materialized (
        select a.eid as viewer_eid, b.entity_id as target_eid, a.conn as viewer_conn
          from dd a join mc.player b on b.conn_id is not null and b.entity_id <> a.eid and b.chunk_x between a.cx - r and a.cx + r and b.chunk_z between a.cz - r and a.cz + r
        union
        select a.entity_id, b.eid, a.conn_id
          from dd b join mc.player a on a.conn_id is not null and a.entity_id <> b.eid and a.chunk_x between b.cx - r and b.cx + r and a.chunk_z between b.cz - r and b.cz + r),
    ins as (
        insert into mc.visible (viewer_eid, target_eid, viewer_conn)
        select w.viewer_eid, w.target_eid, w.viewer_conn from want w
         where (select true from mc.visible v where v.viewer_eid = w.viewer_eid and v.target_eid = w.target_eid) is null
        returning viewer_eid, target_eid, viewer_conn),
    cand as materialized (
        select v.viewer_eid, v.target_eid from mc.visible v where v.viewer_eid = any (d)
        union
        select v.viewer_eid, v.target_eid from mc.visible v where v.target_eid = any (d)),
    del as (
        delete from mc.visible v using cand c
         where v.viewer_eid = c.viewer_eid and v.target_eid = c.target_eid
           and not exists (select 1 from want w where w.viewer_eid = v.viewer_eid and w.target_eid = v.target_eid)
        returning v.viewer_conn, v.target_eid),
    tp as materialized (select t.entity_id as eid, mc.pkt_add_player_entity(t.entity_id, t.uuid, t.sent_qx / 4096.0, t.sent_qy / 4096.0, t.sent_qz / 4096.0, t.sent_yaw, t.sent_pitch, t.sent_yaw) as pkt
                          from mc.player t where t.entity_id in (select target_eid from ins)),
    addp as (select i.viewer_conn, string_agg(tp.pkt, '\x'::bytea order by i.target_eid) as data from ins i join tp on tp.eid = i.target_eid group by i.viewer_conn),
    remp as (select viewer_conn, mc.pkt_remove_entities(array_agg(target_eid)) as data from del group by viewer_conn),
    clr as (update mc.player set vis_dirty = false where vis_dirty returning 1),
    q as (insert into mc.play_out (conn_id, data) select conn_id, data from (select viewer_conn as conn_id, 1 as ph, data from addp union all select viewer_conn, 2, data from remp) u order by ph returning 1)
    select (select count(*) from ins)::int, (select count(*) from del)::int into added, removed;
    return next;
end $$;
