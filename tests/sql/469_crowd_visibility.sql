-- this test pins the classic (simplified) player broadcast of sql/430-468; the vanilla tracker of sql/900-910 has its own test (900_vis.sql)
update mc.server_property set value = 'false' where key = 'dbcraft.vanilla-tracker';
-- mc.refresh_visibility (sql/468): recomputing only the pairs whose in-range status changed must give EXACTLY what the full recomputation (mc.refresh_visibility_full, the
-- sql/465 code) gives: the same mc.visible, the same counts, the same packets per connection in the same order.  Random states, built the way the server builds them:
-- a consistent visibility relation (made by the full refresh), then players cross chunk borders the way the movement update records it (the chunk before the move in
-- vis_ocx/vis_ocz), sometimes with a joiner or a teleport in the same tick (old chunk unknown: the fallback must run and still be exact).
create or replace function t.vis_case(p_seed float8, p_n int, p_side int, p_view int, p_cross float8, p_far int, p_joiner boolean, p_tp boolean) returns text language plpgsql as $$
declare diff text := ''; a_new record; a_old record; nj int; k int;
begin
  perform setseed(p_seed);
  truncate mc.play_out, mc.visible; delete from mc.player;
  update mc.server_property set value = p_view::text where key = 'view-distance';
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, vis_dirty, last_sent_tick, gamemode, keepalive_sent_tick)
  select md5(i::text)::uuid, 'v' || i, i, i, px, -60, pz, 0, 0, floor(px / 16)::int, floor(pz / 16)::int, mc.quant(px), mc.quant(-60), mc.quant(pz), true, 0, 1, 0
    from (select i, case when i <= p_n - p_far then random() * p_side * 16 else 1000 + random() * 2000 end as px, case when i <= p_n - p_far then random() * p_side * 16 else random() * 2000 end as pz
            from generate_series(1, p_n) i) g;
  perform count(*) from mc.refresh_visibility_full();            -- the consistent starting state (everybody dirty, nothing known: the exact path)
  truncate mc.play_out;
  -- crossers: move to a neighbouring chunk (sometimes far), recording the chunk before the move as the movement update does
  update mc.player set vis_ocx = chunk_x, vis_ocz = chunk_z, vis_dirty = true,
         chunk_x = chunk_x + (random() * 4 - 2)::int, chunk_z = chunk_z + (case when random() < 0.1 then 40 else (random() * 4 - 2)::int end)
   where random() < p_cross;
  if p_joiner then
    nj := p_n + 1;
    insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, vis_dirty, last_sent_tick, gamemode, keepalive_sent_tick)
    values (md5(nj::text)::uuid, 'vj', nj, nj, 8, -60, 8, 0, 0, 0, 0, mc.quant(8), mc.quant(-60), mc.quant(8), true, 0, 1, 0);
  end if;
  if p_tp then        -- a teleport: dirty, old chunk not recorded
    update mc.player set chunk_x = chunk_x + 3, vis_dirty = true where entity_id = 2 and not vis_dirty;
  end if;
  create temp table if not exists t_p as select * from mc.player with no data;
  create temp table if not exists t_v as select * from mc.visible with no data;
  truncate t_p, t_v; insert into t_p select * from mc.player; insert into t_v select * from mc.visible;
  -- the new refresh
  select * into a_new from mc.refresh_visibility();
  create temp table if not exists t_nv as select * from mc.visible with no data;
  create temp table if not exists t_no (conn_id int, seq bigint, data bytea);
  truncate t_nv, t_no; insert into t_nv select * from mc.visible; insert into t_no select conn_id, seq, data from mc.play_out;
  -- restore the snapshot, then the exact one
  truncate mc.play_out, mc.visible; delete from mc.player;
  insert into mc.player select * from t_p; insert into mc.visible select * from t_v;
  select * into a_old from mc.refresh_visibility_full();
  create temp table if not exists t_ov as select * from mc.visible with no data;
  create temp table if not exists t_oo (conn_id int, seq bigint, data bytea);
  truncate t_ov, t_oo; insert into t_ov select * from mc.visible; insert into t_oo select conn_id, seq, data from mc.play_out;

  if a_new.added <> a_old.added or a_new.removed <> a_old.removed then diff := diff || format(' counts(%s,%s) vs (%s,%s)', a_new.added, a_new.removed, a_old.added, a_old.removed); end if;
  select count(*) into k from (select viewer_eid, target_eid, viewer_conn from t_nv except select viewer_eid, target_eid, viewer_conn from t_ov) x;
  if k > 0 then diff := diff || format(' visible: %s only in new', k); end if;
  select count(*) into k from (select viewer_eid, target_eid, viewer_conn from t_ov except select viewer_eid, target_eid, viewer_conn from t_nv) x;
  if k > 0 then diff := diff || format(' visible: %s only in old', k); end if;
  select count(*) into k from (select conn_id, array_agg(data order by seq) d from t_no group by conn_id except select conn_id, array_agg(data order by seq) from t_oo group by conn_id) x;
  if k > 0 then diff := diff || format(' packets: %s connections differ', k); end if;
  select count(*) into k from (select conn_id, array_agg(data order by seq) d from t_oo group by conn_id except select conn_id, array_agg(data order by seq) from t_no group by conn_id) x;
  if k > 0 then diff := diff || format(' packets: %s connections differ (old side)', k); end if;
  if exists (select 1 from mc.player where vis_ocx is not null) then diff := diff || ' vis_ocx not cleared'; end if;
  return coalesce(nullif(diff, ''), 'same');
end $$;

select t.eq('crowd 80 players in 3x3 chunks, view 4, 30% cross', t.vis_case(0.11, 80, 3, 4, 0.3, 0, false, false), 'same');
select t.eq('crowd 120 players in 2x2 chunks, view 10, 50% cross', t.vis_case(0.12, 120, 2, 10, 0.5, 0, false, false), 'same');
select t.eq('partial overlap: 100 players in 8x8 chunks, view 2, 20% cross', t.vis_case(0.13, 100, 8, 2, 0.2, 0, false, false), 'same');
select t.eq('view 1 in 6x6 chunks, 40% cross', t.vis_case(0.14, 90, 6, 1, 0.4, 0, false, false), 'same');
select t.eq('crowd plus 25 players far away, view 3', t.vis_case(0.15, 100, 4, 3, 0.3, 25, false, false), 'same');
select t.eq('everybody crosses', t.vis_case(0.16, 70, 4, 3, 1.0, 0, false, false), 'same');
select t.eq('nobody crosses', t.vis_case(0.17, 60, 3, 3, 0.0, 0, false, false), 'same');
select t.eq('sparse world: 50 players over 30x30 chunks, view 3', t.vis_case(0.18, 50, 30, 3, 0.4, 0, false, false), 'same');
select t.eq('a joiner in the same tick (old chunk unknown: the exact path)', t.vis_case(0.19, 80, 3, 4, 0.3, 0, true, false), 'same');
select t.eq('a teleport in the same tick (old chunk unknown: the exact path)', t.vis_case(0.2, 80, 3, 4, 0.3, 0, false, true), 'same');
select t.eq('joiner and teleport and crossers together', t.vis_case(0.21, 90, 4, 3, 0.4, 10, true, true), 'same');
select t.eq('mixed: 30 random cases', (select string_agg(t.vis_case(s * 0.017, 40 + s * 3, 1 + s % 7, 1 + s % 6, (s % 5) / 4.0, s % 4, s % 7 = 0, s % 11 = 0), ',') from generate_series(1, 30) s) ~ '^(same,)*same$', true);

-- which path ran: the fast one reports counts without calling the full function (observable: a state with a joiner must take the full path, a plain crossing must not)
select t.is_true('the movement update records the chunk before the move (the fast path is reachable in the real server)', (
  select position('vis_ocx' in pg_get_functiondef('mc.apply_player_moves(bigint)'::regprocedure)) > 0));
select t.is_true('mc.on_join clears the recorded chunk (a rejoining player must not carry a stale one)', (
  select position('vis_ocx = null' in pg_get_functiondef('mc.on_join(integer,uuid,text,boolean)'::regprocedure)) > 0));
