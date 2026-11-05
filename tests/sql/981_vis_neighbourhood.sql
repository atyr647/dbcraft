-- mc.refresh_visibility_vis (sql/909, docs/PERF-CAPACITY.md) finds the players that can be paired with a dirty one in the chunk squares around the cells the dirty players stand in; the scan
-- version (mc.refresh_visibility_vis_scan) looks at every online player.  They must do EXACTLY the same: the same mc.visible, the same counts, the same packets per connection in the same
-- order, the same player rows afterwards.  Random states built the way the server builds them: a consistent relation (made by the scan version), then players move (some jump:
-- a teleport whose client is still waiting for its chunks, which the stale-viewer rule depends on), spectators, per-client view distances from 2 to 12, joiners.
update mc.server_property set value = 'true' where key = 'dbcraft.vanilla-tracker';
create temp table vn_last (added int, removed int, packets bigint);
create or replace function t.vn_case(p_seed float8, p_n int, p_side int, p_view int, p_dirty float8, p_spec float8, p_tp float8, p_far float8) returns text language plpgsql as $$
declare diff text := ''; a_new record; a_old record; k int;
begin
  perform setseed(p_seed);
  truncate mc.play_out, mc.visible, net.conn, mc.vtrk, mc.wp; delete from mc.player;
  update mc.game_state set game_time = 1000;
  update mc.server_property set value = p_view::text where key = 'view-distance';
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, vis_dirty, last_sent_tick, gamemode, keepalive_sent_tick, view_distance_req)
  select md5(i::text)::uuid, 'v' || i, i, i, px, 70, pz, 0, 0, floor(px / 16)::int, floor(pz / 16)::int, mc.quant(px), mc.quant(70), mc.quant(pz), true, 0,
         case when random() < p_spec then 3 else 1 end, 0, (array[null, 2, 3, 6, 10, 12])[1 + (random() * 5)::int]
    from (select i, random() * p_side * 16 as px, random() * p_side * 16 as pz from generate_series(1, p_n) i) g;
  insert into net.conn (conn_id, state, name, uuid, compression, entity_id, view_cx, view_cz, gamemode)
  select conn_id, 'play', name, uuid, -1, entity_id, chunk_x, chunk_z, gamemode from mc.player;
  perform count(*) from mc.refresh_visibility_vis_scan();             -- the consistent starting state (everybody dirty)
  truncate mc.play_out;
  update mc.player set vis_dirty = false, vis_x = x, vis_z = z;
  -- movers: a few blocks, or a jump (far: a teleport, the client's view stays where it was until net.stream_chunks)
  update mc.player set x = case when random() < p_far then random() * p_side * 16 else x + (random() - .5) * 12 end,
                       z = case when random() < p_far then random() * p_side * 16 else z + (random() - .5) * 12 end, vis_dirty = true
   where random() < p_dirty;
  update mc.player set chunk_x = floor(x / 16)::int, chunk_z = floor(z / 16)::int where vis_dirty;
  update mc.player set tp_ground_tick = 1002 where random() < p_tp;
  update mc.player set vis_dirty = true where tp_ground_tick is not null;
  -- some pairs of the relation that the rule no longer holds, or never held (state left by other code): both versions must treat them alike
  delete from mc.visible where random() < 0.03;
  insert into mc.visible (viewer_eid, target_eid, viewer_conn) select a.entity_id, b.entity_id, a.conn_id from mc.player a, mc.player b where a.entity_id <> b.entity_id and random() < 0.5 / p_n on conflict do nothing;
  create temp table if not exists t_p as select * from mc.player with no data;
  create temp table if not exists t_v as select * from mc.visible with no data;
  create temp table if not exists t_w as select * from mc.wp with no data;
  create temp table if not exists t_k as select * from mc.vtrk with no data;
  truncate t_p, t_v, t_w, t_k; insert into t_p select * from mc.player; insert into t_v select * from mc.visible; insert into t_w select * from mc.wp; insert into t_k select * from mc.vtrk;
  select * into a_new from mc.refresh_visibility_vis_nb();
  create temp table if not exists t_nv as select * from mc.visible with no data;
  create temp table if not exists t_np as select * from mc.player with no data;
  create temp table if not exists t_no (conn_id int, seq bigint, data bytea);
  truncate t_nv, t_np, t_no; insert into t_nv select * from mc.visible; insert into t_np select * from mc.player; insert into t_no select conn_id, seq, data from mc.play_out;
  perform set_config('session_replication_role', 'replica', true);        -- the join triggers of sql/900 would rewrite the restored rows
  truncate mc.play_out, mc.visible, mc.wp, mc.vtrk; delete from mc.player;
  insert into mc.player select * from t_p; insert into mc.visible select * from t_v; insert into mc.wp select * from t_w; insert into mc.vtrk select * from t_k;
  perform set_config('session_replication_role', 'origin', true);
  select * into a_old from mc.refresh_visibility_vis_scan();
  create temp table if not exists t_ov as select * from mc.visible with no data;
  create temp table if not exists t_op as select * from mc.player with no data;
  create temp table if not exists t_oo (conn_id int, seq bigint, data bytea);
  truncate t_ov, t_op, t_oo; insert into t_ov select * from mc.visible; insert into t_op select * from mc.player; insert into t_oo select conn_id, seq, data from mc.play_out;

  if a_new.added <> a_old.added or a_new.removed <> a_old.removed then diff := diff || format(' counts(%s,%s) vs (%s,%s)', a_new.added, a_new.removed, a_old.added, a_old.removed); end if;
  select count(*) into k from (select viewer_eid, target_eid, viewer_conn from t_nv except select viewer_eid, target_eid, viewer_conn from t_ov) x;
  if k > 0 then diff := diff || format(' visible: %s only in new', k); end if;
  select count(*) into k from (select viewer_eid, target_eid, viewer_conn from t_ov except select viewer_eid, target_eid, viewer_conn from t_nv) x;
  if k > 0 then diff := diff || format(' visible: %s only in old', k); end if;
  select count(*) into k from (select conn_id, array_agg(data order by seq) d from t_no group by conn_id except select conn_id, array_agg(data order by seq) from t_oo group by conn_id) x;
  if k > 0 then diff := diff || format(' packets: %s connections differ', k); end if;
  select count(*) into k from (select conn_id, array_agg(data order by seq) d from t_oo group by conn_id except select conn_id, array_agg(data order by seq) from t_no group by conn_id) x;
  if k > 0 then diff := diff || format(' packets: %s connections differ (old side)', k); end if;
  select count(*) into k from (select to_jsonb(p)::text from t_np p except select to_jsonb(p)::text from t_op p) x;
  if k > 0 then diff := diff || format(' player rows: %s differ', k); end if;
  if (select count(*) from t_nv) = 0 then diff := diff || ' (the test state is empty)'; end if;
  insert into vn_last values (a_new.added, a_new.removed, (select count(*) from t_no));
  return coalesce(nullif(diff, ''), 'same');
end $$;

select t.eq('sparse 150 players over 20 x 20 chunks, view 10, 20% move', t.vn_case(0.11, 150, 20, 10, 0.2, 0.05, 0.0, 0.0), 'same');
select t.eq('...with spectators', t.vn_case(0.12, 150, 20, 10, 0.2, 0.3, 0.0, 0.0), 'same');
select t.eq('...with jumps (teleports)', t.vn_case(0.13, 150, 20, 10, 0.3, 0.1, 0.0, 0.3), 'same');
select t.eq('...with teleported clients still waiting for their chunks (stale viewers)', t.vn_case(0.14, 150, 20, 10, 0.2, 0.1, 0.08, 0.2), 'same');
select t.eq('a crowd: 140 players in 3 x 3 chunks, view 10', t.vn_case(0.15, 140, 3, 10, 0.3, 0.05, 0.02, 0.0), 'same');
select t.eq('a crowd of spectators and survival players, view 4', t.vn_case(0.16, 140, 6, 4, 0.5, 0.4, 0.0, 0.1), 'same');
select t.eq('view distance 2 (squares of 3 chunks)', t.vn_case(0.17, 160, 14, 2, 0.4, 0.1, 0.0, 0.0), 'same');
select t.eq('view distance 32', t.vn_case(0.18, 130, 40, 32, 0.3, 0.1, 0.03, 0.1), 'same');
select t.eq('a small server (40 players, the locator bar is on)', t.vn_case(0.19, 40, 5, 6, 0.4, 0.1, 0.05, 0.1), 'same');
select t.eq('everybody moves', t.vn_case(0.20, 120, 10, 8, 1.0, 0.1, 0.0, 0.1), 'same');
select t.eq('nobody moves', t.vn_case(0.21, 120, 10, 8, 0.0, 0.1, 0.0, 0.0), 'same');
select t.eq('25 more random states', (select count(*) filter (where t.vn_case(0.5 + s::float8 / 100, 100 + s * 4, 4 + s, 2 + s % 11, (s % 7) / 7.0, 0.15, (s % 3) * 0.03, (s % 5) * 0.1) <> 'same') from generate_series(1, 25) s)::int, 0);
-- the comparisons above are not empty: across all of them pairs were added and removed and packets were sent
select t.is_true('the states exercised both adding and removing pairs (' || (select sum(added) from vn_last) || ' added, ' || (select sum(removed) from vn_last) || ' removed, ' || (select sum(packets) from vn_last) || ' packets)',
                 (select sum(added) > 100 and sum(removed) > 100 and sum(packets) > 100 from vn_last));
