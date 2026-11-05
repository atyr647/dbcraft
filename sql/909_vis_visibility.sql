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
-- what else was true when they were (the boundary version below trusts a pair that is far from the edge of the circle only while all of this still holds): the session (entity id) the
-- evaluation belongs to, the player's range and whether it was a spectator; null = no trustworthy evaluation (never, a join, a teleported client that was waiting for its chunks)
alter table mc.player add column if not exists vis_eid int, add column if not exists vis_rng float8, add column if not exists vis_spec boolean;

-- the view distance in effect for a player (chunks): what its client asked for, clamped; the server's with the classic broadcast
create or replace function mc.view_dist(p_req int) returns int language sql stable as $$
  select case when mc.vis_on() then greatest(2, least(coalesce(p_req, 2), mc.prop_int('view-distance'))) else mc.prop_int('view-distance') end $$;

-- the radius of the chunk square of a connection (view distance + 1), or p_default when there is no game player for it
create or replace function mc.conn_view_r(p_conn int, p_default int) returns int language sql stable as $$
  select coalesce((select mc.view_dist(p.view_distance_req) + 1 from mc.player p where p.conn_id = p_conn), p_default) $$;

-- the pairs of every player that has to be re-evaluated (vis_dirty), with the exact rule; adds and removes what changed.
-- THIS IS THE SCAN VERSION: it looks at every online player on every call (a row of the join with net.conn and a dozen computed columns each: 5.9 ms of 12 at 500 walkers) and is
-- what mc.refresh_visibility_vis (below, docs/PERF-CAPACITY.md) is compared with in tests/sql/981; it is also what that function calls when a crowd makes the neighbourhood search pointless.
create or replace function mc.refresh_visibility_vis_scan() returns table(added int, removed int) language plpgsql as $$
declare srv int := least(mc.prop_int('view-distance'), 32); trk float8 := ((coalesce(mc.prop_int('entity-broadcast-range-percentage'), 100) * 512) / 100)::float8;
        d int[]; wv int[]; wt int[]; wc int[]; av int[]; at_ int[]; ac int[]; sv int[]; wk mc.vis_work; gt bigint := (select game_time from mc.game_state); wp_on boolean;
begin
  added := 0; removed := 0;
  wk := mc.vis_find(gt);                                                    -- one scan of the online players for the whole tick (sql/905)
  -- the locator bar's updates for this tick's movement and teleports go out first (vanilla sends them when the movement packet is handled; the tracker's pairing comes after).
  -- A pass is needed when somebody moved or its block changed, or when the bar has to be switched on or off (its connections exist or not).
  wp_on := wk.n > 1 and mc.rule_bool('locator_bar', true) and wk.n <= coalesce(mc.prop_int('dbcraft.locator-bar-max-players'), 120);
  if wk.wp1 or wp_on is distinct from exists (select 1 from mc.wp) then perform mc.vis_wp_pass(gt, 1, wk.n); end if;
  if wk.recheck then
    perform mc.vis_recheck_mark();
    select coalesce(array_agg(entity_id), '{}') into d from mc.player where vis_dirty and conn_id is not null;
  else
    d := coalesce(wk.dirty, '{}');
  end if;
  if cardinality(d) > 0 then
    with pc as materialized (
      select p.entity_id as eid, p.conn_id as conn, p.x, p.z, p.chunk_x as cx, p.chunk_z as cz, (p.gamemode = 3) as spec,
             least(greatest(2, least(coalesce(p.view_distance_req, 2), srv)) * 16.0, trk) as rng, greatest(2, least(coalesce(p.view_distance_req, 2), srv)) as vd,
             (p.entity_id = any (d)) as dirty,
             p.tp_ground_tick is not null and coalesce((c.view_cx, c.view_cz) <> (p.chunk_x, p.chunk_z), false) as stale     -- a teleported client has not been sent the chunks of its new position yet (net.stream_chunks runs after this); a walking one is paired at once (recorded: range)
        from mc.player p left join net.conn c on c.conn_id = p.conn_id where p.conn_id is not null),
    dpc as materialized (select * from pc where dirty),         -- the dirty players: the outer side of both joins below (a CTE scan has no index: the inner side is rescanned once per outer row)
    w as (       -- the pairs with a dirty player in them: (dirty viewer, anybody), then (clean viewer, dirty target).  One join with "a.dirty or b.dirty" is a nested loop over all N x N pairs
      select a.eid as v, b.eid as t, a.conn as c, a.stale
        from dpc a join pc b on b.eid <> a.eid and (not b.spec or a.spec)
                               and abs(a.cx - b.cx) <= a.vd + 1 and abs(a.cz - b.cz) <= a.vd + 1
                               and (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2 <= a.rng ^ 2
      union all
      select a.eid, b.eid, a.conn, a.stale
        from dpc b join pc a on a.eid <> b.eid and not a.dirty and (not b.spec or a.spec)
                               and abs(a.cx - b.cx) <= a.vd + 1 and abs(a.cz - b.cz) <= a.vd + 1
                               and (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2 <= a.rng ^ 2)
    select coalesce(array_agg(w.v), '{}'), coalesce(array_agg(w.t), '{}'), coalesce(array_agg(w.c), '{}'),
           coalesce(array_agg(w.v) filter (where not w.stale), '{}'), coalesce(array_agg(w.t) filter (where not w.stale), '{}'), coalesce(array_agg(w.c) filter (where not w.stale), '{}'),
           (select coalesce(array_agg(pc.eid), '{}') from pc where pc.stale)
      into wv, wt, wc, av, at_, ac, sv from w;

    -- a viewer that was teleported and whose client is still waiting for the chunks of its new position is shown nobody yet: after /tp vanilla sends the chunks, then the entities (recorded: walk)
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
         and not (v.viewer_eid = any (sv))        -- (a teleported viewer that waits for its chunks loses its entities after them too: recorded, view: forgets, then remove_entities)
         and not exists (select 1 from w where w.viewer_eid = v.viewer_eid and w.target_eid = v.target_eid)
      returning v.viewer_conn, v.target_eid),
    q as (
      insert into mc.play_out (conn_id, data)
      select viewer_conn, mc.pkt_remove_entities(array_agg(target_eid order by target_eid)) from del group by viewer_conn
      returning 1)
    select (select count(*) from del) into removed;
  end if;
  if cardinality(d) > 0 then
    update mc.player p set vis_dirty = false, vis_ocx = null, vis_ocz = null, vis_x = x, vis_z = z
     where vis_dirty and not (p.tp_ground_tick is not null and exists (select 1 from net.conn c where c.conn_id = p.conn_id and (c.view_cx, c.view_cz) <> (p.chunk_x, p.chunk_z)));      -- (a stale viewer is looked at again next tick)
  end if;
  return next;
end $$;

-- THE NEIGHBOURHOOD VERSION (docs/PERF-CAPACITY.md), kept as the reference of mc.refresh_visibility_vis below (tests/sql/990).  The same pairs, the same packets, the same rows as mc.refresh_visibility_vis_scan (tests/sql/981 compares them on random
-- states): only the way the candidates are found differs.  A pair in range has both players within the larger of the two view squares of each other (at most the server's view distance + 1
-- chunks), so the players that can be paired with a dirty one are the ones in the chunk squares around the CELLS the dirty players stand in (one index probe per occupied cell of the partial
-- index mc.player (chunk_x, chunk_z) where conn_id is not null: in a crowd a handful, 27 movers in a sparse world).  The scan version joined every online player with net.conn and computed
-- the view distance, range and stale flag of each, 500 times a tick, to find out about the 27 that moved.  The stale viewers (a teleported client that is still waiting for its chunks) are
-- looked up on their own: they matter for the pairs to delete wherever they stand.
create or replace function mc.refresh_visibility_vis_nb() returns table(added int, removed int) language plpgsql as $$
declare srv int := least(mc.prop_int('view-distance'), 32); trk float8 := ((coalesce(mc.prop_int('entity-broadcast-range-percentage'), 100) * 512) / 100)::float8; rr int := greatest(srv, 2) + 1;
        d int[]; wv int[]; wt int[]; wc int[]; av int[]; at_ int[]; ac int[]; sv int[]; wk mc.vis_work; gt bigint := (select game_time from mc.game_state); wp_on boolean;
begin
  added := 0; removed := 0;
  wk := mc.vis_find(gt);                                                    -- one scan of the online players for the whole tick (sql/905)
  wp_on := wk.n > 1 and mc.rule_bool('locator_bar', true) and wk.n <= coalesce(mc.prop_int('dbcraft.locator-bar-max-players'), 120);
  if wk.wp1 or wp_on is distinct from exists (select 1 from mc.wp) then perform mc.vis_wp_pass(gt, 1, wk.n); end if;
  if wk.recheck then
    perform mc.vis_recheck_mark();
    select coalesce(array_agg(entity_id), '{}') into d from mc.player where vis_dirty and conn_id is not null;
  else
    d := coalesce(wk.dirty, '{}');
  end if;
  if cardinality(d) > 0 then
    select coalesce(array_agg(p.entity_id), '{}') into sv
      from mc.player p join net.conn c on c.conn_id = p.conn_id
     where p.tp_ground_tick is not null and (c.view_cx, c.view_cz) <> (p.chunk_x, p.chunk_z);       -- a teleported client has not been sent the chunks of its new position yet (net.stream_chunks runs after this)
    with dpc as materialized (        -- the dirty players: for each of them below one probe of the partial index for the targets in its own square, one for the viewers that can have it in theirs
      select p.entity_id as eid, p.conn_id as conn, p.x, p.z, p.chunk_x as cx, p.chunk_z as cz, (p.gamemode = 3) as spec,
             least(greatest(2, least(coalesce(p.view_distance_req, 2), srv)) * 16.0, trk) as rng, greatest(2, least(coalesce(p.view_distance_req, 2), srv)) as vd,
             p.tp_ground_tick is not null and coalesce((c.view_cx, c.view_cz) <> (p.chunk_x, p.chunk_z), false) as stale
        from mc.player p left join net.conn c on c.conn_id = p.conn_id
       where p.entity_id = any (d) and p.conn_id is not null),
    w as (       -- the pairs with a dirty player in them: (dirty viewer, anybody), then (clean viewer, dirty target)
      select a.eid as v, b.eid as t, a.conn as c, a.stale
        from dpc a cross join lateral (
               select p.entity_id as eid, p.x, p.z, (p.gamemode = 3) as spec
                 from mc.player p
                where p.conn_id is not null and p.chunk_x between a.cx - (a.vd + 1) and a.cx + (a.vd + 1) and p.chunk_z between a.cz - (a.vd + 1) and a.cz + (a.vd + 1)) b
       where b.eid <> a.eid and (not b.spec or a.spec) and (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2 <= a.rng ^ 2
      union all
      select a.eid, b.eid, a.conn, a.stale
        from dpc b cross join lateral (
               select p.entity_id as eid, p.conn_id as conn, p.x, p.z, p.chunk_x as cx, p.chunk_z as cz, (p.gamemode = 3) as spec,
                      least(greatest(2, least(coalesce(p.view_distance_req, 2), srv)) * 16.0, trk) as rng, greatest(2, least(coalesce(p.view_distance_req, 2), srv)) as vd,
                      p.tp_ground_tick is not null and coalesce((c.view_cx, c.view_cz) <> (p.chunk_x, p.chunk_z), false) as stale
                 from mc.player p left join net.conn c on c.conn_id = p.conn_id
                where p.conn_id is not null and p.chunk_x between b.cx - rr and b.cx + rr and p.chunk_z between b.cz - rr and b.cz + rr) a
       where a.eid <> b.eid and not (a.eid = any (d)) and (not b.spec or a.spec)
         and abs(a.cx - b.cx) <= a.vd + 1 and abs(a.cz - b.cz) <= a.vd + 1 and (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2 <= a.rng ^ 2)
    select coalesce(array_agg(w.v), '{}'), coalesce(array_agg(w.t), '{}'), coalesce(array_agg(w.c), '{}'),
           coalesce(array_agg(w.v) filter (where not w.stale), '{}'), coalesce(array_agg(w.t) filter (where not w.stale), '{}'), coalesce(array_agg(w.c) filter (where not w.stale), '{}')
      into wv, wt, wc, av, at_, ac from w;

    -- a viewer that was teleported and whose client is still waiting for the chunks of its new position is shown nobody yet: after /tp vanilla sends the chunks, then the entities (recorded: walk)
    with w as (select * from unnest(av, at_, ac) as w(viewer_eid, target_eid, viewer_conn)),
    ins as (
      insert into mc.visible (viewer_eid, target_eid, viewer_conn)
      select w.viewer_eid, w.target_eid, w.viewer_conn from w
       where not exists (select 1 from mc.visible v where v.viewer_eid = w.viewer_eid and v.target_eid = w.target_eid)      -- the pairs that exist are most of them: a probe each, not an insert that finds the conflict (a crowd of 500: 175,000 candidates a tick)
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
         and not (v.viewer_eid = any (sv))        -- (a teleported viewer that waits for its chunks loses its entities after them too: recorded, view: forgets, then remove_entities)
         and not exists (select 1 from w where w.viewer_eid = v.viewer_eid and w.target_eid = v.target_eid)
      returning v.viewer_conn, v.target_eid),
    q as (
      insert into mc.play_out (conn_id, data)
      select viewer_conn, mc.pkt_remove_entities(array_agg(target_eid order by target_eid)) from del group by viewer_conn
      returning 1)
    select (select count(*) from del) into removed;
    -- (the dirty players, found by their index: the scan version looked for the flag in every row; a player that left has no flag, mc.on_leave clears it)
    update mc.player p set vis_dirty = false, vis_ocx = null, vis_ocz = null, vis_x = x, vis_z = z
     where p.entity_id = any (d) and p.vis_dirty and not (p.tp_ground_tick is not null and exists (select 1 from net.conn c where c.conn_id = p.conn_id and (c.view_cx, c.view_cz) <> (p.chunk_x, p.chunk_z)));      -- (a stale viewer is looked at again next tick)
  end if;
  return next;
end $$;

-- THE BOUNDARY VERSION (docs/PERF-VIS2.md), what the tick calls.  The same pairs, packets and rows as the two versions above (tests/sql/990 compares it with mc.refresh_visibility_vis_nb on random walks,
-- tick by tick).  Those test every pair of a dirty player: 137 dirty players of 500 crowded walkers, each against nearly everybody, 137,000 pair tests and 46,000 probes of mc.visible for the pairs that
-- are in range, to find the 190 pairs that change.  A pair can only change its status when the two players are about as far apart as the edge of the circle:
--
--   The status of a pair (v, t) in mc.visible is the rule applied to the positions of the two at the last time the pair was looked at, tau: the last time either player was dirty (a pair is looked at
--   only then).  At tau one of them was evaluated, so it stood where its pairs were evaluated, (vis_x, vis_z); the other was not dirty, so it was less than 4 blocks from ITS (vis_x, vis_z)
--   (a player becomes dirty at 4 blocks, mc.apply_player_moves).  Since then each has moved by at most |position now - vis| (the one evaluated at tau) or that plus 4 (the other), so the
--   distance of the pair is now within  disp_a + disp_b + 4  of what it was, and a pair whose distance is further than that from the radius of the viewer (|d - R| > disp_a + disp_b + 4) is in the
--   same state now as at tau: nothing to do.  Everything else (about 10 % of the pairs of a crowd) is tested exactly as before.
--   Who has no such bound is tested against everybody, as before: a player that was never evaluated (a join; vis_eid is the session), whose range or spectator state differs from what its pairs were
--   evaluated with (a changed view distance or game mode), that waited for the chunks of a teleport (its pairs were evaluated at positions that are not its vis), or that has moved 4 blocks without being
--   dirty (not possible through the movement step, but then the bound would be wrong); and every dirty player that jumped far has a disp that makes its ring cover everybody.
--   The pairs found are probed in mc.visible (the primary key) and only the changes are written: O(pairs near the edge), not O(dirty x online).  A pair to delete is deleted by the tuple id the probe found.
create or replace function mc.refresh_visibility_vis() returns table(added int, removed int) language plpgsql as $$
declare srv int := least(mc.prop_int('view-distance'), 32); trk float8 := ((coalesce(mc.prop_int('entity-broadcast-range-percentage'), 100) * 512) / 100)::float8;
        d int[]; sv int[]; av int[]; at_ int[]; ac int[]; dtid tid[]; wk mc.vis_work; gt bigint := (select game_time from mc.game_state); wp_on boolean;
begin
  added := 0; removed := 0;
  wk := mc.vis_find(gt);                                                    -- one scan of the online players for the whole tick (sql/905)
  wp_on := wk.n > 1 and mc.rule_bool('locator_bar', true) and wk.n <= coalesce(mc.prop_int('dbcraft.locator-bar-max-players'), 120);
  if wk.wp1 or wp_on is distinct from exists (select 1 from mc.wp) then perform mc.vis_wp_pass(gt, 1, wk.n); end if;
  if wk.recheck then
    perform mc.vis_recheck_mark();
    select coalesce(array_agg(entity_id), '{}') into d from mc.player where vis_dirty and conn_id is not null;
  else
    d := coalesce(wk.dirty, '{}');
  end if;
  if cardinality(d) > 0 then
    with pc as materialized (        -- every online player, narrow, the columns of the pair loop first: k = half of the bound above (disp + 2), infinite for a player that has none or whose bound is wider than 14 blocks
      select p.entity_id as eid, p.x, p.z, l.rng, (p.entity_id = any (d)) as dirty,
             case when p.vis_eid is not distinct from p.entity_id and p.vis_rng is not distinct from l.rng and p.vis_spec is not distinct from (p.gamemode = 3) and p.vis_x is not null and p.vis_z is not null
                       and not stl.s and (p.entity_id = any (d) or (p.x - p.vis_x) ^ 2 + (p.z - p.vis_z) ^ 2 < 16)
                       and (p.x - p.vis_x) ^ 2 + (p.z - p.vis_z) ^ 2 < 196
                  then sqrt((p.x - p.vis_x) ^ 2 + (p.z - p.vis_z) ^ 2) + 2.005 else 'infinity'::float8 end as k,
             p.conn_id as conn, p.chunk_x as cx, p.chunk_z as cz, (p.gamemode = 3) as spec, l.vd, stl.s as stale
        from mc.player p
        cross join lateral (select p.tp_ground_tick is not null and coalesce(exists (select 1 from net.conn c where c.conn_id = p.conn_id and (c.view_cx, c.view_cz) <> (p.chunk_x, p.chunk_z)), false) as s) stl     -- a teleported client has not been sent the chunks of its new position yet (net.stream_chunks runs after this)
        cross join lateral (select greatest(2, least(coalesce(p.view_distance_req, 2), srv)) as vd, least(greatest(2, least(coalesce(p.view_distance_req, 2), srv)) * 16.0, trk) as rng) l
       where p.conn_id is not null),
    dp as materialized (select * from pc where dirty),
    cand as (        -- (a dirty, b anybody) whose distance is near the radius of either of them: |d - R| <= m.  (m is below 32, the smallest radius, or infinite)  A pair of two dirty players once, from the lower id
      select a.eid as ae, a.conn as aconn, a.x as ax, a.z as az, a.cx as acx, a.cz as acz, a.spec as aspec, a.rng as arng, a.vd as avd, a.stale as astale,
             b.eid as be, b.conn as bconn, b.x as bx, b.z as bz, b.cx as bcx, b.cz as bcz, b.spec as bspec, b.rng as brng, b.vd as bvd, b.stale as bstale, a.k + b.k as m
        from dp a join pc b on a.eid <> b.eid and (not b.dirty or a.eid < b.eid)
                              and (abs(sqrt((a.x - b.x) * (a.x - b.x) + (a.z - b.z) * (a.z - b.z)) - a.rng) <= a.k + b.k
                                   or (b.rng <> a.rng and abs(sqrt((a.x - b.x) * (a.x - b.x) + (a.z - b.z) * (a.z - b.z)) - b.rng) <= a.k + b.k))),
    dirs as (        -- the two directions of those pairs
      select ae as v, be as t, aconn as vconn, astale as vstale,
             (not bspec or aspec) and abs(acx - bcx) <= avd + 1 and abs(acz - bcz) <= avd + 1 and (ax - bx) ^ 2 + (az - bz) ^ 2 <= arng ^ 2 as inr,
             abs(sqrt((ax - bx) * (ax - bx) + (az - bz) * (az - bz)) - arng) <= m as hit
        from cand
      union all
      select be, ae, bconn, bstale,
             (not aspec or bspec) and abs(acx - bcx) <= bvd + 1 and abs(acz - bcz) <= bvd + 1 and (ax - bx) ^ 2 + (az - bz) ^ 2 <= brng ^ 2,
             abs(sqrt((ax - bx) * (ax - bx) + (az - bz) * (az - bz)) - brng) <= m
        from cand),
    chk as materialized (select h.v, h.t, h.vconn, h.vstale, h.inr, (select x.ctid from mc.visible x where x.viewer_eid = h.v and x.target_eid = h.t) as vt       -- (a probe of the primary key each: a join is planned as a hash join over all of mc.visible)
              from dirs h where h.hit)
    select coalesce(array_agg(v) filter (where inr and not vstale and vt is null), '{}'), coalesce(array_agg(t) filter (where inr and not vstale and vt is null), '{}'),
           coalesce(array_agg(vconn) filter (where inr and not vstale and vt is null), '{}'), coalesce(array_agg(vt) filter (where not inr and vt is not null and not vstale), '{}'),
           (select coalesce(array_agg(pc.eid), '{}') from pc where pc.stale)
      into av, at_, ac, dtid, sv from chk;

    -- a viewer that was teleported and whose client is still waiting for the chunks of its new position is shown nobody yet: after /tp vanilla sends the chunks, then the entities (recorded: walk)
    if cardinality(av) > 0 then
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
    end if;

    if cardinality(dtid) > 0 then
    with del as (
      delete from mc.visible v where v.ctid = any (dtid)
      returning v.viewer_conn, v.target_eid),
    q as (
      insert into mc.play_out (conn_id, data)
      select viewer_conn, mc.pkt_remove_entities(array_agg(target_eid order by target_eid)) from del group by viewer_conn
      returning 1)
    select (select count(*) from del) into removed;
    end if;

    -- the evaluated players' state: where their pairs are now, and what the rule used.  A player that is still waiting for its chunks has no state to trust (its pairs were not all evaluated).
    update mc.player p set vis_dirty = false, vis_ocx = null, vis_ocz = null, vis_x = x, vis_z = z, vis_eid = entity_id, vis_spec = (gamemode = 3),
           vis_rng = least(greatest(2, least(coalesce(view_distance_req, 2), srv)) * 16.0, trk)
     where p.entity_id = any (d) and p.vis_dirty and not (p.tp_ground_tick is not null and exists (select 1 from net.conn c where c.conn_id = p.conn_id and (c.view_cx, c.view_cz) <> (p.chunk_x, p.chunk_z)));
    update mc.player p set vis_eid = null where p.entity_id = any (sv) and p.vis_eid is not null;
  end if;
  return next;
end $$;
