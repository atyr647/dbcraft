-- Entity behaviour (prototype): spawning, wander and chase goals, a table-driven spawner, despawning, item pickup.  All set-based, all opt-in (mc.entity_tick calls them).
-- FAKED relative to vanilla (docs/ENTITY.md): mobs follow a straight-line goal (no pathfinding, no step-up, no jumping, no water), goals change on a timer, the spawner
-- places mobs at the player's height (flat worlds), chase is greedy toward the nearest player within 16 blocks, pickup is checked every 4th tick per player.

alter table mc.entity add column if not exists sent_cx int;
alter table mc.entity add column if not exists sent_cz int;
create index if not exists entity_goal_idx on mc.entity (goal_until) where goal_until > 0;                  -- mobs whose goal expired
create index if not exists entity_new_idx on mc.entity (id) where last_sent_tick = 0;                      -- not yet announced to viewers
create index if not exists entity_zombie_idx on mc.entity (id) where type = 'minecraft:zombie';             -- chasers

create or replace function mc.entity_spawn(p_type text, x float8, y float8, z float8, vx float8 default 0, vy float8 default 0, vz float8 default 0,
                                           p_tick bigint default null, p_data jsonb default '{}', p_pickup_delay int default 10, p_yaw real default 0) returns int language plpgsql as $$
declare t bigint := coalesce(p_tick, (select game_time from mc.game_state limit 1), 0); eid int := nextval('mc.entity_id_seq')::int;
begin
    insert into mc.entity (id, uuid, type, type_id, x, y, z, vx, vy, vz, yaw, born_tick, pickup_at, phys_tick, cx, cz, data)
    values (eid, gen_random_uuid(), p_type, mc.entity_type_id(p_type), x, y, z, vx, vy, vz, p_yaw, t, t + p_pickup_delay, t, floor(x / 16)::int, floor(z / 16)::int, p_data);
    return eid;
end $$;

-- spawn a dropped item stack
create or replace function mc.entity_drop_item(p_item text, p_count int, x float8, y float8, z float8, vx float8 default 0, vy float8 default 0.2, vz float8 default 0, p_tick bigint default null) returns int
language sql as $$ select mc.entity_spawn('minecraft:item', x, y, z, vx, vy, vz, p_tick, jsonb_build_object('item', p_item, 'count', p_count), 10) $$;

-- Goals.  Pseudo-random numbers come from a hash of (entity id, tick): deterministic, no random() calls (which would be volatile in every row).
create or replace function mc.entity_ai(p_tick bigint) returns int language plpgsql volatile as $$
declare n int := 0; k int;
begin
    -- wander: mobs whose goal ran out pick a new one: walk in a random direction (60%) or stand still
    update mc.entity e set gx = g.gx, gz = g.gz, goal_until = p_tick + g.dur, yaw = g.yaw, deep_sleep = false,
                           phys_tick = case when e.deep_sleep then p_tick - 1 else e.phys_tick end
      from (select q.id, case when q.r1 < 0.6 then -sin(radians(q.r2 * 360)) * q.speed else 0 end as gx, case when q.r1 < 0.6 then cos(radians(q.r2 * 360)) * q.speed else 0 end as gz,
                   case when q.r1 < 0.6 then 20 + floor(q.r4 * 60)::int else 40 + floor(q.r4 * 100)::int end as dur,
                   case when q.r1 < 0.6 then (q.r2 * 360)::real else q.yaw end as yaw
              from (select e2.id, e2.yaw, p.walk_speed * (0.6 + 0.4 * h.r3) as speed, h.r1, h.r2, h.r4
                      from mc.entity e2 join mc.entity_type_param p on p.type = e2.type
                      cross join lateral (select abs(hashtextextended(e2.id::text || ':' || p_tick::text, 0)) as hv) hh
                      cross join lateral (select (hh.hv % 1000) / 1000.0 as r1, ((hh.hv / 1000) % 1000) / 1000.0 as r2, ((hh.hv / 1000000) % 1000) / 1000.0 as r3, ((hh.hv / 1000000000) % 1000) / 1000.0 as r4) h
                     where p.kind = 'mob' and e2.goal_until > 0 and e2.goal_until <= p_tick) q) g
     where e.id = g.id;
    get diagnostics k = row_count; n := n + k;

    -- chase: every 5th tick (by id) a zombie looks for the nearest player within 16 blocks and walks straight at them
    update mc.entity e set gx = c.gx, gz = c.gz, goal_until = p_tick + 5, yaw = c.yaw, deep_sleep = false, phys_tick = case when e.deep_sleep then p_tick - 1 else e.phys_tick end
      from (select distinct on (z.id) z.id, (p.walk_speed * (pl.px - z.x) / sqrt((pl.px - z.x) ^ 2 + (pl.pz - z.z) ^ 2)) as gx, (p.walk_speed * (pl.pz - z.z) / sqrt((pl.px - z.x) ^ 2 + (pl.pz - z.z) ^ 2)) as gz,
                   degrees(atan2(-(pl.px - z.x), (pl.pz - z.z)))::real as yaw
              from mc.entity z join mc.entity_type_param p on p.type = z.type and p.can_chase
              cross join lateral generate_series(-1, 1) dx cross join lateral generate_series(-1, 1) dz
              join (select pp.x as px, pp.z as pz, pp.chunk_x as pcx, pp.chunk_z as pcz from mc.player pp where pp.conn_id is not null) pl on pl.pcx = z.cx + dx and pl.pcz = z.cz + dz
             where z.type = 'minecraft:zombie' and (z.id + p_tick) % 5 = 0
               and (pl.px - z.x) ^ 2 + (pl.pz - z.z) ^ 2 between 0.25 and 256
             order by z.id, (pl.px - z.x) ^ 2 + (pl.pz - z.z) ^ 2) c
     where e.id = c.id;
    get diagnostics k = row_count; n := n + k;
    return n;
end $$;

-- Remove entities, telling the players who can see them.
create or replace function mc.entity_discard(p_ids int[]) returns int language plpgsql volatile as $$
declare n int;
begin
    insert into mc.play_out (conn_id, data)
    select v.conn_id, mc.pkt_remove_entities(array_agg(e.id order by e.id))
      from mc.entity e join mc.entity_type_param p on p.type = e.type
      join mc.entity_cell_viewer v on v.cx = e.cx and v.cz = e.cz
      join mc.entity_viewer_cell vc on vc.conn_id = v.conn_id and greatest(abs(vc.cx - e.cx), abs(vc.cz - e.cz)) <= p.tracking_chunks
     where e.id = any(p_ids) and e.last_sent_tick > 0
     group by v.conn_id order by v.conn_id;
    delete from mc.entity where id = any(p_ids);
    get diagnostics n = row_count;
    return n;
end $$;

-- Despawn (every 20th tick): items older than max_age, anything that fell out of the world, mobs outside every player's view for 30 s.
create or replace function mc.entity_despawn(p_tick bigint) returns int language plpgsql volatile as $$
declare ids int[];
begin
    if p_tick % 20 <> 0 then return 0; end if;
    select array_agg(e.id) into ids
      from mc.entity e join mc.entity_type_param p on p.type = e.type
     where (p.max_age is not null and p_tick - e.born_tick >= p.max_age)
        or e.y < -128
        or (p.kind = 'mob' and p_tick - e.born_tick > 600 and not exists (select 1 from mc.entity_cell_viewer v where v.cx = e.cx and v.cz = e.cz));
    if ids is null then return 0; end if;
    return mc.entity_discard(ids);
end $$;

-- A stack of this item can hold at most this many (APPROXIMATION: 64 for everything but the common single-stack and 16-stack items)
create or replace function mc.item_max_stack(p_item text) returns int language sql immutable parallel safe as $$
  select case when p_item ~ '(_sword|_pickaxe|_axe|_shovel|_hoe|_helmet|_chestplate|_leggings|_boots|_bow|bucket|_boat|shield|elytra|minecart)$' then 1
              when p_item ~ '(ender_pearl|snowball|egg|sign|banner|honey_bottle)$' then 16 else 64 end $$;

-- Add `count` of an item to a player's inventory: fill matching stacks, then the first empty hotbar slot (36-44), then main inventory (9-35).  Returns what did not fit.
create or replace function mc.inv_add(p_player uuid, p_item text, p_count int) returns int language plpgsql volatile as $$
declare left_ int := p_count; mx int := mc.item_max_stack(p_item); s record; put int;
begin
    for s in select slot, count from mc.inventory_slot where player = p_player and item = p_item and components is null and count < mx order by case when slot between 36 and 44 then slot - 36 else slot end loop
        exit when left_ = 0;
        put := least(left_, mx - s.count);
        update mc.inventory_slot set count = count + put where player = p_player and slot = s.slot; left_ := left_ - put;
    end loop;
    while left_ > 0 loop
        select g into s from (select g from generate_series(36, 44) g union all select g from generate_series(9, 35) g) x(g)
         where not exists (select 1 from mc.inventory_slot i where i.player = p_player and i.slot = x.g) order by case when g >= 36 then g - 36 else g + 100 end limit 1;
        exit when s is null;
        put := least(left_, mx);
        insert into mc.inventory_slot (player, slot, item, count) values (p_player, (s.g)::smallint, p_item, put); left_ := left_ - put;
    end loop;
    return left_;
end $$;

-- Pickup: every 4th tick per player, items whose pickup delay is over and that intersect the player's box grown by (1, 0.5, 1) go into the inventory.
-- The collector sees take_item_entity, its slot update and remove_entities; other viewers see take_item_entity + remove_entities.
create or replace function mc.entity_pickup(p_tick bigint) returns int language plpgsql volatile as $$
declare r record; rest int; taken int; ids int[] := '{}'; peids int[] := '{}'; cnts int[] := '{}'; st int;
begin
    for r in
        select distinct on (e.id) e.id as eid, e.data, pl.uuid, pl.entity_id as peid, pl.conn_id
          from mc.player pl
          cross join lateral generate_series(-1, 1) dx cross join lateral generate_series(-1, 1) dz
          join mc.entity e on e.cx = pl.chunk_x + dx and e.cz = pl.chunk_z + dz
         where pl.conn_id is not null and (pl.entity_id + p_tick) % 4 = 0
           and e.type = 'minecraft:item' and e.pickup_at <= p_tick and pl.gamemode <> 3
           and abs(e.x - pl.x) <= 0.3 + 1.0 + 0.125 and abs(e.z - pl.z) <= 0.3 + 1.0 + 0.125 and e.y + 0.25 >= pl.y - 0.5 and e.y <= pl.y + 1.8 + 0.5
         order by e.id, pl.entity_id
    loop
        rest := mc.inv_add(r.uuid, r.data ->> 'item', (r.data ->> 'count')::int);
        taken := (r.data ->> 'count')::int - rest;
        continue when taken <= 0;
        update mc.player set inv_state = inv_state + 1 where uuid = r.uuid returning inv_state into st;
        insert into mc.play_out (conn_id, data)
        select r.conn_id, mc.cb('take_item_entity', proto.varint(r.eid) || proto.varint(r.peid) || proto.varint(taken))
               || (select string_agg(mc.pkt_container_set_slot(st, i.slot, i.item, i.count), '\x'::bytea order by i.slot) from mc.inventory_slot i where i.player = r.uuid and i.item = r.data ->> 'item');
        if rest = 0 then ids := ids || r.eid; peids := peids || r.peid; cnts := cnts || taken;
        else update mc.entity set data = jsonb_set(data, '{count}', to_jsonb(rest)) where id = r.eid; end if;
    end loop;
    if cardinality(ids) > 0 then
        -- the other viewers of the item see it fly to the collector
        insert into mc.play_out (conn_id, data)
        select v.conn_id, string_agg(mc.cb('take_item_entity', proto.varint(u.eid) || proto.varint(u.peid) || proto.varint(u.cnt)), '\x'::bytea order by u.eid)
          from unnest(ids, peids, cnts) u(eid, peid, cnt) join mc.entity e on e.id = u.eid
          join mc.entity_cell_viewer v on v.cx = e.cx and v.cz = e.cz
          join mc.entity_viewer_cell vc on vc.conn_id = v.conn_id and greatest(abs(vc.cx - e.cx), abs(vc.cz - e.cz)) <= 6
         where e.last_sent_tick > 0 and v.conn_id not in (select pl.conn_id from mc.player pl where pl.entity_id = u.peid)
         group by v.conn_id order by v.conn_id;
        perform mc.entity_discard(ids);
    end if;
    return cardinality(ids);
end $$;

-- The spawner (every 40th tick by player entity id): a player with fewer than 8 mobs within 3 chunks gets one new mob 16-32 blocks away (APPROXIMATION: at the player's height).
create or replace function mc.entity_spawner(p_tick bigint) returns int language plpgsql volatile as $$
declare n int;
begin
    insert into mc.entity (id, uuid, type, type_id, x, y, z, yaw, born_tick, phys_tick, cx, cz, goal_until)
    select nextval('mc.entity_id_seq')::int, gen_random_uuid(), s.tp, mc.entity_type_id(s.tp), s.sx, s.y, s.sz, 0, p_tick, p_tick - 1, floor(s.sx / 16)::int, floor(s.sz / 16)::int, p_tick
      from (select pl.y, pl.x + (16 + (h.hv % 17)) * case when (h.hv / 17) % 2 = 0 then 1 else -1 end as sx, pl.z + (16 + ((h.hv / 100) % 17)) * case when (h.hv / 1700) % 2 = 0 then 1 else -1 end as sz,
                   case when (h.hv / 17000) % 10 < 7 then 'minecraft:cow' else 'minecraft:zombie' end as tp, pl.chunk_x as pcx, pl.chunk_z as pcz
              from mc.player pl cross join lateral (select abs(hashtextextended(pl.entity_id::text || ':' || p_tick::text, 1)) as hv) h
             where pl.conn_id is not null and (pl.entity_id + p_tick) % 40 = 0) s
     where (select count(*) from mc.entity m join mc.entity_type_param p on p.type = m.type and p.kind = 'mob' where m.cx between s.pcx - 3 and s.pcx + 3 and m.cz between s.pcz - 3 and s.pcz + 3) < 8;
    get diagnostics n = row_count;
    return n;
end $$;
