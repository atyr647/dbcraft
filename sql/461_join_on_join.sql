-- Login-path speed, round 2: mc.on_join, the O(online players) part of a join.
--
-- Measured (docs/PERF-JOIN.md): at 50 players online mc.on_join was 17 of the 33 ms of a join.  Its three INSERT ... SELECT statements evaluated the packet
-- expressions (join message: tc_player -> tc_translate -> nbt_root -> pkt_system_chat, 428 proto.mutf8 calls per join; tab entry: pie_add -> pkt_player_info_add)
-- once PER RECIPIENT ROW instead of once, and the third statement built the list of players already online for the joiner, which net.hook_join_info then DELETES
-- again (the entry burst carries the tab list).  Both are O(online players) with a large constant, so a storm of N joiners into N online players was quadratic in CPU.
--
-- Now: each packet is built once (a MATERIALIZED CTE: a stable function with a PL/pgSQL variable argument is not hoisted otherwise), and callers that discard the
-- joiner's own rows (net.hook_join_info) say so with p_to_joiner = false so they are never built.  The rows that are produced, their bytes and their order are
-- identical (tests/sql/461_join_on_join.sql compares them with the original on a populated server).

create or replace function mc.on_join(p_conn int, p_uuid uuid, p_name text, p_to_joiner boolean) returns mc.player language plpgsql as $$
declare p mc.player; gs mc.game_state; old_conn int;
begin
  select * into gs from mc.game_state;
  select conn_id into old_conn from mc.player where uuid = p_uuid;
  if old_conn is not null then perform mc.on_leave(old_conn, 'multiplayer.disconnect.duplicate_login'); end if;   -- vanilla kicks the older session
  insert into mc.player (uuid, name, gamemode, x, y, z, yaw, chunk_x, chunk_z)
  values (p_uuid, p_name, case mc.prop('gamemode') when 'creative' then 1 when 'adventure' then 2 when 'spectator' then 3 else 0 end,
          gs.spawn_x, gs.spawn_y, gs.spawn_z, gs.spawn_yaw, floor(gs.spawn_x / 16)::int, floor(gs.spawn_z / 16)::int)
  on conflict (uuid) do update set name = excluded.name
  returning * into p;
  update mc.player set conn_id = p_conn, entity_id = nextval('mc.entity_id_seq'), vis_dirty = true,
         chunk_x = floor(x / 16)::int, chunk_z = floor(z / 16)::int,
         sent_qx = mc.quant(x), sent_qy = mc.quant(y), sent_qz = mc.quant(z), sent_yaw = yaw, sent_pitch = pitch,
         awaiting_teleport = null, keepalive_id = null, keepalive_sent_tick = null, inv_state = 1, chat_recv = 0, chat_sent = 0   -- chat_sent: the per-session message index restarts at 0 (vanilla, recorded by tests/e2e/join_probe.py)
   where uuid = p_uuid returning * into p;
  -- 1. everyone (including the joiner, unless p_to_joiner is false) gets the join message, then the joiner's tab list entry (vanilla's order); each packet is built once
  with m as materialized (select mc.pkt_system_chat(proto.nbt_root(mc.tc_translate('multiplayer.player.joined', array[mc.tc_player(p.uuid, p.name)], 'yellow'))) as d)
  insert into mc.play_out (conn_id, data)
    select o.conn_id, m.d from mc.player o, m where o.conn_id is not null and (p_to_joiner or o.conn_id <> p_conn) order by o.entity_id;
  with m as materialized (select mc.pkt_player_info_add(array[mc.pie_add(p.uuid, p.name, p.gamemode)]) as d)
  insert into mc.play_out (conn_id, data)
    select o.conn_id, m.d from mc.player o, m where o.conn_id is not null and (p_to_joiner or o.conn_id <> p_conn) order by o.entity_id;
  -- 2. the joiner learns the players that are already online
  if p_to_joiner then
    insert into mc.play_out (conn_id, data)
      select p_conn, mc.pkt_player_info_add(array_agg(mc.pie_add(o.uuid, o.name, o.gamemode) order by o.entity_id))
        from mc.player o where o.conn_id is not null and o.uuid <> p.uuid having count(*) > 0;
  end if;
  return p;
end $$;

-- the original signature: everything the joiner would be told is still produced
create or replace function mc.on_join(p_conn int, p_uuid uuid, p_name text) returns mc.player language sql as $$
  select * from mc.on_join(p_conn, p_uuid, p_name, true) $$;

-- COPY of net.hook_join_info (sql/400_integration.sql) with ONE change, marked "round 2": it asks mc.on_join not to build what it would delete right after.
create or replace function net.hook_join_info(p_conn bigint) returns net.join_info language plpgsql volatile as $$
declare c net.conn; p mc.player; j net.join_info; gs mc.game_state; w mc.world; s record; st int;
begin
    select * into c from net.conn where conn_id = p_conn;
    select * into gs from mc.game_state;
    select * into w from mc.world limit 1;
    -- round 2: false = mc.on_join builds no rows for the joiner itself.  The original deleted them right after (DELETE ... WHERE seq > before AND conn_id = ...), and
    -- mc.play_out has no index, so every join scanned the whole queue: with a storm queueing about 1,200 rows per joiner that was quadratic in the number of joiners.
    p := mc.on_join(p_conn::int, c.uuid, c.name, false);
    -- the join teleport id is 1 (the next correction uses 2); the first keep-alive is due 15 s after joining, as in vanilla, not on the first tick
    update mc.player set teleport_id = 1, awaiting_teleport = null, keepalive_id = null, keepalive_sent_tick = gs.game_time where uuid = p.uuid;

    j := net.default_join_info(p_conn, p.gamemode);
    j.entity_id := p.entity_id;
    j.hardcore := mc.prop_bool('hardcore');
    j.max_players := mc.prop_int('max-players'); j.view_distance := mc.prop_int('view-distance'); j.simulation_distance := mc.prop_int('simulation-distance');
    j.seed := coalesce(w.seed, 0); j.is_flat := true; j.sea_level := -63;
    j.difficulty := case mc.prop('difficulty') when 'peaceful' then 0 when 'easy' then 1 when 'hard' then 3 else 2 end;
    j.held_slot := p.held_slot; j.op_level := mc.permission_level(p.uuid);
    j.x := p.x; j.y := p.y; j.z := p.z; j.yaw := p.yaw; j.pitch := p.pitch; j.teleport_id := 1;
    j.motd := mc.prop('motd');
    j.game_time := gs.game_time;
    j.clocks := jsonb_build_array(jsonb_build_object('id', 1, 'ticks', gs.day_time, 'partial', 0, 'rate', 1.0),
                                  jsonb_build_object('id', 0, 'ticks', gs.day_time, 'partial', 0, 'rate', 1.0));
    j.spawn_x := floor(gs.spawn_x)::int; j.spawn_y := floor(gs.spawn_y)::int; j.spawn_z := floor(gs.spawn_z)::int; j.spawn_yaw := gs.spawn_yaw;
    j.chunk_x := p.chunk_x; j.chunk_z := p.chunk_z;
    j.health := p.health; j.food := p.food; j.saturation := p.saturation; j.xp_level := p.xp_level;

    -- a returning player's inventory: the burst's container_set_content is empty, so send each stack as a slot update right after it
    st := 1;
    for s in select slot, item, count from mc.inventory_slot where player = p.uuid and components is null order by slot loop
        st := st + 1;
        insert into mc.play_out (conn_id, data) values (p_conn::int, mc.pkt_container_set_slot(st, s.slot, s.item, s.count));
    end loop;
    update mc.player set inv_state = st where uuid = p.uuid;
    return j;
end $$;
