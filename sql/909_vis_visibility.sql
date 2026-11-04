-- Player visibility, part 10: who sees whom, per client.  ChunkMap.TrackedEntity.updatePlayer (26.3, javap -c), compared with the real server (tests/e2e/vis_probe.py: range, view):
--
--   A viewer V is sent a player T (add_entity bundle) while
--       (V.x - T.x)^2 + (V.z - T.z)^2 <= R^2,   R = min(scaled tracking range of T, V's view distance * 16)  (blocks, horizontal, exact positions)
--       and T's chunk is one V has loaded (always true inside that circle)
--       and T is not a spectator unless V is one (ServerPlayer.broadcastToPlayer)
--   The tracking range of a player is EntityType.PLAYER.clientTrackingRange = 32 chunks = 512 blocks, scaled by entity-broadcast-range-percentage (DedicatedServer:
--   percentage * 512 / 100, integer arithmetic).  V's view distance is the one its client asked for in client_information (a client that never said has vanilla's default, 2),
--   clamped to 2 .. the server's view-distance (ChunkMap.getPlayerViewDistance).  The same view distance sizes the chunk square the client is sent (radius view distance + 1).
-- Vanilla re-evaluates a pair when either player sends a movement packet (ChunkMap.move) or an entity changes section.  Here a player is re-evaluated when its game mode changed
-- (sql/903), it joined, was teleported, changed chunk, moved 4 blocks from where it was last evaluated, or its client changed the view distance: a pair therefore can
-- change up to 4 blocks late per player, i.e. a player appears or disappears up to 8 blocks away from the exact circle.  The exact circle is what is tested each time.
-- NOT modelled: the asymmetry of vanilla's trigger (a pair can be seen one way for a moment), chunks still pending delivery.

alter table mc.player add column if not exists vis_x float8, add column if not exists vis_z float8;     -- the position the player's pairs were last evaluated at

-- the view distance in effect for a player (chunks): what its client asked for, clamped; the server's with the classic broadcast
create or replace function mc.view_dist(p_req int) returns int language sql stable as $$
  select case when mc.vis_on() then greatest(2, least(coalesce(p_req, 2), mc.prop_int('view-distance'))) else mc.prop_int('view-distance') end $$;

-- the radius of the chunk square of a connection (view distance + 1), or p_default when there is no game player for it
create or replace function mc.conn_view_r(p_conn int, p_default int) returns int language sql stable as $$
  select coalesce((select mc.view_dist(p.view_distance_req) + 1 from mc.player p where p.conn_id = p_conn), p_default) $$;

-- the pairs of every player that has to be re-evaluated (vis_dirty), with the exact rule; adds and removes what changed
create or replace function mc.refresh_visibility_vis() returns table(added int, removed int) language plpgsql as $$
declare srv int := least(mc.prop_int('view-distance'), 32); trk float8 := ((coalesce(mc.prop_int('entity-broadcast-range-percentage'), 100) * 512) / 100)::float8;
        d int[]; wv int[]; wt int[]; wc int[]; av int[]; at_ int[]; ac int[];
begin
  added := 0; removed := 0;
  perform mc.vis_wp_pass((select game_time from mc.game_state), 1);       -- the locator bar's updates for this tick's movement and teleports go out first (vanilla sends them when the movement packet is handled; the tracker's pairing comes after)
  perform mc.vis_recheck_mark();
  select coalesce(array_agg(entity_id), '{}') into d from mc.player where vis_dirty and conn_id is not null;
  if cardinality(d) > 0 then
    with pc as materialized (
      select p.entity_id as eid, p.conn_id as conn, p.x, p.z, p.chunk_x as cx, p.chunk_z as cz, (p.gamemode = 3) as spec,
             least(greatest(2, least(coalesce(p.view_distance_req, 2), srv)) * 16.0, trk) as rng, greatest(2, least(coalesce(p.view_distance_req, 2), srv)) as vd,
             (p.entity_id = any (d)) as dirty,
             coalesce((c.view_cx, c.view_cz) <> (p.chunk_x, p.chunk_z), false) as stale           -- the client has not been sent the chunks of its new position yet (net.stream_chunks runs after this)
        from mc.player p left join net.conn c on c.conn_id = p.conn_id where p.conn_id is not null),
    w as (
      select a.eid as v, b.eid as t, a.conn as c, a.stale
        from pc a join pc b on b.eid <> a.eid and (not b.spec or a.spec)
                              and abs(a.cx - b.cx) <= a.vd + 1 and abs(a.cz - b.cz) <= a.vd + 1
                              and (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2 <= a.rng ^ 2
       where a.dirty or b.dirty)
    select coalesce(array_agg(w.v), '{}'), coalesce(array_agg(w.t), '{}'), coalesce(array_agg(w.c), '{}'),
           coalesce(array_agg(w.v) filter (where not w.stale), '{}'), coalesce(array_agg(w.t) filter (where not w.stale), '{}'), coalesce(array_agg(w.c) filter (where not w.stale), '{}')
      into wv, wt, wc, av, at_, ac from w;

    -- a viewer whose client is still waiting for the chunks of its new position is shown nobody yet: vanilla sends the chunks, then the entities (ChunkMap.tick: chunk tracking first)
    with w as (select * from unnest(av, at_, ac) as w(viewer_eid, target_eid, viewer_conn)),
    ins as (
      insert into mc.visible (viewer_eid, target_eid, viewer_conn)
      select w.viewer_eid, w.target_eid, w.viewer_conn from w
      on conflict (viewer_eid, target_eid) do nothing
      returning viewer_eid, target_eid, viewer_conn),
    tb as materialized (select t.entity_id as eid, mc.pairing_bundle(t) as b from mc.player t where t.entity_id in (select target_eid from ins)),
    q as (
      insert into mc.play_out (conn_id, data)
      select i.viewer_conn, string_agg(tb.b, '\x'::bytea order by tb.eid) from ins i join tb on tb.eid = i.target_eid group by i.viewer_conn
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
  update mc.player p set vis_dirty = false, vis_ocx = null, vis_ocz = null, vis_x = x, vis_z = z
   where vis_dirty and not exists (select 1 from net.conn c where c.conn_id = p.conn_id and (c.view_cx, c.view_cz) <> (p.chunk_x, p.chunk_z));      -- (a stale viewer is looked at again next tick)
  return next;
end $$;
