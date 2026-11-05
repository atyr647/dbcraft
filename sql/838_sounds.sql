-- Sounds: what the server tells the players to hear.  The `sound` packet (ClientboundSoundPacket, play id 119 in 26.3) is
--   Holder<SoundEvent> = VarInt (registry id + 1) | VarInt SoundSource | int x*8 | int y*8 | int z*8 | float volume | float pitch | long seed
-- Layout and every value below were recorded from the real 26.3 server (tests/e2e/sound_probe.py and the survival scenarios, compared by tests/e2e/compare_sound.py).
-- The seed is random in vanilla (RandomSource.nextLong) and so is the pitch of several sounds; everything else is deterministic.
--
-- Who hears a sound: ServerLevel.playSeededSound -> PlayerList.broadcast(except, x, y, z, range, dimension): every player of the dimension except `except` whose squared
-- distance to the sound is STRICTLY less than range squared; the range of a sound is 16 blocks, or 16 x volume above volume 1 (SoundEvent.getRange).  A player's own actions
-- are played by its own client (prediction), so `except` is the player: placing a block, being hurt, falling, eating's per-tick sounds, dying go to everybody else.
-- What the server sends (recorded):
--   a block placed          to the others: the block's SoundType place sound, BLOCKS, at the block's centre, volume (v + 1) / 2, pitch p * 0.8   (before the swing animations)
--   a fall that hurts       to the others: entity.player.big_fall (damage > 4) or small_fall, PLAYERS, volume 1, pitch 1; then the SoundType fall sound of the block under the
--                           feet at volume * 0.5 and pitch * 0.75 (LivingEntity.causeFallDamage + playBlockFallSound), both before the damage event
--   a hit                   to the others, right after the damage event: entity.player.hurt (the type's own sound for burning, drowning, freezing, sweet berries), volume 1, pitch 1;
--                           a hit that kills sends entity.player.death instead
--   eating                  to the others, every 4 ticks from 24 ticks before the end down to the last tick (LivingEntity.updateUsingItem: remaining <= 25 and remaining % 4 == 0,
--                           7 sounds for an apple): entity.generic.eat, PLAYERS, volume 0.5 or 1.0 (random), pitch (r - r) * 0.2 + 1; and when the item is finished to everybody
--                           (the eater too): entity.generic.eat NEUTRAL volume 1 pitch 1 + (r - r) * 0.4, then entity.player.burp PLAYERS volume 0.5 pitch r * 0.1 + 0.9
--   a chest, ender chest, barrel opened by the first player / closed by the last   to everybody within range (the opener too), before the menu is sent: block.chest.open,
--                           .close (ender chest and barrel have their own), BLOCKS, at the centre of the block (a double chest: of the pair; a barrel: moved half a block along its
--                           facing), volume 0.5, pitch r * 0.1 + 0.9

create table if not exists mc.sound_type (
    id         int primary key,
    volume     real not null,
    pitch      real not null,
    break_snd  text not null,
    step_snd   text not null,
    place_snd  text not null,
    hit_snd    text not null,
    fall_snd   text not null);
create table if not exists mc.block_sound   (block text primary key, type int not null references mc.sound_type);      -- the default state's sound type, from the jar (tools/gen_sounds.sh, tools/load_sounds.py)
create table if not exists mc.block_sound_x (state_id int primary key, type int not null references mc.sound_type);    -- the states that differ from their block's default

create or replace function mc.sound_id(p_name text) returns int language sql stable parallel safe as $$
  select protocol_id from ref.registry where registry = 'minecraft:sound_event' and name = 'minecraft:' || p_name $$;

create or replace function mc.sound_seed() returns bigint language sql volatile parallel safe as $$
  select ((floor(random() * 4294967296)::bigint - 2147483648) << 32) | floor(random() * 4294967296)::bigint $$;

-- the whole frame
create or replace function mc.pkt_sound(p_name text, p_source int, x float8, y float8, z float8, p_vol float8, p_pitch float8, p_seed bigint default null) returns bytea language sql volatile as $$
  select mc.cb('sound', proto.varint(mc.sound_id(p_name) + 1) || proto.varint(p_source) || proto.i32(trunc(x * 8)::int) || proto.i32(trunc(y * 8)::int) || proto.i32(trunc(z * 8)::int)
                        || proto.f32(p_vol::real) || proto.f32(p_pitch::real) || proto.i64(coalesce(p_seed, mc.sound_seed()))) $$;

-- PlayerList.broadcast: to every online player but `p_except_conn` whose squared distance is less than range squared (the overworld: players have no dimension column)
create or replace function mc.sound_near(p_except_conn int, p_name text, p_source int, sx float8, sy float8, sz float8, p_vol float8, p_pitch float8) returns void language sql as $$
  insert into mc.play_out (conn_id, data)
  select p.conn_id, f.pkt
    from (select mc.pkt_sound(p_name, p_source, sx, sy, sz, p_vol, p_pitch) as pkt) f, mc.player p
   where p.conn_id is not null and p.conn_id is distinct from p_except_conn
     and (sx - p.x) ^ 2 + (sy - p.y) ^ 2 + (sz - p.z) ^ 2 < (case when p_vol > 1 then 16 * p_vol else 16 end) ^ 2
   order by p.entity_id $$;

create or replace function mc.block_sound_type(p_blk text) returns mc.sound_type language sql stable as $$
  select t.* from mc.sound_type t join mc.block_sound b on b.type = t.id where b.block = split_part(p_blk, '[', 1) $$;

-- a block placed by a player: the others hear it
create or replace function mc.snd_place(p_except_conn int, tx int, ty int, tz int, p_blk text) returns void language plpgsql as $$
declare t mc.sound_type;
begin
  t := mc.block_sound_type(p_blk);
  if t.id is null then return; end if;
  perform mc.sound_near(p_except_conn, t.place_snd, 4, tx + 0.5, ty + 0.5, tz + 0.5, (t.volume + 1) / 2, t.pitch * 0.8);
end $$;

-- fall damage (before the damage event): p_eids and their damage, one sound pair per player
create or replace function mc.snd_fall(p_eids int[], p_dmg real[]) returns void language plpgsql as $$
declare r record; t mc.sound_type;
begin
  for r in select p.conn_id, p.x, p.y, p.z, d.dmg from unnest(p_eids, p_dmg) as d(eid, dmg) join mc.player p on p.entity_id = d.eid where d.dmg > 0 order by d.eid loop
    perform mc.sound_near(r.conn_id, case when r.dmg > 4 then 'entity.player.big_fall' else 'entity.player.small_fall' end, 7, r.x, r.y, r.z, 1, 1);
    t := mc.block_sound_type(mc.get_block('minecraft:overworld', floor(r.x)::int, floor(r.y - 0.2)::int, floor(r.z)::int));
    if t.id is not null and mc.get_block('minecraft:overworld', floor(r.x)::int, floor(r.y - 0.2)::int, floor(r.z)::int) not in ('minecraft:air', 'minecraft:void_air', 'minecraft:cave_air') then
      perform mc.sound_near(r.conn_id, t.fall_snd, 7, r.x, r.y, r.z, t.volume * 0.5, t.pitch * 0.75);
    end if;
  end loop;
end $$;

-- a full hit (after the damage event): the hurt sound, or the death sound for those who died
create or replace function mc.snd_hurt(p_hit int[], p_dead int[], p_type text) returns void language plpgsql as $$
declare r record; nm text;
begin
  for r in select p.entity_id as eid, p.conn_id, p.x, p.y, p.z from unnest(p_hit) as h(eid) join mc.player p on p.entity_id = h.eid order by h.eid loop
    nm := case when r.eid = any (p_dead) then 'entity.player.death'
               when p_type in ('on_fire', 'in_fire', 'lava', 'hot_floor', 'campfire') then 'entity.player.hurt_on_fire'
               when p_type = 'drown' then 'entity.player.hurt_drown'
               when p_type = 'freeze' then 'entity.player.hurt_freeze'
               when p_type = 'sweet_berry_bush' then 'entity.player.hurt_sweet_berry_bush'
               else 'entity.player.hurt' end;
    perform mc.sound_near(r.conn_id, nm, 7, r.x, r.y, r.z, 1, 1);
  end loop;
end $$;

-- using an item (every tick of the use phase): the eating sound for the others, 7 times for an apple
create or replace function mc.snd_use_tick(p_cur bigint, p_ids int[]) returns void language plpgsql as $$
declare r record;
begin
  for r in select p.conn_id, p.x, p.y, p.z, p.use_slot, p.uuid from mc.player p
            where p.use_slot is not null and p.conn_id is not null and not p.dead and p.use_until - p_cur between 0 and 24 and (p.use_until - p_cur) % 4 = 0
              and (p_ids is null or p.entity_id = any (p_ids)) order by p.entity_id loop
    perform mc.sound_near(r.conn_id, case when (select i.item from mc.inventory_slot i where i.player = r.uuid and i.slot = r.use_slot) = 'minecraft:honey_bottle' then 'item.honey_bottle.drink' else 'entity.generic.eat' end,
                          7, r.x, r.y, r.z, (0.5 + 0.5 * floor(random() * 2))::real, ((random() - random()) * 0.2 + 1)::real);
  end loop;
end $$;

-- an item finished (to everybody within range, the eater too): the eating sound, then the burp
create or replace function mc.snd_eaten(p_eids int[], p_items text[]) returns void language plpgsql as $$
declare r record;
begin
  for r in select p.x, p.y, p.z, d.item from unnest(p_eids, p_items) as d(eid, item) join mc.player p on p.entity_id = d.eid order by d.eid loop
    perform mc.sound_near(null, case when r.item = 'minecraft:honey_bottle' then 'item.honey_bottle.drink' else 'entity.generic.eat' end, 6, r.x, r.y, r.z, 1, (1 + (random() - random()) * 0.4)::real);
    perform mc.sound_near(null, 'entity.player.burp', 7, r.x, r.y, r.z, 0.5, (random() * 0.1 + 0.9)::real);
  end loop;
end $$;

-- a chest, trapped chest, ender chest or barrel opened (p_open) or closed: the sound of the lid at the middle of the block, or of the pair of a double chest
create or replace function mc.snd_container(p_blk text, bx int, bby int, bz int, x2 int, y2 int, z2 int, p_open boolean, p_state text default null) returns void language plpgsql as $$
declare nm text; cx float8 := bx + 0.5; cy float8 := bby + 0.5; cz float8 := bz + 0.5; f text;
begin
  nm := case split_part(p_blk, '[', 1) when 'minecraft:ender_chest' then 'block.ender_chest.' when 'minecraft:barrel' then 'block.barrel.' else 'block.chest.' end || case when p_open then 'open' else 'close' end;
  if x2 is not null then cx := (bx + x2) / 2.0 + 0.5; cy := (bby + y2) / 2.0 + 0.5; cz := (bz + z2) / 2.0 + 0.5; end if;
  if split_part(p_blk, '[', 1) = 'minecraft:barrel' then      -- BarrelBlockEntity.playSound: moved half a block along the facing
    f := substring(coalesce(p_state, '') from 'facing=(\w+)');
    cx := cx + case f when 'east' then 0.5 when 'west' then -0.5 else 0 end; cy := cy + case f when 'up' then 0.5 when 'down' then -0.5 else 0 end; cz := cz + case f when 'south' then 0.5 when 'north' then -0.5 else 0 end;
  end if;
  perform mc.sound_near(null, nm, 4, cx, cy, cz, 0.5, (random() * 0.1 + 0.9)::real);
end $$;
