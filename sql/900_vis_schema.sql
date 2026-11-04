-- Player visibility, part 1: state.  What other players see of a player (docs/PLAYER-VISIBILITY.md): entity data, equipment, attributes, animations, the tab list,
-- the locator bar, and who sees whom.  Everything is a row: the current value of each thing a viewer can see is a column of mc.player, the value the viewers were last
-- told is its sent_* twin, and one comparison per tick finds the players whose packets are due (the pattern of sql/830).
-- Rules and layouts were read from the 26.3 classes (javap -c: ServerEntity, ChunkMap$TrackedEntity, ServerGamePacketListenerImpl, Player, ServerPlayer,
-- ServerWaypointManager, WaypointTransmitter, SynchedEntityData) and compared with what the real server sent two scripted clients (tests/e2e/vis_probe.py).

------------------------------------------------------------------------------------------------ reference data: item components
-- Loaded by tools/load_item_components.py from the data generator's per-item component reports.  Empty until loaded: items then add no attribute modifiers.
create table if not exists ref.item_info (
    item text primary key,
    equip_slot text,                    -- head, chest, legs, feet, body, offhand, saddle: where `equippable` puts the item (null: not equippable)
    max_stack int,
    attack_animation text               -- the swing animation component as JSON ({} = the default: whack, 6 ticks)
);
create table if not exists ref.item_attr (
    item text not null, ord int not null,
    slot text not null,                 -- mainhand, head, chest, legs, feet, body: the slot the modifier applies in
    attribute text not null, amount float8 not null, op text not null,   -- add_value | add_multiplied_base | add_multiplied_total
    mod_id text not null,               -- the modifier's id, e.g. minecraft:armor.helmet
    primary key (item, ord)
);

------------------------------------------------------------------------------------------------ settings
-- vanilla's locator bar: gamerule locator_bar (default true), read with mc.rule_bool; the tracking range of players in blocks is EntityType.PLAYER.clientTrackingRange (32 chunks) and is scaled by
-- entity-broadcast-range-percentage (server.properties, in mc.server_property already) exactly as MinecraftServer.getScaledTrackingDistance does.
insert into mc.server_property (key, value, default_value, note)
values ('dbcraft.vanilla-tracker', 'true', 'true', 'dbcraft: send other players what vanilla sends them (entity data, equipment, attributes, animations, waypoints, tracking ranges: docs/PLAYER-VISIBILITY.md); false = the older simplified broadcast (movement only)')
on conflict (key) do nothing;

------------------------------------------------------------------------------------------------ state
alter table mc.player
    -- what the player does (the inputs behind the entity data other players see)
    add column if not exists shift      boolean  not null default false,    -- the shift key (player_input), entity flag 0x02
    add column if not exists flying     boolean  not null default false,    -- abilities.flying (player_abilities): a flying player does not crouch
    add column if not exists pose       smallint not null default 0,        -- entity data index 6: 0 standing, 5 crouching (Pose ordinal); updated in the ENTITY phase of a tick, so it reaches the viewers a tick after the flag
    add column if not exists skin_parts smallint not null default 0,        -- client_information skin layers (entity data index 16)
    add column if not exists main_hand  smallint not null default 1,        -- 0 left, 1 right (entity data index 15)
    add column if not exists view_distance_req int,                         -- the view distance the client asked for (client_information); null = it never said (vanilla's default is 2)
    add column if not exists sim_distance_req int,
    add column if not exists vis_x float8, add column if not exists vis_z float8,   -- the position the player's pairs were last evaluated at (sql/909)
    -- what the viewers were last told (null = the burst / the pairing carried the current values)
    add column if not exists sent_flags smallint, add column if not exists sent_pose smallint, add column if not exists sent_skin smallint, add column if not exists sent_arm smallint,
    add column if not exists sent_hat boolean,
    add column if not exists sent_equip text[],                             -- the six visible stacks last sent (main hand, off hand, feet, legs, chest, head: EquipmentSlot order) as hex of their wire form, '' = empty
    add column if not exists sent_held  smallint,                           -- the held slot the main-hand entry above belongs to
    add column if not exists equip_dirty boolean not null default true,     -- an inventory slot that is visible changed (trigger on mc.inventory_slot) or the held slot changed
    add column if not exists attr_sent  jsonb,                              -- {attribute id: hex of the entry last sent (base + modifiers)}; null = nothing sent yet
    add column if not exists attr_gm    smallint,                           -- the game mode and sprint state the attribute modifiers were last computed for
    add column if not exists attr_spr   boolean,
    add column if not exists attr_seen  bigint not null default 0,          -- bit i: the attribute with registry id i exists in the player's attribute map (instances are created lazily; the pairing lists existing ones)
    add column if not exists attr_due   bigint,                             -- tick from which a changed attribute is sent (equipment changes show in attributes one tick later)
    -- the tracker (ServerEntity): a counter from the entity's creation, the exact position viewers were last told, the angles last sent, the head rotation
    add column if not exists trk_start  bigint,                             -- the tick the entity was created: tickCount = tick - trk_start; the movement body runs on even tickCounts (updateInterval 2)
    -- (the exact position last sent, the angles last sent and the head rotation change every tick of a moving player: they live in the narrow table mc.vtrk below)
    add column if not exists trk_sync   int not null default -2,            -- the tickCount of the last full position sync / the creation: teleportDelay = (tickCount - trk_sync) / 2 (a sync is forced after 400)
    add column if not exists trk_ground boolean,                            -- wasOnGround
    -- the entity was just created (a join, a respawn): the first tracker pass has not run, and (fresh_join) a player who has never played here has no attribute instances yet
    add column if not exists trk_first boolean not null default false,
    add column if not exists fresh_join boolean not null default false,
    -- who is re-checked against whom
    add column if not exists vis_recheck boolean not null default false,    -- something that decides who may see this player changed (game mode): its pairs are re-evaluated when it or a viewer sends a movement packet (ChunkMap.move)
    add column if not exists tp_ground_tick bigint,                         -- the tick of the entity phase that puts a player moved by the server back on the ground
    add column if not exists vis_wake bigint,                               -- the tracker looks at this player on every tick up to this one whether it moved or not (a teleport, a game mode change, a join: things that change what a body is)
    add column if not exists yaw_prev real,                                 -- the yaw before this tick's movement packet (set with last_move_tick by the movement step): the head of the tracker's body
    add column if not exists last_move_tick bigint,                         -- the tick of the last movement packet (any of the four kinds)
    add column if not exists swing_tick bigint;                             -- the tick of the last arm swing that was broadcast (LivingEntity.swing ignores a second one in the first half of the animation)

-- The hot state of the entity tracker (ServerEntity): what a player's viewers were last told about its position and angles.  It changes on every movement body of a moving player, so it
-- is NOT in the wide mc.player row (a wide row is rewritten whole by every UPDATE).  UNLOGGED, fillfactor 50 and no indexed column ever changes: the updates are HOT, in place.
-- One row per online player, made by the join trigger below, removed when the player leaves.
create unlogged table if not exists mc.vtrk (
    entity_id int primary key,
    base_x float8, base_y float8, base_z float8,                  -- VecDeltaCodec.base: the exact position last sent
    sent_yb smallint, sent_pb smallint, sent_hb smallint          -- lastSentYRot / XRot / YHeadRot (Mth.packDegrees, 0-255)
) with (fillfactor = 50);

-- the answer of mc.vis_find (sql/905): who has work this tick.  One scan of the online players computes it; the steps of the tick use it instead of scanning again.
do $$ begin
    if not exists (select 1 from pg_type where typname = 'vis_work' and typnamespace = 'mc'::regnamespace) then
        create type mc.vis_work as (cur bigint, n int, nvt int, dirty int[], mvn int, ed int[], eq boolean, att boolean, pose boolean, tpg boolean, first boolean, wp1 boolean, wp2 boolean, recheck boolean);
    end if;
end $$;

-- the flags byte of entity data index 0 and the pose, as functions of a row (inlinable)
create or replace function mc.ed_flags(p_shift boolean, p_sprint boolean, p_gamemode smallint) returns int language sql immutable parallel safe as $$
  select (case when p_shift then 2 else 0 end) | (case when p_sprint then 8 else 0 end) | (case when p_gamemode = 3 then 32 else 0 end) $$;

-- A joining session: what the join burst / the pairing carries counts as sent; the row's tracker state starts clean.  (sql/830's trigger does the same for health etc.)
create or replace function mc.vis_on_join() returns trigger language plpgsql as $$
declare gt bigint := (select game_time from mc.game_state);
begin
  if tg_op = 'INSERT' and not mc.vis_on() then return new; end if;       -- a row inserted online with the classic broadcast: nothing to start (mc.vis_init_missing does it if the layer is switched on later)
  new.shift := false; new.flying := new.gamemode = 3; new.pose := 0;
  new.sent_flags := mc.ed_flags(false, false, new.gamemode); new.sent_pose := 0; new.sent_skin := new.skin_parts; new.sent_arm := new.main_hand; new.sent_hat := (new.skin_parts & 64) <> 0;
  new.sent_equip := null; new.sent_held := null; new.equip_dirty := true; new.attr_sent := null; new.attr_due := null; new.attr_gm := new.gamemode; new.attr_spr := false; new.vis_recheck := false; new.last_move_tick := null; new.swing_tick := null; new.trk_first := true; new.fresh_join := false;
  new.trk_start := gt + 1; new.vis_wake := gt + 8;
  new.wp_state := null; new.wp_bx := floor(new.x)::int; new.wp_by := floor(new.y)::int; new.wp_bz := floor(new.z)::int; new.wp_cx := new.chunk_x; new.wp_cz := new.chunk_z;       -- (sql/908: the locator bar)
  new.vis_x := new.x; new.vis_z := new.z;
  new.trk_sync := -2; new.trk_ground := new.on_ground; new.yaw_prev := new.yaw;
  new.view_distance_req := null; new.sim_distance_req := null;
  if new.entity_id is not null then
    insert into mc.vtrk (entity_id, base_x, base_y, base_z, sent_yb, sent_pb, sent_hb)
    values (new.entity_id, new.x, new.y, new.z, mc.angle_byte(new.yaw), mc.angle_byte(new.pitch), mc.angle_byte(new.yaw))
    on conflict (entity_id) do update set base_x = excluded.base_x, base_y = excluded.base_y, base_z = excluded.base_z, sent_yb = excluded.sent_yb, sent_pb = excluded.sent_pb, sent_hb = excluded.sent_hb;
  end if;
  return new;
end $$;
drop trigger if exists vis_on_join on mc.player;
create trigger vis_on_join before update on mc.player for each row when (old.conn_id is null and new.conn_id is not null) execute function mc.vis_on_join();
drop trigger if exists vis_on_insert on mc.player;
create trigger vis_on_insert before insert on mc.player for each row when (new.conn_id is not null) execute function mc.vis_on_join();      -- a row made online (a tool, a test)

create or replace function mc.vis_on_leave() returns trigger language plpgsql as $$
begin
  delete from mc.vtrk where entity_id = old.entity_id;
  return null;
end $$;
drop trigger if exists vis_on_leave on mc.player;
create trigger vis_on_leave after update on mc.player for each row when (old.conn_id is not null and new.conn_id is null and old.entity_id is not null) execute function mc.vis_on_leave();
drop trigger if exists vis_on_delete on mc.player;
create trigger vis_on_delete after delete on mc.player for each row when (old.conn_id is not null and old.entity_id is not null) execute function mc.vis_on_leave();

-- an inventory change that other players can see (armor 5-8, hotbar 36-44, off hand 45) marks its owner for the equipment comparison
create or replace function mc.vis_equip_touch() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.slot in (5, 6, 7, 8, 45) or old.slot between 36 and 44 then update mc.player set equip_dirty = true where uuid = old.player and not equip_dirty; end if;
    return old;
  end if;
  if new.slot in (5, 6, 7, 8, 45) or new.slot between 36 and 44 then update mc.player set equip_dirty = true where uuid = new.player and not equip_dirty; end if;
  return new;
end $$;
drop trigger if exists vis_equip_touch on mc.inventory_slot;
create trigger vis_equip_touch after insert or update or delete on mc.inventory_slot for each row execute function mc.vis_equip_touch();

create or replace function mc.vis_on() returns boolean language plpgsql stable as $$
begin return coalesce((select value::boolean from mc.server_property where key = 'dbcraft.vanilla-tracker'), false); end $$;

-- a game mode change re-checks who may see the player (spectators are hidden from everybody who is not a spectator); the pairs are re-evaluated at the next movement packet
create or replace function mc.vis_gamemode_changed() returns trigger language plpgsql as $$
begin
  new.vis_recheck := true;
  new.vis_wake := (select game_time from mc.game_state) + 8;
  new.flying := case new.gamemode when 3 then true when 0 then false when 2 then false else new.flying end;     -- Player.setGameMode / onUpdateAbilities: spectators fly, survival and adventure players do not
  return new;
end $$;
drop trigger if exists vis_gamemode_changed on mc.player;
create trigger vis_gamemode_changed before update of gamemode on mc.player for each row when (old.gamemode is distinct from new.gamemode and new.conn_id is not null) execute function mc.vis_gamemode_changed();
