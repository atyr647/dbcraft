-- Player visibility, part 5: the serverbound packets that change what other players see.
--   player_input           (ServerGamePacketListenerImpl.handlePlayerInput)  byte: 1 forward, 2 backward, 4 left, 8 right, 16 jump, 32 shift, 64 sprint -> the shift key (entity flag 0x02)
--   punch                  (handlePunch: ServerPlayer.swing(MAIN_HAND))      no body -> swing_animation to the viewers
--   client_information     (handleClientInformation -> updateOptions)        language, view distance (byte), chat visibility, chat colors, skin layers (byte), main hand
--                                                                             (VarInt), filtering, listing, particles -> entity data 15 and 16, the hat flag of the tab list
--   player_abilities       (handlePlayerAbilities)                            byte: 2 = flying
-- client_information also reaches mc.play_in_work (net.process_fast lists it with the packets both layers need); the connection layer keeps its own copy in net.conn.client_info.

create or replace function mc.ci_parse(p_body bytea, out skin int, out hand int, out vdist int, out sdist int) language plpgsql immutable as $$
declare ci jsonb;
begin
  ci := net.read_client_information(p_body);
  skin := (ci ->> 'skin_parts')::int; hand := (ci ->> 'main_hand')::int; vdist := (ci ->> 'view_distance')::int; sdist := null;
exception when others then
  skin := null; hand := null; vdist := null; sdist := null;
end $$;

-- the swing animation of the item in the main hand: SwingAnimation (type 1 whack, 2 stab; duration in ticks); the default is whack for 6 ticks
create or replace function mc.swing_of(p_uuid uuid, p_held int, out stype int, out dur int) language sql stable as $$
  select coalesce(case x.t when 'stab' then 2 when 'whack' then 1 when 'none' then 0 end, 1), coalesce(x.d, 6)
    from (select 1) o left join (select i.attack_animation::jsonb ->> 'type' as t, (i.attack_animation::jsonb ->> 'duration')::int as d
                                   from mc.inventory_slot s join ref.item_info i on i.item = s.item where s.player = p_uuid and s.slot = 36 + p_held) x on true $$;

create or replace function mc.vis_input(p_cur bigint) returns void language plpgsql as $$
declare i_in int := mc.sid('player_input'); i_pu int := mc.sid('punch'); i_ci int := mc.sid('client_information'); i_ab int := mc.sid('player_abilities');
        kinds int[]; sw_e int[]; sw_d bytea[];
begin
  select coalesce(array_agg(distinct packet_id) filter (where packet_id in (i_in, i_pu, i_ci, i_ab)), '{}') into kinds from mc.play_in_work;
  if cardinality(kinds) = 0 then return; end if;

  -- player_input: the shift key.  Set twice in one tick (down and up) the entity data is still dirty, so the flags are re-sent although the value is back where it was (sent_flags = -1 forces it).
  if i_in = any (kinds) then
    with a as (
      select m.conn_id, m.seq, get_byte(m.body, 0) & 32 <> 0 as sh
        from mc.play_in_work m where m.packet_id = i_in and length(m.body) >= 1),
    b as (select a.conn_id, a.sh, lag(a.sh) over (partition by a.conn_id order by a.seq) as prev, a.seq,
                 row_number() over (partition by a.conn_id order by a.seq desc) as rn from a),
    c as (select b.conn_id, bool_or(b.sh is distinct from coalesce(b.prev, p.shift)) as flipped, (array_agg(b.sh order by b.seq desc))[1] as last_sh
            from b join mc.player p on p.conn_id = b.conn_id group by b.conn_id, p.shift)
    update mc.player p set shift = c.last_sh, sent_flags = case when c.flipped and c.last_sh = p.shift then -1 else p.sent_flags end
      from c where p.conn_id = c.conn_id and (c.last_sh <> p.shift or c.flipped);
    delete from mc.play_in_work where packet_id = i_in;
  end if;

  -- player_abilities: a flying player does not crouch
  if i_ab = any (kinds) then
    update mc.player p set flying = f.fl
      from (select distinct on (m.conn_id) m.conn_id, get_byte(m.body, 0) & 2 <> 0 as fl from mc.play_in_work m where m.packet_id = i_ab and length(m.body) >= 1 order by m.conn_id, m.seq desc) f
     where p.conn_id = f.conn_id and p.flying <> f.fl and (p.gamemode = 3 or p.gamemode = 1);        -- only a player who may fly can
    delete from mc.play_in_work where packet_id = i_ab;
  end if;

  -- client_information: skin layers and main hand are entity data (sent with the next tracker pass); the hat layer is a tab-list flag that goes out now, to everybody
  if i_ci = any (kinds) then
    with ci as (
      select distinct on (m.conn_id) m.conn_id, q.skin, q.hand, q.vdist
        from mc.play_in_work m, lateral mc.ci_parse(m.body) q where m.packet_id = i_ci and q.skin is not null order by m.conn_id, m.seq desc),
    ci2 as (select ci.*, p.uuid, p.entity_id, p.sent_hat as old_hat, ((ci.skin & 64) <> 0) as hat from ci join mc.player p on p.conn_id = ci.conn_id),
    u as (
      update mc.player p set skin_parts = ci2.skin, main_hand = ci2.hand, view_distance_req = ci2.vdist, sent_hat = ci2.hat,
             vis_dirty = p.vis_dirty or p.view_distance_req is distinct from ci2.vdist, vis_ocx = case when p.view_distance_req is distinct from ci2.vdist then null else p.vis_ocx end,        -- a new view distance changes who it sees (sql/909) and the chunks it holds (net.stream_chunks)
             vis_ocz = case when p.view_distance_req is distinct from ci2.vdist then null else p.vis_ocz end
        from ci2 where p.conn_id = ci2.conn_id returning 1)
    insert into mc.play_out (conn_id, data)
      select o.conn_id, mc.pkt_player_info_hat(h.uuid, h.hat) from ci2 h, mc.player o where h.hat is distinct from h.old_hat and o.conn_id is not null order by h.entity_id, o.entity_id;
    delete from mc.play_in_work where packet_id = i_ci;
  end if;

  -- punch: swing_animation to everybody who sees the player (not to the player: the client swings by itself).  A second swing in the first half of the animation is ignored.
  if i_pu = any (kinds) then
    with sw as (
      select m.seq, p.entity_id as eid, p.uuid, p.held_slot, p.swing_tick, row_number() over (partition by p.entity_id order by m.seq) as k
        from mc.play_in_work m join mc.player p on p.conn_id = m.conn_id where m.packet_id = i_pu and not p.dead),
    pk as (
      select sw.seq, sw.eid, sw.uuid, sw.swing_tick, sw.k, s.stype, s.dur
        from sw cross join lateral mc.swing_of(sw.uuid, sw.held_slot) s),
    ok as (       -- the first punch of a player in a tick counts when the last swing was long enough ago; a later one in the same tick is the same moment, so ignored
      select pk.* from pk where pk.k = 1 and (pk.swing_tick is null or p_cur - pk.swing_tick >= pk.dur / 2 + 1)),
    mk as (update mc.player p set swing_tick = p_cur from ok where p.entity_id = ok.eid returning ok.eid)
    select array_agg(ok.eid order by ok.seq), array_agg(mc.pkt_swing(ok.eid, 0, ok.stype, ok.dur) order by ok.seq) into sw_e, sw_d from ok;
    if sw_e is not null then perform mc.send_players_and_viewers(sw_e, sw_d, false); end if;
    delete from mc.play_in_work where packet_id = i_pu;
  end if;
end $$;
