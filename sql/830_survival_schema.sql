-- Survival core for players, part 1: state, rules and reference helpers.  docs/SURVIVAL.md has the whole picture.
--
-- Everything the survival rules need per player is a column of mc.player (health, food, saturation already were): exhaustion, the food tick timer, fall distance,
-- the damage cooldown, the death state, experience, and "what the client was last told" (the same pattern as the movement bookkeeping: one comparison per tick finds the
-- players whose packets are due).  Rules and constants were read from the 26.3 bytecode (FoodData, FoodConstants, Entity/LivingEntity/Player/ServerPlayer.hurtServer,
-- checkFallDamage, die, CombatTracker, ...) and checked against recorded runs of the real server (tests/e2e/survival_probe.py, docs/SURVIVAL.md).

alter table mc.player
    add column if not exists exhaustion    real   not null default 0,        -- FoodData.exhaustionLevel (capped at 40 by addExhaustion)
    add column if not exists food_timer    int    not null default 0,        -- FoodData.tickTimer
    add column if not exists fall_distance float8 not null default 0,        -- Entity.fallDistance
    add column if not exists fall_tp       int    not null default 0,        -- teleport_id the fall state belongs to (a teleport resets the fall distance)
    add column if not exists hurt_tick     bigint,                           -- tick of the last full hit: damage cooldown (LivingEntity.damageCooldownTime) is 20 - (tick - hurt_tick)
    add column if not exists last_hurt     real   not null default 0,        -- LivingEntity.lastHurt
    add column if not exists dead          boolean not null default false,
    add column if not exists death_tick    bigint,
    add column if not exists death_x       float8, add column if not exists death_y float8, add column if not exists death_z float8,
    add column if not exists xp_progress   real   not null default 0,        -- Player.experienceProgress
    add column if not exists xp_total      int    not null default 0,        -- Player.totalExperience
    add column if not exists xp_score      int    not null default 0,        -- Player score (entity data 18, grows with experience points)
    add column if not exists sprinting     boolean not null default false,   -- player_command start/stop sprinting
    add column if not exists join_tick     bigint,                           -- the tick the session started (vanilla's tickCount phase for peaceful regeneration)
    add column if not exists use_slot      smallint,                         -- inventory slot (menu numbering) of the item being used (eaten), null = none
    add column if not exists use_until     bigint,                           -- tick at which the use completes
    add column if not exists cb_tick       bigint,                           -- CombatTracker: tick of the last recorded damage ...
    add column if not exists cb_fall       real   not null default 0,        -- ... the largest fall distance among the entries of the current window ...
    add column if not exists cb_type       text,                             -- ... and the damage type of the last entry
    -- what the client was last told (null = "the join burst carried the current values", set by the trigger below)
    add column if not exists sent_health   real,   add column if not exists sent_food int,   add column if not exists sent_sat_zero boolean,
    add column if not exists sent_xp_total int,    add column if not exists sent_eh   real,  add column if not exists sent_score int,
    add column if not exists sent_using    boolean,
    add column if not exists pend_slot     smallint;                          -- slot to re-send one tick after an item was used up

-- game rules (mc.game_rule keeps vanilla's names, "minecraft:keep_inventory" ...; the table is empty until a rule is set, defaults are vanilla's)
create or replace function mc.rule_bool(p_name text, p_default boolean) returns boolean language sql stable as $$
  select coalesce((select value from mc.game_rule where name = 'minecraft:' || p_name)::boolean, p_default) $$;

-- the world's difficulty (0 peaceful .. 3 hard) from server.properties
create or replace function mc.difficulty() returns int language sql stable as $$
  select case mc.prop('difficulty') when 'peaceful' then 0 when 'easy' then 1 when 'hard' then 3 else 2 end $$;

-- damage types: id (position in the registry the configuration phase sends), message id, scaling, exhaustion, death message type, effects: read from the datapack
-- entries (ref.dp_node), the same rows the client's registry packet is built from.  Tags (bypasses_invulnerability, ...) from ref.dp_tag_member.  Only the cold paths use
-- these views (a damage event), never the per-tick scans.
create or replace view mc.damage_type as
select e.seq as id, e.name,
       max(n.s) filter (where n.key = 'message_id')          as message_id,
       max(n.s) filter (where n.key = 'scaling')             as scaling,
       coalesce(max(n.f) filter (where n.key = 'exhaustion'), 0)::real as exhaustion,
       max(n.s) filter (where n.key = 'death_message_type')  as death_message_type
  from ref.dp_entry e join ref.dp_node n on n.registry = e.registry and n.entry = e.name
 where e.registry = 'minecraft:damage_type' group by e.seq, e.name;

create or replace function mc.damage_tag(p_tag text, p_type text) returns boolean language sql stable as $$
  select exists (select 1 from ref.dp_tag_member where registry = 'minecraft:damage_type' and tag = 'minecraft:' || p_tag and member = 'minecraft:' || p_type) $$;

-- a joining session starts with clean survival bookkeeping: the join burst carries the current health/food/experience, so those count as sent; a player who left dead
-- comes back alive at the world spawn (vanilla keeps the death screen state: not reproduced).  The WHEN clause is evaluated in C, the function runs once per join.
create or replace function mc.survival_on_join() returns trigger language plpgsql as $$
begin
  if new.dead or new.health <= 0 then
    new.dead := false; new.health := 20; new.food := 20; new.saturation := 5; new.exhaustion := 0;
    select spawn_x, spawn_y, spawn_z into new.x, new.y, new.z from mc.game_state;
    new.chunk_x := floor(new.x / 16)::int; new.chunk_z := floor(new.z / 16)::int;
  end if;
  new.sent_health := new.health; new.sent_food := new.food; new.sent_sat_zero := new.saturation = 0; new.sent_eh := new.health;
  new.sent_xp_total := new.xp_total; new.sent_score := new.xp_score; new.sent_using := false;
  new.fall_distance := 0; new.fall_tp := 0; new.food_timer := 0; new.hurt_tick := null; new.last_hurt := 0; new.sprinting := false;
  new.use_slot := null; new.use_until := null; new.cb_tick := null; new.cb_fall := 0; new.cb_type := null;
  new.join_tick := (select game_time from mc.game_state);
  return new;
end $$;
drop trigger if exists survival_on_join on mc.player;
create trigger survival_on_join before update on mc.player for each row when (old.conn_id is null and new.conn_id is not null) execute function mc.survival_on_join();
