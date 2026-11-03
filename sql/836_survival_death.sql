-- Survival core, part 6: the end of the death animation, respawn, /kill.
--
-- A death (mc.survival_die, sql/832) leaves the player entity in place for 19 ticks (the death animation: LivingEntity.tickDeath counts deathTime to 20, measured on
-- the real server: entity event 60 and the removal 19 ticks after entity event 3), then it is removed for everybody who sees it.  The dead player's client shows the death
-- screen; its perform_respawn (client_command action 0) creates the new player: what PlayerList.respawn sends, in the order the real server sent it (recorded by
-- tests/e2e/survival_probe.py kill, compared by tests/e2e/compare_survival.py):
--   player_abilities, respawn, player_position, set_default_spawn_position, change_difficulty, set_experience, post_effects, initialize_border, set_time,
--   set_default_spawn_position, game_event 13, ticking_state, ticking_step, entity_event 24+level, commands, set_chunk_cache_center, container_set_content,
--   set_entity_data (health), update_attributes, set_health, set_experience, then the chunks around the spawn.
-- The spawn is the world spawn (mc.game_state; vanilla spreads respawns over spawn_radius, 0 in the recorded run); beds and respawn anchors are not modelled.

drop function if exists mc.survival_deaths(bigint);
create or replace function mc.survival_deaths(p_cur bigint, p_ids int[] default null) returns void language plpgsql as $$
declare e int[];
begin
  select coalesce(array_agg(entity_id order by entity_id), '{}') into e from mc.player where dead and death_tick is not null and p_cur - death_tick >= 19 and conn_id is not null and (p_ids is null or entity_id = any (p_ids));
  if cardinality(e) = 0 then return; end if;
  update mc.player set death_tick = null where entity_id = any (e);
  perform mc.send_players_and_viewers(e, array(select mc.pkt_entity_event(x, 60) from unnest(e) x));
  insert into mc.play_out (conn_id, data) select v.viewer_conn, mc.pkt_remove_entities(array_agg(v.target_eid order by v.target_eid)) from mc.visible v where v.target_eid = any (e) group by v.viewer_conn order by v.viewer_conn;
  delete from mc.visible v where v.target_eid = any (e);
end $$;

create or replace function mc.respawn_player(p_uuid uuid, p_cur bigint) returns void language plpgsql as $$
declare p mc.player; gs mc.game_state; w mc.world; tid int; keep boolean := mc.rule_bool('keep_inventory', false); op int; diff int := mc.difficulty(); r int := mc.prop_int('view-distance') + 1;
        sx int; sy int; sz int; nch int; chunks bytea;
begin
  select * into p from mc.player where uuid = p_uuid and dead and conn_id is not null; if not found then return; end if;
  select * into gs from mc.game_state; select * into w from mc.world limit 1;
  tid := p.teleport_id + 1; op := mc.permission_level(p.uuid); sx := floor(gs.spawn_x)::int; sy := floor(gs.spawn_y)::int; sz := floor(gs.spawn_z)::int;
  -- viewers who still see the corpse forget it; the new player is announced by the next visibility pass, which also tells the respawned client about everybody
  insert into mc.play_out (conn_id, data) select v.viewer_conn, mc.pkt_remove_entities(array[p.entity_id]) from mc.visible v where v.target_eid = p.entity_id;
  delete from mc.visible where viewer_eid = p.entity_id or target_eid = p.entity_id;
  delete from mc.entity_viewer_cell where conn_id = p.conn_id;                  -- (the entity tracker's view of this client: its world was reset)
  update mc.player set dead = false, death_tick = null, health = 20, food = 20, saturation = 5, exhaustion = 0, food_timer = 0, fall_distance = 0, fall_tp = tid, hurt_tick = null,
         last_hurt = 0, cb_tick = null, cb_fall = 0, cb_type = null, use_slot = null, use_until = null, pend_slot = null, sprinting = false,
         xp_level = case when keep then xp_level else 0 end, xp_progress = case when keep then xp_progress else 0 end, xp_total = case when keep then xp_total else 0 end,
         xp_score = case when keep then xp_score else 0 end,
         x = gs.spawn_x, y = gs.spawn_y, z = gs.spawn_z, yaw = gs.spawn_yaw, pitch = 0, on_ground = true, chunk_x = floor(gs.spawn_x / 16)::int, chunk_z = floor(gs.spawn_z / 16)::int,
         sent_qx = mc.quant(gs.spawn_x), sent_qy = mc.quant(gs.spawn_y), sent_qz = mc.quant(gs.spawn_z), sent_yaw = gs.spawn_yaw, sent_pitch = 0, last_sent_tick = p_cur,
         vis_dirty = true, vis_ocx = null, vis_ocz = null, teleport_id = tid, awaiting_teleport = tid, inv_state = 1,
         sent_health = 20, sent_food = 20, sent_sat_zero = false, sent_eh = 20, sent_using = false, sent_score = case when keep then xp_score else 0 end,
         sent_xp_total = case when keep then xp_total else 0 end
   where uuid = p_uuid returning * into p;
  perform mc.generate_flat('minecraft:overworld', s.x, s.z) from net.chunk_square(p.chunk_x, p.chunk_z, r) s
   where not exists (select 1 from mc.chunk c where c.dimension = 'minecraft:overworld' and c.cx = s.x and c.cz = s.z);
  select string_agg(mc.chunk_packet('minecraft:overworld', q.x, q.z), '\x'::bytea order by q.o), count(*) into chunks, nch from (select x, z, row_number() over () as o from net.chunk_square(p.chunk_x, p.chunk_z, r)) q;
  update net.conn set view_cx = p.chunk_x, view_cz = p.chunk_z where conn_id = p.conn_id;
  insert into mc.play_out (conn_id, data) values (p.conn_id,
       mc.pkt_player_abilities(mc.gamemode_abilities(p.gamemode))
    || mc.pkt_respawn(p.gamemode, coalesce(w.seed, 0), p.death_x::int, p.death_y::int, p.death_z::int)
    || mc.pkt_player_position(tid, p.x, p.y, p.z, 0, 0, 0, p.yaw, p.pitch, 0)
    || mc.cb('set_default_spawn_position', proto.string('minecraft:overworld') || proto.position(sx, sy, sz) || proto.f32(gs.spawn_yaw) || proto.f32(0))
    || mc.pkt_change_difficulty(diff, false)
    || mc.pkt_set_experience(p.xp_progress, p.xp_level, p.xp_total)
    || mc.cb('post_effects', proto.varint(0))
    || mc.cb('initialize_border', proto.f64(0) || proto.f64(0) || proto.f64(5.9999968e7) || proto.f64(5.9999968e7) || proto.varlong(0) || proto.varint(29999984) || proto.varint(5) || proto.varint(300))
    || mc.pkt_set_time(gs.game_time, array[1, 0], array[gs.day_time, gs.day_time])
    || mc.cb('set_default_spawn_position', proto.string('minecraft:overworld') || proto.position(sx, sy, sz) || proto.f32(gs.spawn_yaw) || proto.f32(0))
    || mc.pkt_game_event(13, 0)
    || mc.cb('ticking_state', proto.f32(20) || proto.bool(false)) || mc.cb('ticking_step', proto.varint(0))
    || mc.pkt_entity_event(p.entity_id, 24 + op)
    || coalesce((select mc.cb(substr(s.packet, 11), s.body) from net.static_packet s where s.packet = 'minecraft:commands'), '\x'::bytea)
    || mc.cb('set_chunk_cache_center', proto.varint(p.chunk_x) || proto.varint(p.chunk_z))
    || mc.cb('container_set_content', proto.varint(0) || proto.varint(1) || proto.varint(46) || decode(repeat('00', 46), 'hex') || '\x00'::bytea)
    || mc.pkt_data_health(p.entity_id, 20)
    || coalesce((select mc.cb(substr(s.packet, 11), proto.varint(p.entity_id) || s.body) from net.static_packet s where s.packet = 'minecraft:update_attributes'), '\x'::bytea)
    || mc.pkt_set_health(20, 20, 5)
    || mc.pkt_set_experience(p.xp_progress, p.xp_level, p.xp_total)
    || mc.cb('chunk_batch_start', '\x') || chunks || mc.cb('chunk_batch_finished', proto.varint(nch)));
end $$;

create or replace function mc.survival_respawn(p_cur bigint) returns void language plpgsql as $$
declare i_cc int := mc.sid('client_command'); u uuid;
begin
  if not exists (select 1 from mc.play_in_work where packet_id = i_cc) then return; end if;
  for u in select p.uuid from mc.play_in_work m join mc.player p on p.conn_id = m.conn_id
            where m.packet_id = i_cc and p.dead and length(m.body) >= 1 and get_byte(m.body, 0) = 0 order by p.entity_id loop       -- action 0: perform_respawn (1: request_stats)
    perform mc.respawn_player(u, p_cur);
  end loop;
  delete from mc.play_in_work where packet_id = i_cc;
end $$;

------------------------------------------------------------------------------------------------ /kill
-- /kill [target]: the executor, or a player by name (target selectors are not implemented).  Feedback commands.kill.success.single (recorded) AFTER the death packets.
create or replace function mc.cmd_kill(p_conn int, tok text[]) returns void language plpgsql as $$
declare tgt mc.player;
begin
  tgt := case when tok[2] is null then (select p from mc.player p where p.conn_id = p_conn) else mc.find_player(tok[2]) end;
  if tgt.uuid is null then perform mc.feedback(p_conn, mc.tc_failure(mc.tc_translate('argument.entity.notfound.player'))); return; end if;
  perform mc.kill_players(array[tgt.uuid]);
  perform mc.feedback(p_conn, mc.tc_translate('commands.kill.success.single', array[mc.tc_player(tgt.uuid, tgt.name)]));
end $$;
insert into mc.command values ('kill', 2, 'kill [targets]') on conflict (name) do nothing;
