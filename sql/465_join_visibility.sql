-- Login storms, round 6: mc.refresh_visibility must not depend on the planner's idea of how big mc.visible is.
--
-- Found by tests/bench/join/cliff.py with auto_explain: one storm in three (500 joiners in one tick) took 350 s instead of 10 s.  The statement that records new
-- pairs was `insert into mc.visible ... select ... from w where not exists (select 1 from mc.visible v where v.viewer_eid = w.viewer_eid and v.target_eid = w.target_eid)`.
-- When autovacuum or autoanalyze has recorded mc.visible as EMPTY (it is, at night on a quiet server, or right after a restart), the planner trusts that and picks a
-- nested loop with a sequential scan of mc.visible as the inner side: 0 pages, so it looks free.  But the statement inserts 250,500 rows into that very table, and every
-- one of the 250,500 inner scans reads all the pages inserted so far (the new rows are invisible to the snapshot but still have to be read): quadratic, 349 s.
-- `ON CONFLICT (viewer_eid, target_eid) DO NOTHING` uses the primary key whatever the statistics say, skips the pairs that exist exactly as the NOT EXISTS did, and the
-- pairs in w are unique (it comes from a UNION).  Everything else is a copy of the function in sql/432_tick_perf_world.sql.
-- A server that restarts and has 500 players reconnect in one tick is the case this protects.

create or replace function mc.refresh_visibility() returns table(added int, removed int) language plpgsql as $$
declare r int := least(mc.prop_int('view-distance'), 32); d int[]; wv int[]; wt int[]; wc int[];
begin
  added := 0; removed := 0;
  select coalesce(array_agg(entity_id), '{}') into d from mc.player where vis_dirty and conn_id is not null;
  if cardinality(d) > 0 then
    select coalesce(array_agg(q.v), '{}'), coalesce(array_agg(q.t), '{}'), coalesce(array_agg(q.c), '{}') into wv, wt, wc
      from (select a.entity_id as v, b.entity_id as t, a.conn_id as c
              from mc.player a join mc.player b on b.entity_id <> a.entity_id and abs(a.chunk_x - b.chunk_x) <= r and abs(a.chunk_z - b.chunk_z) <= r and b.conn_id is not null
             where a.entity_id = any (d) and a.conn_id is not null
            union
            select a.entity_id, b.entity_id, a.conn_id
              from mc.player b join mc.player a on a.entity_id <> b.entity_id and abs(a.chunk_x - b.chunk_x) <= r and abs(a.chunk_z - b.chunk_z) <= r and a.conn_id is not null
             where b.entity_id = any (d) and b.conn_id is not null) q;

    -- newly visible: add_entity at the position the other viewers were last told (shared delta base)
    with w as (select * from unnest(wv, wt, wc) as w(viewer_eid, target_eid, viewer_conn)),
    ins as (
      insert into mc.visible (viewer_eid, target_eid, viewer_conn)
      select w.viewer_eid, w.target_eid, w.viewer_conn from w
      on conflict (viewer_eid, target_eid) do nothing                      -- was: where not exists (select 1 from mc.visible v ...): a plan that could become quadratic
      returning viewer_eid, target_eid, viewer_conn),
    q as (
      insert into mc.play_out (conn_id, data)
      select i.viewer_conn, string_agg(mc.pkt_add_player_entity(t.entity_id, t.uuid, t.sent_qx / 4096.0, t.sent_qy / 4096.0, t.sent_qz / 4096.0, t.sent_yaw, t.sent_pitch, t.sent_yaw), '\x'::bytea order by t.entity_id)
        from ins i join mc.player t on t.entity_id = i.target_eid group by i.viewer_conn
      returning 1)
    select (select count(*) from ins) into added;

    -- no longer visible (only pairs involving a dirty player can have changed)
    with w as (select * from unnest(wv, wt) as w(viewer_eid, target_eid)),
    del as (
      delete from mc.visible v
       where (v.viewer_eid = any (d) or v.target_eid = any (d))
         and not exists (select 1 from w where w.viewer_eid = v.viewer_eid and w.target_eid = v.target_eid)
      returning v.viewer_conn, v.target_eid),
    q as (
      insert into mc.play_out (conn_id, data)
      select viewer_conn, mc.pkt_remove_entities(array_agg(target_eid order by target_eid)) from del group by viewer_conn
      returning 1)
    select (select count(*) from del) into removed;
  end if;
  update mc.player set vis_dirty = false where vis_dirty;
  return next;
end $$;
