-- Mining, part 2: the digging protocol (docs/MINING-AND-COMMANDS.md).  ServerPlayerGameMode.handleBlockBreakAction / tick / destroyBlock and ServerGamePacketListenerImpl.handlePlayerAction,
-- read from the 26.3 bytecode and compared with the real server by tests/e2e/mine_probe.py + compare_mine.py.
--
-- What a dig is, to the packets:
--   START_DESTROY_BLOCK  (action 0)  creative: the block goes at once.  Survival: the destroy progress of the block (hardness, tool, ground, water) is computed; a block that is
--                                    mined in one go (progress >= 1) goes at once ("insta mine"), otherwise the dig starts: every OTHER player within 32 blocks gets a
--                                    block_destruction (the crack, stage = int(progress * 10)).  Adventure and spectator players are sent the block's real state.
--   every tick of the dig            the crack stage is sent to the others when it changed, and level_event 2019 (2020 every 4th tick: the hit sound and particles) to every player
--                                    within 64 blocks, the digger included.  The progress is  destroyProgress * (ticks + 1)  with ticks = game ticks since the START.
--   STOP_DESTROY_BLOCK   (action 3)  accepted when progress * (ticks + 1) >= 0.7: the crack is cleared (stage -1) and the block breaks.  Otherwise it is "delayed": the server keeps
--                                    counting by itself and breaks the block when the progress reaches 1.0 (no acknowledgement for that; the stop packet was acknowledged).
--   ABORT_DESTROY_BLOCK  (action 2)  the dig ends, the crack is cleared.   CHANGE_DESTROY_DIRECTION (action 1)  only changes the direction of the 2019 / 2020 events.
--   A block out of reach (block interaction range 4.5, creative 5.0, plus 1.0 of slack, against the eye position) is ignored (an abort still ends a dig); above the build height the
--   client is sent the block's state.  Every packet but the direction change is acknowledged with block_changed_ack (the ack is queued by mc.apply_block_actions).
--
-- Breaking (ServerPlayerGameMode.destroyBlock): refused (the client is sent the block's state) for a creative player holding a sword (Tool.canDestroyBlocksInCreative), a game master
-- block without a creative operator, adventure and spectator players.  The block becomes air (water when it was waterlogged).  Creative: nothing else.  Survival: the tool loses
-- damage_per_block durability when the block's hardness is not 0 (Item.mineBlock; it breaks at its max damage: entity_event 47, the stack vanishes); when the tool is the correct one
-- for the block's drops (or the block does not need one) the player is exhausted by 0.005 and the block drops its loot (sql/892).
--
-- Ticks: mc.server_tick runs mc.apply_block_actions (the packets) and then mc.mining_tick (ServerPlayerGameMode.tick), as vanilla handles the queued packets before it ticks the
-- players.  `gameTicks` is the server tick counter minus one while packets are handled (vanilla's counter is raised by the tick that follows).
--
-- Not modelled, and why: enchantments and their effects (efficiency, unbreaking, silk touch, fortune, aqua affinity: item components other than the damage are kept but not read),
-- potion effects (haste, mining fatigue: no effects exist), attributes other than their defaults, spawn protection, the world border, the `player_loaded` gate, block entities'
-- own destroy rules (beds, doors' other half are the block-support rules of sql/886), experience from ores, piglin anger.

create unlogged table if not exists mc.mining (
    uuid        uuid primary key,
    destroying  boolean not null default false,        -- ServerPlayerGameMode.isDestroyingBlock
    start_gt    bigint  not null default 0,            -- destroyProgressStart
    x int not null default 0, y int not null default 0, z int not null default 0,       -- destroyPos
    dir         int     not null default 0,            -- destroyDirection (Direction ordinal: down up north south west east)
    last_state  int     not null default -1,           -- lastSentState
    delayed     boolean not null default false,        -- hasDelayedDestroy
    dx int not null default 0, dy int not null default 0, dz int not null default 0,    -- delayedDestroyPos
    dstart      bigint  not null default 0             -- delayedTickStart
);

------------------------------------------------------------------------------------------------ what the player holds, where the eyes are
create or replace function mc.held_item(p_uuid uuid, p_held int) returns text language sql stable as $$
  select i.item from mc.inventory_slot i where i.player = p_uuid and i.slot = 36 + p_held $$;

-- Entity.updateFluidOnEyes: is the eye in a water cell below its surface?  Source water and waterlogged blocks have the height 8/9, flowing water (9 - level) / 9 (a falling column and
-- a cell with water above it are full: FlowingFluid.getHeight).
create or replace function mc.eye_in_water(px float8, py float8, pz float8, p_sneaking boolean) returns boolean language plpgsql stable as $$
declare ey float8 := py + case when p_sneaking then 1.27 else 1.62 end; bx int := floor(px)::int; yy int := floor(ey)::int; bz int := floor(pz)::int; s text; lvl int; h float8;
begin
  s := mc.get_block('minecraft:overworld', bx, yy, bz);
  if s is null then return false; end if;
  if s like 'minecraft:water%' then
    lvl := coalesce(substring(s from 'level=([0-9]+)')::int, 0); h := case when lvl = 0 or lvl >= 8 then 8.0 / 9 else (8 - lvl) / 9.0 end;
  elsif s like '%waterlogged=true%' then h := 8.0 / 9;
  else return false; end if;
  s := mc.get_block('minecraft:overworld', bx, yy + 1, bz);
  if s like 'minecraft:water%' or s like '%waterlogged=true%' then h := 1.0; end if;
  return yy + h > ey;
end $$;

-- ServerPlayer.isWithinBlockInteractionRange(pos, 1.0): the block's box against the eye, range 4.5 (creative 5.0) + 1.0
create or replace function mc.in_dig_reach(p mc.player, bx int, yy int, bz int) returns boolean language sql immutable as $$
  select (power(greatest(bx - p.x, 0, p.x - (bx + 1)), 2) + power(greatest(yy - (p.y + case when p.sneaking then 1.27 else 1.62 end), 0, (p.y + case when p.sneaking then 1.27 else 1.62 end) - (yy + 1)), 2)
          + power(greatest(bz - p.z, 0, p.z - (bz + 1)), 2)) < power(case when p.gamemode = 1 then 6.0 else 5.5 end, 2) $$;

------------------------------------------------------------------------------------------------ the destroy speed and progress (float32 arithmetic: `real`)
-- Player.getDestroySpeed: the held item's speed for the block; efficiency (+) and haste / mining fatigue are not modelled; * the block-break-speed attribute (1.0); * the
-- submerged-mining-speed attribute (0.2) with the eyes in water; / 5 off the ground
create or replace function mc.dig_speed(p mc.player, p_item text, p_state text) returns real language plpgsql stable as $$
declare f real := mc.tool_speed(p_item, p_state);
begin
  if mc.eye_in_water(p.x, p.y, p.z, p.sneaking) then f := f * 0.2::real; end if;
  if not p.on_ground then f := f / 5::real; end if;
  return f;
end $$;

-- BlockBehaviour.getDestroyProgress: speed / hardness / (30 with the correct tool or none needed, else 100); an unbreakable block (-1) has none; a block of hardness 0 divides
-- by zero in Java's float arithmetic: infinity
create or replace function mc.dig_progress(p mc.player, p_item text, p_state text) returns real language plpgsql stable as $$
declare h real := mc.block_hardness(p_state); i real;
begin
  if h = -1::real then return 0; end if;
  i := case when mc.has_correct_tool(p_item, p_state) then 30 else 100 end;
  if h = 0::real then return 'Infinity'::real; end if;
  return (mc.dig_speed(p, p_item, p_state) / h) / i;
end $$;

------------------------------------------------------------------------------------------------ packets to other players
-- ServerLevel.destroyBlockProgress: everybody but the breaker within 32 blocks (the block's corner against the player's position, strictly less than 32)
create or replace function mc.destroy_progress_broadcast(p_eid int, bx int, yy int, bz int, p_stage int) returns void language sql as $$
  insert into mc.play_out (conn_id, data)
  select q.conn_id, proto.frame(mc.pid('block_destruction'), proto.varint(p_eid) || proto.position(bx, yy, bz) || set_byte('\x00'::bytea, 0, p_stage & 255))
    from mc.player q where q.conn_id is not null and q.entity_id is distinct from p_eid
     and (bx - q.x) ^ 2 + (yy - q.y) ^ 2 + (bz - q.z) ^ 2 < 1024 order by q.entity_id $$;

-- ServerLevel.levelEvent(null, ...): everybody within 64 blocks of the block (its corner), the digger included
create or replace function mc.level_event_near(p_event int, bx int, yy int, bz int, p_data int) returns void language sql as $$
  insert into mc.play_out (conn_id, data)
  select q.conn_id, proto.frame(mc.pid('level_event'), proto.i32(p_event) || proto.position(bx, yy, bz) || proto.i32(p_data) || '\x00'::bytea)
    from mc.player q where q.conn_id is not null and (bx - q.x) ^ 2 + (yy - q.y) ^ 2 + (bz - q.z) ^ 2 < 4096 order by q.entity_id $$;

------------------------------------------------------------------------------------------------ the tool loses durability
-- the damage of a stack's component patch: only a patch that is empty or holds nothing but `minecraft:damage` is read (anything else: NULL = unknown)
create or replace function mc.patch_damage(p_hex text) returns int language plpgsql stable as $$
declare b bytea; did int := (select protocol_id from ref.registry where registry = 'minecraft:data_component_type' and name = 'minecraft:damage'); o int;
begin
  if p_hex is null or p_hex = '0000' then return 0; end if;
  b := decode(p_hex, 'hex');
  if get_byte(b, 0) = 1 and get_byte(b, 1) = 0 and get_byte(b, 2) = did then return (select val from proto.varint_read(b, 3)); end if;
  return null;
end $$;
create or replace function mc.damage_patch(p_damage int) returns text language sql stable as $$
  select case when p_damage <= 0 then null else '0100' || encode(proto.varint((select protocol_id from ref.registry where registry = 'minecraft:data_component_type' and name = 'minecraft:damage')) || proto.varint(p_damage), 'hex') end $$;

-- ItemStack.hurtAndBreak(amount, level, player, onBreak) for the held item of a survival player: setDamageValue; at max damage the stack shrinks by one, the break event goes to
-- the player and everybody who sees it (entity_event 47: the main hand's tool broke).  The slot is sent to the owner (the inventory menu's broadcast of the changed slot).
create or replace function mc.tool_hurt(p_uuid uuid, p_held int, p_amount int) returns void language plpgsql as $$
declare s record; mx int; d int; nd int; slot int := 36 + p_held; state int; p mc.player;
begin
  select i.item, i.count, i.components ->> 'raw_hex' as hex into s from mc.inventory_slot i where i.player = p_uuid and i.slot = slot;
  if not found then return; end if;
  select t.max_damage into mx from ref.item_tool t where t.item = s.item;
  if mx is null or mx <= 0 or p_amount <= 0 then return; end if;
  d := mc.patch_damage(s.hex);
  if d is null then return; end if;                                  -- other components are kept but their damage is not tracked
  nd := d + p_amount;
  select * into p from mc.player where uuid = p_uuid;
  if nd >= mx then                                                    -- broken
    perform mc.set_slot(p_uuid, slot, null, 0);
    update mc.player set inv_state = inv_state + 1 where uuid = p_uuid returning inv_state into state;
    insert into mc.play_out (conn_id, data) values (p.conn_id, mc.pkt_cs(0, state, slot, mc.s_empty()));
    insert into mc.play_out (conn_id, data)
      select c.conn_id, mc.pkt_entity_event(p.entity_id, 47) from (select p.conn_id union select v.viewer_conn from mc.visible v where v.target_eid = p.entity_id) c order by c.conn_id;
  else
    perform mc.set_slot(p_uuid, slot, s.item, s.count, case when mc.damage_patch(nd) is null then null else jsonb_build_object('raw_hex', mc.damage_patch(nd)) end);
    update mc.player set inv_state = inv_state + 1 where uuid = p_uuid returning inv_state into state;
    insert into mc.play_out (conn_id, data) values (p.conn_id, mc.pkt_cs(0, state, slot, mc.s_mk(s.item, s.count, mc.damage_patch(nd))));
  end if;
end $$;

------------------------------------------------------------------------------------------------ breaking
-- ServerPlayerGameMode.destroyBlock: true when the block was broken (or there was nothing to break)
create or replace function mc.mining_destroy(p mc.player, bx int, yy int, bz int) returns boolean language plpgsql as $$
declare dim text := 'minecraft:overworld'; st text := coalesce(mc.get_block(dim, bx, yy, bz), 'minecraft:air'); item text := mc.held_item(p.uuid, p.held_slot); creative_ok boolean; ns text; correct boolean;
begin
  if mc.is_air(st) then return true; end if;
  select t.creative_ok into creative_ok from ref.item_tool t where t.item = item;
  if p.gamemode = 1 and creative_ok = false then return false; end if;                                             -- Item.canDestroyBlock: a sword does not break blocks in creative
  if split_part(st, '[', 1) in ('minecraft:command_block', 'minecraft:repeating_command_block', 'minecraft:chain_command_block', 'minecraft:structure_block', 'minecraft:jigsaw',
                                'minecraft:test_block', 'minecraft:test_instance_block')
     and not (p.gamemode = 1 and mc.permission_level(p.uuid) >= 2) then                                              -- GameMasterBlock: sendBlockUpdated, then the caller's own update
    perform mc.queue_block_update(p.conn_id, bx, yy, bz, st);
    return false;
  end if;
  if p.gamemode in (2, 3) then return false; end if;                                                                 -- blockActionRestricted
  correct := mc.has_correct_tool(item, st);
  ns := case when st like '%waterlogged=true%' then 'minecraft:water[level=0]' else 'minecraft:air' end;           -- removeBlock: the fluid takes the cell
  perform mc.set_block(dim, bx, yy, bz, ns);
  perform mc.shape_neighbours(dim, bx, yy, bz);                                                                      -- (sql/890) a fence next to it no longer connects
  insert into mc.block_actor values (dim, bx, yy, bz, p.conn_id);
  if p.gamemode = 1 then return true; end if;                                                                        -- creative: preventsBlockDrops
  if mc.block_hardness(st) <> 0::real then perform mc.tool_hurt(p.uuid, p.held_slot, coalesce((select t.damage_per_block from ref.item_tool t where t.item = item), 0)); end if;      -- Item.mineBlock
  if correct then                                                                                                    -- Block.playerDestroy
    update mc.player set exhaustion = least(exhaustion + 0.005::real, 40::real) where uuid = p.uuid;
    perform mc.block_drops(p, bx, yy, bz, st, item);
  end if;
  return true;
end $$;

-- destroyAndAck: the block, or the client is sent what the block really is
create or replace function mc.mining_destroy_ack(p mc.player, bx int, yy int, bz int) returns int language plpgsql as $$
begin
  if mc.mining_destroy(p, bx, yy, bz) then return 1; end if;
  perform mc.queue_block_update(p.conn_id, bx, yy, bz, coalesce(mc.get_block('minecraft:overworld', bx, yy, bz), 'minecraft:air'));
  return 0;
end $$;

------------------------------------------------------------------------------------------------ the packets of one player
-- ServerPlayerGameMode.handleBlockBreakAction.  p_act: 0 start, 1 change direction, 2 abort, 3 stop.  Returns 1 when a block was broken.
create or replace function mc.mining_action(p_uuid uuid, p_act int, bx int, yy int, bz int, p_face int, cur bigint) returns int language plpgsql as $$
declare p mc.player; m mc.mining; st text; f real; j bigint; gt bigint; item text; broke int := 0; stage int;
begin
  select * into p from mc.player where uuid = p_uuid;
  if not found or p.conn_id is null then return 0; end if;
  gt := cur - 1 - coalesce(p.join_tick, 0);                                                   -- gameTicks: this player's own counter (it starts at the join), one behind while packets are handled
  insert into mc.mining (uuid) values (p_uuid) on conflict do nothing;
  select * into m from mc.mining where uuid = p_uuid;
  if not mc.in_dig_reach(p, bx, yy, bz) then                                                  -- "too far"
    if m.destroying and p_act = 2 then
      update mc.mining set destroying = false where uuid = p_uuid;
      if (m.x, m.y, m.z) <> (bx, yy, bz) then perform mc.destroy_progress_broadcast(p.entity_id, m.x, m.y, m.z, -1); end if;
      perform mc.destroy_progress_broadcast(p.entity_id, bx, yy, bz, -1);
    end if;
  elsif yy > 319 then                                                                           -- "too high"
    perform mc.queue_block_update(p.conn_id, bx, yy, bz, coalesce(mc.get_block('minecraft:overworld', bx, yy, bz), 'minecraft:air'));
  elsif p_act = 0 then
    st := coalesce(mc.get_block('minecraft:overworld', bx, yy, bz), 'minecraft:air');
    if p.gamemode = 1 then
      broke := mc.mining_destroy_ack(p, bx, yy, bz);                                          -- "creative destroy"
    elsif p.gamemode in (2, 3) then
      perform mc.queue_block_update(p.conn_id, bx, yy, bz, st);                                 -- "block action restricted"
    else
      f := 1;
      item := mc.held_item(p_uuid, p.held_slot);
      if not mc.is_air(st) then f := mc.dig_progress(p, item, st); end if;
      if not mc.is_air(st) and f >= 1::real then
        broke := mc.mining_destroy_ack(p, bx, yy, bz);                                          -- "insta mine"
        update mc.mining set start_gt = gt where uuid = p_uuid;
      else
        if m.destroying then perform mc.queue_block_update(p.conn_id, m.x, m.y, m.z, coalesce(mc.get_block('minecraft:overworld', m.x, m.y, m.z), 'minecraft:air')); end if;
        stage := least(trunc((f * 10::real)::float8), 2147483647)::int;
        update mc.mining set destroying = true, start_gt = gt, x = bx, y = yy, z = bz, dir = p_face, last_state = stage where uuid = p_uuid;
        perform mc.destroy_progress_broadcast(p.entity_id, bx, yy, bz, stage);
      end if;
    end if;
  elsif p_act = 1 then
    update mc.mining set dir = p_face where uuid = p_uuid;
  elsif p_act = 3 then
    if (bx, yy, bz) = (m.x, m.y, m.z) then
      j := gt - m.start_gt;
      st := coalesce(mc.get_block('minecraft:overworld', bx, yy, bz), 'minecraft:air');
      if not mc.is_air(st) then
        item := mc.held_item(p_uuid, p.held_slot);
        f := mc.dig_progress(p, item, st) * (j + 1)::real;
        if f >= 0.7::real then
          update mc.mining set destroying = false where uuid = p_uuid;
          perform mc.destroy_progress_broadcast(p.entity_id, bx, yy, bz, -1);
          broke := mc.mining_destroy_ack(p, bx, yy, bz);                                       -- "destroyed"
        elsif not m.delayed then
          update mc.mining set destroying = false, delayed = true, dx = bx, dy = yy, dz = bz, dstart = m.start_gt where uuid = p_uuid;
        end if;
      end if;
    end if;
  elsif p_act = 2 then                                                                          -- abortDestroyBlock
    update mc.mining set destroying = false where uuid = p_uuid;
    if (m.x, m.y, m.z) <> (bx, yy, bz) then perform mc.destroy_progress_broadcast(p.entity_id, m.x, m.y, m.z, -1); end if;
    perform mc.destroy_progress_broadcast(p.entity_id, bx, yy, bz, -1);
  end if;
  delete from mc.mining where uuid = p_uuid and not destroying and not delayed;
  return broke;
end $$;

------------------------------------------------------------------------------------------------ ServerPlayerGameMode.tick
-- incrementDestroyProgress(state, pos, ticks): the crack stage is sent to the others when it changed; returns the progress  destroyProgress * (ticks + 1)
create or replace function mc.mining_increment(p mc.player, m mc.mining, p_state text, bx int, yy int, bz int, p_ticks bigint) returns real language plpgsql as $$
declare f real; stage int;
begin
  f := mc.dig_progress(p, mc.held_item(p.uuid, p.held_slot), p_state) * (p_ticks + 1)::real;
  stage := least(trunc((f * 10::real)::float8), 2147483647)::int;
  if stage <> m.last_state then
    perform mc.destroy_progress_broadcast(p.entity_id, bx, yy, bz, stage);
    update mc.mining set last_state = stage where uuid = m.uuid;
  end if;
  return f;
end $$;

create or replace function mc.mining_tick(cur bigint) returns void language plpgsql as $$
declare m mc.mining; p mc.player; st text; f real; i bigint; gt bigint;
begin
  for m in select mi.* from mc.mining mi join mc.player pl on pl.uuid = mi.uuid order by pl.entity_id loop
    select * into p from mc.player where uuid = m.uuid;
    if p.conn_id is null or p.dead then delete from mc.mining where uuid = m.uuid; continue; end if;
    gt := cur - coalesce(p.join_tick, 0);                                                       -- gameTicks after this tick's increment
    if m.delayed then
      st := coalesce(mc.get_block('minecraft:overworld', m.dx, m.dy, m.dz), 'minecraft:air');
      if mc.is_air(st) then update mc.mining set delayed = false where uuid = m.uuid;
      else
        f := mc.mining_increment(p, m, st, m.dx, m.dy, m.dz, m.dstart);                      -- (vanilla passes delayedTickStart itself as the tick count: the progress of a delayed dig is
                                                                                         -- progress * (start tick + 1), constant while it waits: a long-online player's dig finishes at once, a new player's never)
        if f >= 1::real then
          update mc.mining set delayed = false where uuid = m.uuid;
          perform mc.mining_destroy(p, m.dx, m.dy, m.dz);                                       -- (destroyBlock only: no acknowledgement)
        end if;
      end if;
    elsif m.destroying then
      st := coalesce(mc.get_block('minecraft:overworld', m.x, m.y, m.z), 'minecraft:air');
      if mc.is_air(st) then
        perform mc.destroy_progress_broadcast(p.entity_id, m.x, m.y, m.z, -1);
        update mc.mining set last_state = -1, destroying = false where uuid = m.uuid;
      else
        i := gt - m.start_gt;
        perform mc.mining_increment(p, m, st, m.x, m.y, m.z, i);
        perform mc.level_event_near(case when i % 4 = 0 then 2020 else 2019 end, m.x, m.y, m.z, m.dir);
      end if;
    end if;
  end loop;
  delete from mc.mining where not destroying and not delayed;
end $$;
