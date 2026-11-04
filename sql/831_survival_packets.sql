-- Survival core, part 2: clientbound packet builders (whole frames) and death messages.
-- Layouts from the 26.3 classes (tools/pkt_layout.py) and recorded runs of the real server (tests/e2e/survival_probe.py):
--   set_health        = float health | VarInt food | float saturation
--   set_experience    = float progress | VarInt LEVEL | VarInt TOTAL   (the order is level first: seen with /experience on the real server; net.join_info wrote total first)
--   damage_event      = VarInt entity | VarInt damage type (registry id) | VarInt cause entity + 1 | VarInt direct entity + 1 | Optional<Vec3> source position
--   entity_event      = int entity | byte event   (3 death, 9 finished using an item, 60 death poof)
--   set_entity_data   = VarInt entity | { byte index | VarInt serializer | value }* | 0xff   (9 health: float; 8 living flags: byte; 18 score: VarInt)
--   player_combat_kill= VarInt player | component
--   respawn           = CommonPlayerSpawnInfo (as in `login`) | byte data kept
--   level_particles   = [particle: VarInt type, VarInt block state] | bool override limiter | bool always show | 3 doubles | 3 float spread | 3 float max speed | VarInt count | byte randomization

create or replace function mc.pkt_set_health(p_health real, p_food int, p_sat real) returns bytea language sql stable parallel safe as $$
  select mc.cb('set_health', proto.f32(p_health) || proto.varint(p_food) || proto.f32(p_sat)) $$;
create or replace function mc.pkt_set_experience(p_progress real, p_level int, p_total int) returns bytea language sql stable parallel safe as $$
  select mc.cb('set_experience', proto.f32(p_progress) || proto.varint(p_level) || proto.varint(p_total)) $$;
create or replace function mc.pkt_damage_event(p_eid int, p_type_id int, p_cause int default null, p_direct int default null) returns bytea language sql stable parallel safe as $$
  select mc.cb('damage_event', proto.varint(p_eid) || proto.varint(p_type_id) || proto.varint(coalesce(p_cause + 1, 0)) || proto.varint(coalesce(p_direct + 1, 0)) || proto.bool(false)) $$;
-- mc.pkt_entity_event(int, int) is defined in sql/813 (the commands use it too)
create or replace function mc.pkt_data_health(p_eid int, p_health real) returns bytea language sql stable parallel safe as $$
  select mc.cb('set_entity_data', proto.varint(p_eid) || '\x0903'::bytea || proto.f32(p_health) || '\xff'::bytea) $$;
create or replace function mc.pkt_data_using(p_eid int, p_using boolean) returns bytea language sql stable parallel safe as $$      -- living entity flags: bit 0 = using an item (main hand)
  select mc.cb('set_entity_data', proto.varint(p_eid) || '\x0800'::bytea || proto.i8(case when p_using then 1 else 0 end) || '\xff'::bytea) $$;
create or replace function mc.pkt_data_score(p_eid int, p_score int) returns bytea language sql stable parallel safe as $$
  select mc.cb('set_entity_data', proto.varint(p_eid) || '\x1201'::bytea || proto.varint(p_score) || '\xff'::bytea) $$;
create or replace function mc.pkt_combat_kill(p_eid int, p_component bytea) returns bytea language sql stable parallel safe as $$
  select mc.cb('player_combat_kill', proto.varint(p_eid) || p_component) $$;
-- block particles (the landing puff): particle type 1 = block, then the block state
create or replace function mc.pkt_particles_block(x float8, y float8, z float8, p_state int, p_count int) returns bytea language sql stable parallel safe as $$
  select mc.cb('level_particles', proto.varint(1) || proto.varint(p_state) || proto.bool(false) || proto.bool(false) || proto.f64(x) || proto.f64(y) || proto.f64(z)
       || proto.f32(0) || proto.f32(0) || proto.f32(0) || proto.f32(0.15::real) || proto.f32(0.15::real) || proto.f32(0.15::real) || proto.varint(p_count) || '\x00'::bytea) $$;

-- the respawn packet for a player (after a death): spawn info like `login`'s, the last death location, nothing kept
create or replace function mc.pkt_respawn(p_gamemode int, p_seed bigint, p_death_x int, p_death_y int, p_death_z int) returns bytea language sql stable as $$
  select mc.cb('respawn', proto.varint(net.tag_member_id('minecraft:dimension_type', 'minecraft:overworld')) || proto.string('minecraft:overworld') || proto.i64(p_seed)
       || proto.varint(p_gamemode) || '\x00'::bytea || proto.bool(false) || proto.bool(true)
       || case when p_death_x is null then '\x00'::bytea else '\x01'::bytea || proto.string('minecraft:overworld') || proto.position(p_death_x, p_death_y, p_death_z) end
       || proto.varint(0) || proto.varint(-63) || '\x00'::bytea) $$;

-- Death message component (CombatTracker.getDeathMessage): the last damage's type decides.  `p_cb_fall` is the largest fall distance of the combat window:
-- a fall that kills after more than 5 blocks reads "fell from a high place" (death.fell.accident.generic), a shorter one "hit the ground too hard" (death.attack.fall).
-- Messages that name an attacker (mob and player damage) need entities that damage players, which this server does not have.
create or replace function mc.death_message(p_uuid uuid, p_name text, p_type text, p_cb_fall real default 0) returns bytea language sql stable as $$
  select mc.tc_translate(
           case when p_type is null then 'death.attack.generic'
                when dt.death_message_type = 'fall_variants' and p_cb_fall > 5 then 'death.fell.accident.generic'
                else 'death.attack.' || coalesce(dt.message_id, 'generic') end,
           array[mc.tc_player(p_uuid, p_name)])
    from (select 1) one left join mc.damage_type dt on dt.name = 'minecraft:' || p_type $$;
