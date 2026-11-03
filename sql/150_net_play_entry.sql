-- Entering the play state: the packets vanilla 26.3 sends after finish_configuration, in the order it sends them.
-- Layouts were read from the 26.3 packet classes and confirmed against a capture (tests/sql/150_net_play_entry.sql replays it).
--
-- Everything player- or world-specific comes from one record, net.join_info, produced by net.hook_join_info(conn_id) (sql/190_net_hooks.sql).
-- The game layer replaces that hook with real player and world rows; until then net.default_join_info gives a plain world.
--
-- OPAQUE PACKETS: update_recipes, commands, recipe_book_add, update_advancements and the player's own set_entity_data / update_attributes
-- are stored as captured bytes in net.static_packet (loaded by tools/load_static_packets.py).  They are correct for what they were captured
-- for (a creative player in a flat world) but are NOT yet generated from readable rows; see docs/NET.md.

drop type if exists net.join_info cascade;
create type net.join_info as (
    -- login
    entity_id int, hardcore boolean, levels text[], max_players int, view_distance int, simulation_distance int,
    reduced_debug boolean, show_death_screen boolean, limited_crafting boolean,
    dimension_type text, dimension text, seed bigint, gamemode int, prev_gamemode int, is_debug boolean, is_flat boolean,
    portal_cooldown int, sea_level int, online_mode boolean, enforces_secure_chat boolean,
    -- world / player state
    difficulty int, difficulty_locked boolean,
    invulnerable boolean, flying boolean, can_fly boolean, instabuild boolean, fly_speed real, walk_speed real,
    held_slot int, op_level int,
    x float8, y float8, z float8, yaw real, pitch real, teleport_id int,
    motd text,
    border_center_x float8, border_center_z float8, border_size float8, border_max int, border_warn_blocks int, border_warn_time int,
    game_time bigint, clocks jsonb,                        -- clocks: [{"id":registry id,"ticks":..,"partial":..,"rate":..}, ...] in send order
    spawn_dimension text, spawn_x int, spawn_y int, spawn_z int, spawn_yaw real, spawn_pitch real,
    tick_rate real, tick_frozen boolean, chunk_x int, chunk_z int,
    health real, food int, saturation real, xp_progress real, xp_total int, xp_level int, inventory_slots int
);

create sequence if not exists net.entity_id_seq;

create table if not exists net.static_packet (
    seq             int primary key,
    ord             int not null,                -- position in the entry sequence (see net.play_entry_packets)
    packet          text not null,
    entity_prefixed boolean not null default false,   -- the captured body began with the player's entity id VarInt: stored without it, added back per player
    body            bytea not null,
    note            text
);

-- A plain world with a player in it.  gamemode: 0 survival, 1 creative, 2 adventure, 3 spectator.
create or replace function net.default_join_info(p_conn bigint, p_gamemode int default null) returns net.join_info language plpgsql stable as $$
declare j net.join_info; c net.conn; gm int;
begin
    select * into c from net.conn where conn_id = p_conn;
    gm := coalesce(p_gamemode, c.gamemode, case net.setting('gamemode') when 'creative' then 1 when 'adventure' then 2 when 'spectator' then 3 else 0 end);
    j.entity_id := coalesce(c.entity_id, nextval('net.entity_id_seq')::int);
    j.hardcore := false; j.levels := array['minecraft:overworld', 'minecraft:the_nether', 'minecraft:the_end'];
    j.max_players := net.setting('max_players')::int; j.view_distance := net.setting('view_distance')::int; j.simulation_distance := net.setting('simulation_distance')::int;
    j.reduced_debug := false; j.show_death_screen := true; j.limited_crafting := false;
    j.dimension_type := 'minecraft:overworld'; j.dimension := 'minecraft:overworld'; j.seed := 0; j.gamemode := gm; j.prev_gamemode := null;
    j.is_debug := false; j.is_flat := false; j.portal_cooldown := 0; j.sea_level := 63;
    j.online_mode := net.setting('online_mode') = 'true'; j.enforces_secure_chat := false;
    j.difficulty := 2; j.difficulty_locked := false;
    j.invulnerable := gm in (1, 3); j.flying := gm = 3; j.can_fly := gm in (1, 3); j.instabuild := gm = 1; j.fly_speed := 0.05; j.walk_speed := 0.1;
    j.held_slot := 0; j.op_level := 0;
    j.x := 0.5; j.y := 64; j.z := 0.5; j.yaw := 0; j.pitch := 0; j.teleport_id := 1;
    j.motd := net.setting('motd');
    j.border_center_x := 0; j.border_center_z := 0; j.border_size := 5.9999968e7; j.border_max := 29999984; j.border_warn_blocks := 5; j.border_warn_time := 300;
    j.game_time := 0; j.clocks := '[]'::jsonb;
    j.spawn_dimension := 'minecraft:overworld'; j.spawn_x := 0; j.spawn_y := 64; j.spawn_z := 0; j.spawn_yaw := 0; j.spawn_pitch := 0;
    j.tick_rate := 20; j.tick_frozen := false; j.chunk_x := 0; j.chunk_z := 0;
    j.health := 20; j.food := 20; j.saturation := 5; j.xp_progress := 0; j.xp_total := 0; j.xp_level := 0; j.inventory_slots := 46;
    return j;
end $$;

-- player_info_update: the full action set (add player, chat session, game mode, listed, latency, display name, list order, hat),
-- then each player's entry in that order.  An empty list is still sent (vanilla sends it to a player who joins an empty server).
create or replace function net.player_info_body(p_conns bigint[]) returns bytea language sql stable as $$
    select '\xff'::bytea || proto.varint(count(*)::int)
           || coalesce(string_agg(proto.uuid(c.uuid) || proto.string(c.name) || proto.varint(0) || proto.bool(false)
                                  || proto.varint(coalesce(c.gamemode, 0)) || proto.bool(true) || proto.varint(c.latency_ms)
                                  || proto.bool(false) || proto.varint(0) || proto.bool(false), ''::bytea order by c.conn_id), '\x'::bytea)
    from net.conn c where c.conn_id = any (p_conns) $$;

-- The ordered packets for one player.  ord is the position in the sequence; rows with the same ord do not occur.
create or replace function net.play_entry_packets(p_conn bigint, j net.join_info) returns table (ord int, packet text, body bytea) language plpgsql stable as $$
begin
    return query
    select v.ord, v.packet, v.body from (values
        (10,  'minecraft:login',
              proto.i32(j.entity_id) || proto.bool(j.hardcore) || proto.varint(cardinality(j.levels))
              || (select string_agg(proto.string(l), ''::bytea order by o) from unnest(j.levels) with ordinality t(l, o))
              || proto.varint(j.max_players) || proto.varint(j.view_distance) || proto.varint(j.simulation_distance)
              || proto.bool(j.reduced_debug) || proto.bool(j.show_death_screen) || proto.bool(j.limited_crafting)
              -- spawn info: dimension type holder (registry id), dimension, hashed seed, game mode, previous game mode, debug, flat, last death, portal cooldown, sea level
              || proto.varint(net.tag_member_id('minecraft:dimension_type', j.dimension_type)) || proto.string(j.dimension) || proto.i64(j.seed)
              || proto.varint(j.gamemode) || case when j.prev_gamemode is null then '\x00'::bytea else '\x01'::bytea || proto.varint(j.prev_gamemode) end
              || proto.bool(j.is_debug) || proto.bool(j.is_flat) || proto.bool(false) || proto.varint(j.portal_cooldown) || proto.varint(j.sea_level)
              || proto.bool(j.online_mode) || proto.bool(j.enforces_secure_chat)),
        (20,  'minecraft:change_difficulty', proto.i8(j.difficulty) || proto.bool(j.difficulty_locked)),
        (30,  'minecraft:player_abilities',
              proto.i8((case when j.invulnerable then 1 else 0 end) | (case when j.flying then 2 else 0 end) | (case when j.can_fly then 4 else 0 end) | (case when j.instabuild then 8 else 0 end))
              || proto.f32(j.fly_speed) || proto.f32(j.walk_speed)),
        (40,  'minecraft:set_held_slot', proto.varint(j.held_slot)),
        (60,  'minecraft:entity_event', proto.i32(j.entity_id) || proto.i8(24 + j.op_level)),    -- 24 + level: the player's permission level
        (80,  'minecraft:recipe_book_settings', '\x0000000000000000'::bytea),
        (100, 'minecraft:player_position',
              proto.varint(j.teleport_id) || proto.f64(j.x) || proto.f64(j.y) || proto.f64(j.z) || '\x000000000000000000000000000000000000000000000000'::bytea
              || proto.f32(j.yaw) || proto.f32(j.pitch) || proto.i32(0)),
        (110, 'minecraft:server_data', nbt.text_literal(j.motd) || proto.bool(false)),           -- no icon
        (140, 'minecraft:initialize_border',
              proto.f64(j.border_center_x) || proto.f64(j.border_center_z) || proto.f64(j.border_size) || proto.f64(j.border_size) || proto.varlong(0)
              || proto.varint(j.border_max) || proto.varint(j.border_warn_blocks) || proto.varint(j.border_warn_time)),
        (150, 'minecraft:set_time',
              proto.i64(j.game_time) || proto.varint(jsonb_array_length(j.clocks))
              || coalesce((select string_agg(proto.varint((cl ->> 'id')::int) || proto.varlong((cl ->> 'ticks')::bigint)
                                             || proto.f32((cl ->> 'partial')::real) || proto.f32((cl ->> 'rate')::real), ''::bytea order by o)
                           from jsonb_array_elements(j.clocks) with ordinality t(cl, o)), '\x'::bytea)),
        (160, 'minecraft:set_default_spawn_position',
              proto.string(j.spawn_dimension) || proto.position(j.spawn_x, j.spawn_y, j.spawn_z) || proto.f32(j.spawn_yaw) || proto.f32(j.spawn_pitch)),
        (170, 'minecraft:game_event', proto.i8(13) || proto.f32(0)),                              -- 13: level chunks load start
        (180, 'minecraft:ticking_state', proto.f32(j.tick_rate) || proto.bool(j.tick_frozen)),
        (190, 'minecraft:ticking_step', proto.varint(0)),
        (200, 'minecraft:set_chunk_cache_center', proto.varint(j.chunk_x) || proto.varint(j.chunk_z)),
        (210, 'minecraft:post_effects', proto.varint(0)),
        (220, 'minecraft:container_set_content',
              proto.varint(0) || proto.varint(1) || proto.varint(j.inventory_slots) || decode(repeat('00', j.inventory_slots), 'hex') || '\x00'::bytea),   -- every slot empty, nothing carried
        (260, 'minecraft:set_health', proto.f32(j.health) || proto.varint(j.food) || proto.f32(j.saturation)),
        (270, 'minecraft:set_experience', proto.f32(j.xp_progress) || proto.varint(j.xp_level) || proto.varint(j.xp_total))     -- level BEFORE total (found with /experience on the real server, docs/SURVIVAL.md; all zero in the recorded burst, so it was invisible)
    ) v(ord, packet, body)
    union all
    select s.ord, s.packet, case when s.entity_prefixed then proto.varint(j.entity_id) || s.body else s.body end from net.static_packet s
    order by 1;
end $$;
