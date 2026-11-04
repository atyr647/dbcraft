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
  attrs := case when t.fresh_join then null else mc.pairing_attrs(t.uuid, t.held_slot, coalesce(t.attr_gm, t.gamemode), t.sprinting, t.attr_seen) end;     -- a first-time player's attribute map is still empty
  eq := mc.equip_now(t.uuid, t.held_slot);
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
