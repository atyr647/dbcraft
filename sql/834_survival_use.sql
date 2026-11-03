-- Survival core, part 5: eating, the end of the death animation, respawning, /kill.
--
-- Eating (ServerGamePacketListenerImpl.handleUseItem -> Item.use -> LivingEntity.startUsingItem ... completeUsingItem -> FoodData.eat):
--   use_item (VarInt hand | VarInt sequence | float yaw | float pitch) with a food item in the hand starts the use if the player can eat (hungry, or the food is always
--   edible, or creative/spectator: Player.canEat); the player is told with entity data (living flags bit 0) and the block-changed acknowledgement of the sequence.
--   After the item's consume time (apple 32 ticks) the use completes: entity event 9, the food and saturation grow (FoodData.add: food capped at 20, saturation at the new
--   food level), the stack shrinks by one (not in creative) and what the item leaves behind (a bowl, a bottle) takes its place; the player is sent set_health in the same
--   tick and the flag reset and the new stack one tick later.  Releasing the item (player_action 6), changing the held slot or losing the item cancels the use.
--   NOT modelled: the eating sounds and particles, food effects (golden apple regeneration, rotten flesh hunger, ...), the advancement update the real server sends.

-- p_phase 'start': the packets (release, use_item), in the tick's input phase; 'finish': the item's own tick (cancel checks, completion), after the tracker pass
create or replace function mc.survival_use(p_cur bigint, p_phase text) returns void language plpgsql as $$
declare i_use int := mc.sid('use_item'); i_act int := mc.sid('player_action'); ue int[]; uu uuid[]; us int[]; uc int[]; ur text[]; ug int[];
begin
  -- releasing the item cancels the use: player_action with action 6 (release use item)
  if p_phase = 'start' and exists (select 1 from mc.play_in_work where packet_id = i_act) then
    update mc.player p set use_slot = null, use_until = null
      from mc.play_in_work m where m.packet_id = i_act and m.conn_id = p.conn_id and p.use_slot is not null and length(m.body) >= 1 and get_byte(m.body, 0) = 6;
  end if;
  -- start
  if p_phase = 'start' and exists (select 1 from mc.play_in_work where packet_id = i_use) then
    with r as (
      select distinct on (p.uuid) p.uuid, p.conn_id, f.consume_ticks, (case when m.hand = 1 then 45 else 36 + p.held_slot end) as slot, m.seq_no
        from (select m0.conn_id, m0.seq, proto.varint_safe(m0.body, 0) as hand, proto.varint_safe(m0.body, (select nxt from proto.varint_read(m0.body, 0))) as seq_no
                from mc.play_in_work m0 where m0.packet_id = i_use and length(m0.body) >= 10) m
        join mc.player p on p.conn_id = m.conn_id and not p.dead and p.use_slot is null
        join mc.inventory_slot i on i.player = p.uuid and i.slot = case when m.hand = 1 then 45 else 36 + p.held_slot end
        join mc.food_item f on f.item = i.item
       where m.hand in (0, 1) and (p.gamemode in (1, 3) or p.food < 20 or f.can_always_eat) and p.gamemode <> 3
       order by p.uuid, m.seq desc),
    u as (update mc.player p set use_slot = r.slot, use_until = p_cur + r.consume_ticks from r where p.uuid = r.uuid returning r.conn_id, r.seq_no)
    insert into mc.pending_ack (conn_id, sequence) select conn_id, seq_no from u where seq_no is not null;
  end if;
  if p_phase = 'start' then delete from mc.play_in_work where packet_id in (i_use); return; end if;
  -- cancel: the held item changed or went away
  update mc.player p set use_slot = null, use_until = null
   where p.use_slot is not null and (p.dead or not exists (select 1 from mc.inventory_slot i join mc.food_item f on f.item = i.item where i.player = p.uuid and i.slot = p.use_slot)
                                     or (p.use_slot between 36 and 44 and p.use_slot <> 36 + p.held_slot));
  -- complete
  if exists (select 1 from mc.player where use_until <= p_cur) then
    with d as (
      select p.entity_id as eid, p.uuid, p.use_slot as slot, i.count, f.nutrition, f.saturation, f.remainder, p.gamemode
        from mc.player p join mc.inventory_slot i on i.player = p.uuid and i.slot = p.use_slot join mc.food_item f on f.item = i.item
       where p.use_until <= p_cur and p.conn_id is not null and not p.dead),
    eat as (   -- FoodData.add(nutrition, saturation): food 0..20, saturation 0..food (float)
      update mc.player p set food = least(p.food + d.nutrition, 20), saturation = least(greatest(p.saturation + d.saturation, 0::real), least(p.food + d.nutrition, 20)::real),
                             use_slot = null, use_until = null, pend_slot = d.slot, inv_state = p.inv_state + 1
        from d where p.entity_id = d.eid returning d.eid, d.uuid, d.slot, d.count, d.remainder, d.gamemode)
    select array_agg(eid order by eid), array_agg(uuid order by eid), array_agg(slot order by eid), array_agg(count order by eid), array_agg(remainder order by eid), array_agg(gamemode order by eid)
      into ue, uu, us, uc, ur, ug from eat;
    if ue is not null then
      -- the stack shrinks (not in creative); the last one is replaced by what the item leaves behind, a bigger stack gets that item added to the inventory
      delete from mc.inventory_slot i using unnest(uu, us, uc, ur, ug) as t(uuid, slot, cnt, rem, gm)
       where i.player = t.uuid and i.slot = t.slot and t.gm <> 1 and t.cnt = 1 and t.rem is null;
      update mc.inventory_slot i set item = t.rem, count = 1, components = null
        from unnest(uu, us, uc, ur, ug) as t(uuid, slot, cnt, rem, gm) where i.player = t.uuid and i.slot = t.slot and t.gm <> 1 and t.cnt = 1 and t.rem is not null;
      update mc.inventory_slot i set count = i.count - 1
        from unnest(uu, us, uc, ur, ug) as t(uuid, slot, cnt, rem, gm) where i.player = t.uuid and i.slot = t.slot and t.gm <> 1 and t.cnt > 1;
      perform mc.inv_add(t.uuid, t.rem, 1) from unnest(uu, us, uc, ur, ug) as t(uuid, slot, cnt, rem, gm) where t.gm <> 1 and t.cnt > 1 and t.rem is not null;
      perform mc.send_players_and_viewers(ue, array(select mc.pkt_entity_event(e, 9) from unnest(ue) e));
    end if;
  end if;
end $$;
