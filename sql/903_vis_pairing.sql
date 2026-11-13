-- Player visibility, part 4: what a viewer is sent when a player comes into view.
--
-- ServerEntity.addPairing / sendPairingData: one bundle (bundle_delimiter ... bundle_delimiter) with the add_entity packet, the entity's non-default entity data
-- (set_entity_data), the attributes in its attribute map (update_attributes, only when there is one), and the non-empty equipment (set_equipment).  Recorded from the real
-- server by tests/e2e/vis_probe.py.  (The classic broadcast, dbcraft.vanilla-tracker = false, sent the add_entity packet alone.)

-- the non-default entity data entries of a player (SynchedEntityData.getNonDefaultValues): a mask for mc.ed_entries
create or replace function mc.ed_nondefault_mask(t mc.player) returns int language sql immutable parallel safe as $$
  select (case when mc.ed_flags(t.shift, t.sprinting, t.gamemode) <> 0 then 1 else 0 end)
       | (case when t.pose <> 0 then 2 else 0 end)
       | (case when t.use_slot is not null then 4 else 0 end)
       | (case when t.health <> 1 then 8 else 0 end)
       | (case when t.main_hand <> 1 then 16 else 0 end)
       | (case when t.skin_parts <> 0 then 32 else 0 end)
       | (case when t.xp_score <> 0 then 64 else 0 end) $$;

create or replace function mc.pairing_bundle(t mc.player) returns bytea language plpgsql stable as $$
declare add_pkt bytea; v mc.vtrk;
        attrs bytea[]; eq text[]; slots int[]; stacks text[];
begin
  if not mc.vis_on() then
    return mc.pkt_add_player_entity(t.entity_id, t.uuid, t.sent_qx / 4096.0, t.sent_qy / 4096.0, t.sent_qz / 4096.0, t.sent_yaw, t.sent_pitch, t.sent_yaw);
  end if;
  select * into v from mc.vtrk where entity_id = t.entity_id;
  add_pkt := mc.pkt_add_player_entity_b(t.entity_id, t.uuid, coalesce(v.base_x, t.x), coalesce(v.base_y, t.y), coalesce(v.base_z, t.z),       -- the position and angles the tracker last sent (the player's own until the tracker started for it)
                                        coalesce(v.sent_yb, mc.angle_byte(t.yaw)), coalesce(v.sent_pb, mc.angle_byte(t.pitch)), coalesce(v.sent_hb, mc.angle_byte(t.yaw)));
  eq := mc.equip_now(t.uuid, t.held_slot);
  attrs := case when t.fresh_join then null                                                                                                                -- a first-time player's attribute map is still empty
                when not exists (select 1 from unnest(eq) h where h <> '') then mc.attr_memo(coalesce(t.attr_gm, t.gamemode), t.sprinting, t.attr_seen)        -- nothing worn or held: the answer is a function of three values (sql/981)
                else mc.pairing_attrs(t.uuid, t.held_slot, coalesce(t.attr_gm, t.gamemode), t.sprinting, t.attr_seen) end;
  select array_agg((o - 1)::int order by o), array_agg(h order by o) into slots, stacks from unnest(eq) with ordinality e(h, o) where h <> '';
  return mc.pkt_bundle_delimiter() || add_pkt
      || mc.pkt_entity_data(t.entity_id, mc.ed_entries(mc.ed_flags(t.shift, t.sprinting, t.gamemode), t.pose, case when t.use_slot is not null then 1 else 0 end, t.health,
                                                        t.main_hand, t.skin_parts, t.xp_score, mc.ed_nondefault_mask(t)))
      || case when attrs is not null then mc.pkt_update_attributes(t.entity_id, attrs) else '\x'::bytea end
      || case when slots is not null then mc.pkt_equipment(t.entity_id, slots, stacks) else '\x'::bytea end
      || mc.pkt_bundle_delimiter();
end $$;

-- A player whose game mode changed is re-checked against its viewers (and they against it) when it or any other player sends a movement packet this tick: that is when
-- vanilla's ChunkMap.move runs the tracker's updatePlayer for the pairs (ServerGamePacketListenerImpl.handlePlayerPositionChange).  Marks the player for the exact recomputation of
-- mc.refresh_visibility (an unknown "chunk before the move").  Called at the start of the refresh.
create or replace function mc.vis_recheck_mark() returns void language plpgsql as $$
declare gt bigint;
begin
  if not exists (select 1 from mc.player where vis_recheck and conn_id is not null) then return; end if;
  select game_time into gt from mc.game_state;
  if not exists (select 1 from mc.player where last_move_tick = gt and conn_id is not null) then return; end if;
  update mc.player set vis_dirty = true, vis_ocx = null, vis_ocz = null, vis_recheck = (last_move_tick is distinct from gt)
   where vis_recheck and conn_id is not null;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Pairing deferral for login storms (docs/PERF-PAIRING.md).  Vanilla pairs a new player with everybody in range inside the join (ChunkMap.addEntity -> TrackedEntity.updatePlayers, and
-- ServerWaypointManager.addPlayer for the locator bar): one Java call, microseconds per pair.  Here the same work is one joiner's pair search, its pairing bundles in both directions,
-- the first tracker pass and the locator bar's connections of the new source (about 10 ms at 200 players online), and it ran in the tick of the join, on top of the join itself (20 ms)
-- and the chunk delivery.  Several joiners in one tick, or a joiner in a tick that is already heavy, made the 100-150 ms ticks of a storm.
--
-- A joiner is queued in mc.vpair by mc.vis_join (sql/906); mc.vis_pair_release (the start of mc.refresh_visibility_vis) decides how many leave the queue this tick:
--   dbcraft.pair-free (1)        joiners per tick that always leave it, whatever the cost: with one join per tick (or any number below the budget) nothing is ever delayed and every byte is where it was
--   dbcraft.pair-budget-ms (8)   more leave in the same tick while the measured cost of a pairing (a moving average of ms per released joiner: its pair search and bundles, first tracker pass and locator
--                                connections, measured in the ticks that had any) keeps the sum within this budget; off = all at once (the old behaviour)
--   dbcraft.pair-tick-ms (off)   when the tick has already spent this many ms before the pairing (the joins of the tick, a chunk burst: mc.server_tick stamps its start), not even the free one
--                                leaves, unless it has waited dbcraft.pair-max-wait-ticks (20)
-- A joiner in the queue is not paired yet: it sees nobody and nobody sees it (it is left out of the pair search, the first tracker pass and the locator bar's transmit state, mc.vis_find /
-- mc.vis_wp_pass), exactly as a player that has not come into range; its own join burst, entity data and the waypoints it is sent are not touched.  When it leaves the queue its
-- bundles are made from its state of that moment, the same bytes the pair would get if it came into range then; the first tracker pass and the locator bar's new source follow in the same
-- tick (the order of an unqueued join).
create unlogged table if not exists mc.vpair (entity_id int primary key, since bigint not null);
create unlogged table if not exists mc.vpair_state (id int primary key default 1 check (id = 1), ema_ms float8 not null default 2.0, released bigint not null default 0, deferred_ticks bigint not null default 0, max_depth int not null default 0);
insert into mc.vpair_state (id) values (1) on conflict do nothing;

insert into mc.server_property (key, value, default_value, note) values
    ('dbcraft.pair-free',           '1',   '1',   'dbcraft: login storms: joiners per tick that are paired with their viewers at once (docs/PERF-PAIRING.md); the rest of a tick''s joiners wait for the pairing budget'),
    ('dbcraft.pair-budget-ms',      '8',   '8',   'dbcraft: login storms: more joiners than dbcraft.pair-free are paired in a tick while the measured ms per pairing keeps the tick''s sum within this budget; off = every joiner at once'),
    ('dbcraft.pair-tick-ms',        'off', 'off', 'dbcraft: login storms: when the tick has already spent this many ms before the pairing, the queued joiners wait (at most dbcraft.pair-max-wait-ticks); off = never'),
    ('dbcraft.pair-max-wait-ticks', '20',  '20',  'dbcraft: login storms: a queued joiner is paired after at most this many ticks whatever the budget says')
on conflict (key) do nothing;

-- ms since mc.server_tick started this tick (it stamps dbcraft.tick_t0); null when the tick was not started by it (tests, tools)
create or replace function mc.tick_elapsed_ms() returns float8 language plpgsql stable as $$
declare s text := current_setting('dbcraft.tick_t0', true);
begin
  if s is null or s = '' then return null; end if;
  return extract(epoch from clock_timestamp() - s::timestamptz) * 1000;
exception when others then return null;
end $$;

-- How many queued joiners are paired this tick; they leave the queue (the caller's mc.vis_find then sees them).  Returns that number.
create or replace function mc.vis_pair_release(p_cur bigint) returns int language plpgsql as $$
declare bud text := mc.prop('dbcraft.pair-budget-ms'); heavy text := mc.prop('dbcraft.pair-tick-ms'); free int := coalesce(mc.prop_int('dbcraft.pair-free'), 1);
        maxw int := coalesce(mc.prop_int('dbcraft.pair-max-wait-ticks'), 20); n int; adm int; est float8; e float8; oldest bigint; k int;
begin
  if not exists (select 1 from mc.vpair) then return 0; end if;
  delete from mc.vpair q where not exists (select 1 from mc.player p where p.entity_id = q.entity_id and p.conn_id is not null);
  select count(*)::int, min(since) into n, oldest from mc.vpair;
  if n = 0 then return 0; end if;
  if lower(coalesce(bud, 'off')) in ('off', '0', '-1', '') then
    delete from mc.vpair;
    return n;
  end if;
  select ema_ms into est from mc.vpair_state;
  adm := greatest(free, floor(bud::numeric / greatest(est, 0.2))::int);
  if lower(coalesce(heavy, 'off')) not in ('off', '0', '-1', '') then
    e := mc.tick_elapsed_ms();
    if e is not null and e > heavy::numeric then adm := 0; end if;
  end if;
  -- (a joiner that has waited long enough is paired whatever the tick looks like: at least one per tick, the oldest first)
  if p_cur - oldest >= maxw then adm := greatest(adm, 1); end if;
  adm := least(adm, n);
  update mc.vpair_state set max_depth = greatest(max_depth, n), deferred_ticks = deferred_ticks + case when adm < n then 1 else 0 end, released = released + adm;
  perform set_config('dbcraft.pair_adm', adm::text, true); perform set_config('dbcraft.pair_ms', '0', true);
  if adm = 0 then return 0; end if;
  with s as (select entity_id from mc.vpair order by since, entity_id limit adm) delete from mc.vpair q using s where q.entity_id = s.entity_id;
  return adm;
end $$;

-- The cost of this tick's pairings, for the moving average: ms measured by the steps that did the work, added up in a transaction-local setting, folded in by mc.vis_pair_measure at the end of
-- mc.vis_step.
create or replace function mc.vis_pair_note(p_ms float8) returns void language plpgsql as $$
begin
  perform set_config('dbcraft.pair_ms', (coalesce(nullif(current_setting('dbcraft.pair_ms', true), '')::float8, 0) + p_ms)::text, true);
end $$;
create or replace function mc.vis_pair_measure(p_cur bigint) returns void language plpgsql as $$
declare adm int := coalesce(nullif(current_setting('dbcraft.pair_adm', true), '')::int, 0); ms float8 := coalesce(nullif(current_setting('dbcraft.pair_ms', true), '')::float8, 0);
begin
  if adm > 0 then
    update mc.vpair_state set ema_ms = 0.7 * ema_ms + 0.3 * (ms / adm);
    perform set_config('dbcraft.pair_adm', '0', true);
    perform set_config('dbcraft.pair_ms', '0', true);
  end if;
end $$;
