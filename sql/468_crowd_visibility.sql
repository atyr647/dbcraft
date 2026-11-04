-- Visibility refresh for crowds: recompute only the pairs whose in-range status CHANGED.
--
-- mc.refresh_visibility (sql/465) recomputes every pair of every player that crossed a chunk border (about 2 x N pairs per crosser), tries to insert all of them
-- (INSERT ... ON CONFLICT DO NOTHING) and scans mc.visible for the pairs to delete.  In a crowd nearly all of those pairs are unchanged: measured with 28 crossers in a
-- 2,000-player crowd: the wanted pairs 94 ms, the 111,000 conflicting inserts 739 ms, the delete scan 870 ms; with no pair changing at all.
--
-- The rule is a function of the chunk coordinates (|dx| <= r and |dz| <= r), so a pair changes only when it is in range after the move and was not before, or the
-- other way round.  The chunk BEFORE the move is needed: mc.player.vis_ocx/vis_ocz holds it, written by the movement update (sql/431) at the moment a player becomes
-- dirty, cleared here (and by mc.on_join).  Whoever else marks a player dirty (/tp, a join) leaves it NULL, and then the exact old code runs
-- (mc.refresh_visibility_full below, a copy of sql/465): a refresh with any such player is as before.  tests/sql/469_crowd_visibility.sql compares both on random states.
alter table mc.player add column if not exists vis_ocx int, add column if not exists vis_ocz int;

create or replace function mc.refresh_visibility_full() returns table(added int, removed int) language plpgsql as $$
declare r int := least(mc.prop_int('view-distance'), 32); d int[]; wv int[]; wt int[]; wc int[]; vison boolean := mc.vis_on();       -- (sql/900: a spectator is seen only by spectators)
begin
  added := 0; removed := 0;
  select coalesce(array_agg(entity_id), '{}') into d from mc.player where vis_dirty and conn_id is not null;
  if cardinality(d) > 0 then
    select coalesce(array_agg(q.v), '{}'), coalesce(array_agg(q.t), '{}'), coalesce(array_agg(q.c), '{}') into wv, wt, wc
      from (select a.entity_id as v, b.entity_id as t, a.conn_id as c
              from mc.player a join mc.player b on b.entity_id <> a.entity_id and abs(a.chunk_x - b.chunk_x) <= r and abs(a.chunk_z - b.chunk_z) <= r and b.conn_id is not null
                                                  and (not vison or b.gamemode <> 3 or a.gamemode = 3)
             where a.entity_id = any (d) and a.conn_id is not null
            union
            select a.entity_id, b.entity_id, a.conn_id
              from mc.player b join mc.player a on a.entity_id <> b.entity_id and abs(a.chunk_x - b.chunk_x) <= r and abs(a.chunk_z - b.chunk_z) <= r and a.conn_id is not null
                                                  and (not vison or b.gamemode <> 3 or a.gamemode = 3)
             where b.entity_id = any (d) and b.conn_id is not null) q;

    -- newly visible: add_entity at the position the other viewers were last told (shared delta base)
    with w as (select * from unnest(wv, wt, wc) as w(viewer_eid, target_eid, viewer_conn)),
    ins as (
      insert into mc.visible (viewer_eid, target_eid, viewer_conn)
      select w.viewer_eid, w.target_eid, w.viewer_conn from w
      on conflict (viewer_eid, target_eid) do nothing                      -- was: where not exists (select 1 from mc.visible v ...): a plan that could become quadratic
      returning viewer_eid, target_eid, viewer_conn),
    tb as materialized (select t.entity_id as eid, mc.pairing_bundle(t) as b from mc.player t where t.entity_id in (select target_eid from ins)),      -- one bundle per target, not per viewer (sql/903)
    q as (
      insert into mc.play_out (conn_id, data)
      select i.viewer_conn, string_agg(tb.b, '\x'::bytea order by tb.eid)
        from ins i join tb on tb.eid = i.target_eid group by i.viewer_conn
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
  update mc.player set vis_dirty = false, vis_ocx = null, vis_ocz = null where vis_dirty;
  return next;
end $$;

create or replace function mc.refresh_visibility() returns table(added int, removed int) language plpgsql as $$
declare r int := least(mc.prop_int('view-distance'), 32); n_dirty int; n_unknown int; av int[]; at_ int[]; ac int[]; rv int[]; rt int[]; vison boolean := mc.vis_on();
begin
  added := 0; removed := 0;
  if vison then return query select * from mc.refresh_visibility_vis(); return; end if;         -- the exact per-client rule (sql/909)
  select count(*), count(*) filter (where vis_ocx is null) into n_dirty, n_unknown from mc.player where vis_dirty and conn_id is not null;
  if n_unknown > 0 then                                  -- a joiner, a teleport: the chunk the pairs were computed from is not known: the exact full recomputation
    return query select * from mc.refresh_visibility_full();
    return;
  end if;
  if n_dirty > 0 then
    with pc as materialized (                            -- every online player: the chunk now, and the chunk its pairs in mc.visible were computed from
      select entity_id as eid, conn_id, chunk_x as ncx, chunk_z as ncz, gamemode as gm,
             case when vis_dirty then vis_ocx else chunk_x end as ocx, case when vis_dirty then vis_ocz else chunk_z end as ocz, vis_dirty as dirty
        from mc.player where conn_id is not null),
    ch as (                                              -- ordered pairs (viewer, target) with a dirty player in them whose in-range status changed; each pair once
      select a.eid as v, b.eid as t, a.conn_id as c, (abs(a.ncx - b.ncx) <= r and abs(a.ncz - b.ncz) <= r) as now_in
        from pc a join pc b on b.eid <> a.eid and (not vison or b.gm <> 3 or a.gm = 3)
       where a.dirty and ((abs(a.ncx - b.ncx) <= r and abs(a.ncz - b.ncz) <= r) <> (abs(a.ocx - b.ocx) <= r and abs(a.ocz - b.ocz) <= r))
      union all
      select a.eid, b.eid, a.conn_id, (abs(a.ncx - b.ncx) <= r and abs(a.ncz - b.ncz) <= r)
        from pc a join pc b on b.eid <> a.eid and (not vison or b.gm <> 3 or a.gm = 3)
       where b.dirty and not a.dirty and ((abs(a.ncx - b.ncx) <= r and abs(a.ncz - b.ncz) <= r) <> (abs(a.ocx - b.ocx) <= r and abs(a.ocz - b.ocz) <= r)))
    select coalesce(array_agg(v) filter (where now_in), '{}'), coalesce(array_agg(t) filter (where now_in), '{}'), coalesce(array_agg(c) filter (where now_in), '{}'),
           coalesce(array_agg(v) filter (where not now_in), '{}'), coalesce(array_agg(t) filter (where not now_in), '{}')
      into av, at_, ac, rv, rt from ch;

    if cardinality(av) > 0 then                          -- newly visible: add_entity at the position the other viewers were last told (shared delta base)
      with ins as (
        insert into mc.visible (viewer_eid, target_eid, viewer_conn)
        select w.v, w.t, w.c from unnest(av, at_, ac) as w(v, t, c)
        on conflict (viewer_eid, target_eid) do nothing
        returning viewer_eid, target_eid, viewer_conn),
      tb as materialized (select t.entity_id as eid, mc.pairing_bundle(t) as b from mc.player t where t.entity_id in (select target_eid from ins)),
      q as (
        insert into mc.play_out (conn_id, data)
        select i.viewer_conn, string_agg(tb.b, '\x'::bytea order by tb.eid)
          from ins i join tb on tb.eid = i.target_eid group by i.viewer_conn
        returning 1)
      select (select count(*) from ins) into added;
    end if;
    if cardinality(rv) > 0 then                          -- no longer visible
      with del as (
        delete from mc.visible x using unnest(rv, rt) as w(v, t) where x.viewer_eid = w.v and x.target_eid = w.t
        returning x.viewer_conn, x.target_eid),
      q as (
        insert into mc.play_out (conn_id, data)
        select viewer_conn, mc.pkt_remove_entities(array_agg(target_eid order by target_eid)) from del group by viewer_conn
        returning 1)
      select (select count(*) from del) into removed;
    end if;
  end if;
  update mc.player set vis_dirty = false, vis_ocx = null, vis_ocz = null where vis_dirty;
  return next;
end $$;
