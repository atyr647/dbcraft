-- sql/465: mc.refresh_visibility records new pairs with ON CONFLICT DO NOTHING instead of an anti-join against the table it inserts into.
--   part 1: same result as the original (copied below as t.refresh_visibility_orig) on a scenario with joins and movement
--   part 2: the regression: with mc.visible recorded as EMPTY by ANALYZE (what autovacuum does on a quiet server), 400 players at one spot must not take minutes
\ir ../../sql/465_join_visibility.sql

create or replace function t.refresh_visibility_orig() returns table(added int, removed int) language plpgsql as $$
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
    with w as (select * from unnest(wv, wt, wc) as w(viewer_eid, target_eid, viewer_conn)),
    ins as (
      insert into mc.visible (viewer_eid, target_eid, viewer_conn)
      select w.viewer_eid, w.target_eid, w.viewer_conn from w
       where not exists (select 1 from mc.visible v where v.viewer_eid = w.viewer_eid and v.target_eid = w.target_eid)
      returning viewer_eid, target_eid, viewer_conn),
    q as (
      insert into mc.play_out (conn_id, data)
      select i.viewer_conn, string_agg(mc.pkt_add_player_entity(t.entity_id, t.uuid, t.sent_qx / 4096.0, t.sent_qy / 4096.0, t.sent_qz / 4096.0, t.sent_yaw, t.sent_pitch, t.sent_yaw), '\x'::bytea order by t.entity_id)
        from ins i join mc.player t on t.entity_id = i.target_eid group by i.viewer_conn
      returning 1)
    select (select count(*) from ins) into added;
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

------------------------------------------------------------------------------------------------ part 1: same result as the original
-- 70 players in a 14 x 14 chunk area (view distance 3), refresh, move 20 of them far away and 15 next to each other, refresh again, remove 5 players, refresh again.
-- Returns the digest of everything the three refreshes produced.  Positions depend only on the entity id, so both variants see the same world.
create or replace function t.scenario(p_variant text) returns table (step text, digest text) language plpgsql as $$
declare a int; rm int;
begin
    truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick;
    delete from mc.player;
    perform setval('mc.entity_id_seq', 1, false);
    update mc.server_property set value = '3' where key = 'view-distance';
    perform mc.on_join(g, ('00000000-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid, 'V' || g) from generate_series(1, 70) g;
    update mc.player set chunk_x = (entity_id * 7) % 14, chunk_z = (entity_id * 11) % 14, vis_dirty = true where conn_id is not null;
    truncate mc.play_out;
    if p_variant = 'orig' then select r.added, r.removed into a, rm from t.refresh_visibility_orig() r; else select r.added, r.removed into a, rm from mc.refresh_visibility() r; end if;
    step := '1 join: added ' || a || ' removed ' || rm; digest := (select md5(string_agg(conn_id || ':' || encode(data, 'hex'), ',' order by conn_id, seq)) from mc.play_out); return next;
    step := '1 pairs'; digest := (select md5(string_agg(viewer_eid || '>' || target_eid || '@' || viewer_conn, ',' order by viewer_eid, target_eid)) from mc.visible); return next;
    truncate mc.play_out;
    update mc.player set chunk_x = 200 + entity_id, chunk_z = 200, vis_dirty = true where entity_id <= 20;                  -- 20 leave everybody's range
    update mc.player set chunk_x = 5, chunk_z = 5, vis_dirty = true where entity_id between 21 and 35;                      -- 15 gather
    if p_variant = 'orig' then select r.added, r.removed into a, rm from t.refresh_visibility_orig() r; else select r.added, r.removed into a, rm from mc.refresh_visibility() r; end if;
    step := '2 move: added ' || a || ' removed ' || rm; digest := (select md5(string_agg(conn_id || ':' || encode(data, 'hex'), ',' order by conn_id, seq)) from mc.play_out); return next;
    step := '2 pairs'; digest := (select md5(string_agg(viewer_eid || '>' || target_eid || '@' || viewer_conn, ',' order by viewer_eid, target_eid)) from mc.visible); return next;
    truncate mc.play_out;
    update mc.player set conn_id = null, vis_dirty = false where entity_id between 36 and 40;                                -- five disconnect
    update mc.player set vis_dirty = true where conn_id is not null and entity_id between 21 and 35;
    if p_variant = 'orig' then select r.added, r.removed into a, rm from t.refresh_visibility_orig() r; else select r.added, r.removed into a, rm from mc.refresh_visibility() r; end if;
    step := '3 leave: added ' || a || ' removed ' || rm; digest := (select md5(string_agg(conn_id || ':' || encode(data, 'hex'), ',' order by conn_id, seq)) from mc.play_out); return next;
    step := '3 pairs'; digest := (select md5(string_agg(viewer_eid || '>' || target_eid || '@' || viewer_conn, ',' order by viewer_eid, target_eid)) from mc.visible); return next;
end $$;

create table t.vis_orig as select * from t.scenario('orig');
create table t.vis_new  as select * from t.scenario('new');
select t.is_true('the scenario really exercises both paths (pairs are added, then removed)',
  (select count(*) from t.vis_orig where step like '1 join: added %' and step not like '%added 0 %') = 1 and (select count(*) from t.vis_orig where step like '2 move:%' and step not like '%removed 0') = 1);
select t.eq('every step gives the same added/removed counts and the same bytes queued', (select count(*)::int from t.vis_orig o join t.vis_new n using (step) where o.digest is distinct from n.digest), 0);
select t.eq('...over all 6 steps', (select count(*)::int from t.vis_new), 6);
select t.is_true('...with real content (at least 4 different non-NULL digests; a step that queues nothing has none)', (select count(distinct digest) >= 4 from t.vis_new));

------------------------------------------------------------------------------------------------ part 2: the cliff
-- mc.visible recorded as empty, a crowd arrives in one tick: the plan must not depend on that
create or replace function t.crowd(p_n int) returns void language plpgsql as $$
begin
    truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick;
    delete from mc.player;
    perform setval('mc.entity_id_seq', 1, false);
    update mc.server_property set value = '10' where key = 'view-distance';
    perform mc.on_join(g, ('00000000-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid, 'C' || g) from generate_series(1, p_n) g;
    update mc.player set chunk_x = 0, chunk_z = 0, vis_dirty = true where conn_id is not null;
    truncate mc.play_out;
end $$;
select t.crowd(400);
truncate mc.visible;
analyze mc.visible;                                                           -- the statistics now say: no rows, no pages
select t.eq('the statistics say the table is empty', (select reltuples::int from pg_class where oid = 'mc.visible'::regclass), 0);
create table t.cliff as select clock_timestamp() as t0;
select r.added from mc.refresh_visibility() r;
create table t.cliff2 as select extract(epoch from clock_timestamp() - (select t0 from t.cliff)) as secs;
select t.eq('400 players at one spot: 159,600 pairs recorded', (select count(*)::int from mc.visible), 400 * 399);
select t.is_true('...in well under 30 s with empty statistics (the anti-join plan took minutes at this size)', (select secs < 30 from t.cliff2));
