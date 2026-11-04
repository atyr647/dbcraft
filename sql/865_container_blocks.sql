-- Containers, crafting and recipes, part 6: what a block change does to the container that was there.
--
-- Every block change anybody makes (a player breaking it, mc.set_block, mc.fill, the fluid and block-tick code of other tracks) is a row in mc.block_event; a statement
-- trigger on that table sees them all:
--   * a container block replaced by a DIFFERENT block (a state change such as lit=true, facing, waterlogging, the two halves of a chest joining, is not a removal):
--     the contents fall out as item entities (Containers.dropContents; with the entity simulation off they are gone, like the death drops) and the rows, the furnace
--     state and the block entity row disappear; an open menu on it closes on the next tick (mc.menu_still_valid)
--   * a fill (kind 'cells') over a container removes its contents without dropping them (vanilla's /fill replace and /setblock replace do the same)
--   * a container block that appears gets its block entity row, so the chunk packets of later joiners carry it (an empty update tag)

create or replace function mc.container_block_names() returns text[] language sql immutable parallel safe as $$
    select array['minecraft:chest', 'minecraft:trapped_chest', 'minecraft:ender_chest', 'minecraft:barrel', 'minecraft:furnace', 'minecraft:blast_furnace', 'minecraft:smoker'] $$;

-- take everything out of the container at a position; p_drop: let it fall as items
create or replace function mc.container_purge(p_dim text, px int, py int, pz int, p_drop boolean) returns void language plpgsql as $$
declare c record;
begin
  if p_drop and mc.entity_mode() = 'inline' then
    for c in select item, count, components from mc.container_slot s where s.dimension = p_dim and s.x = px and s.y = py and s.z = pz order by s.slot loop
      perform mc.entity_spawn('minecraft:item', px + 0.5 + (random() - 0.5) * 0.5, py + 0.5 + (random() - 0.5) * 0.5, pz + 0.5 + (random() - 0.5) * 0.5,
                              (random() - 0.5) * 0.2, 0.2, (random() - 0.5) * 0.2, null,
                              jsonb_build_object('item', c.item, 'count', c.count) || coalesce(c.components, '{}'::jsonb), 10);
    end loop;
  end if;
  delete from mc.container_slot s where s.dimension = p_dim and s.x = px and s.y = py and s.z = pz;
  delete from mc.furnace f where f.dimension = p_dim and f.x = px and f.y = py and f.z = pz;
end $$;

create or replace function mc.container_on_block_event() returns trigger language plpgsql as $$
declare r record; names text[] := mc.container_block_names();
begin
  -- single positions
  for r in select n.dimension, n.x, n.y, n.z, n.old_state, n.new_state from nr n
            where n.kind = 'block' and split_part(n.old_state, '[', 1) = any (names) and split_part(n.old_state, '[', 1) is distinct from split_part(n.new_state, '[', 1)
  loop
    perform mc.container_purge(r.dimension, r.x, r.y, r.z, true);
    delete from mc.block_entity e where e.dimension = r.dimension and e.x = r.x and e.y = r.y and e.z = r.z;
    update mc.menu_state m set stale = true where m.open and (m.dimension is not distinct from r.dimension or m.dimension is null) and ((m.x, m.y, m.z) = (r.x, r.y, r.z) or (m.x2, m.y2, m.z2) = (r.x, r.y, r.z));
  end loop;
  for r in select n.dimension, n.x, n.y, n.z, n.new_state from nr n
            where n.kind = 'block' and split_part(n.new_state, '[', 1) = any (names) and split_part(n.old_state, '[', 1) is distinct from split_part(n.new_state, '[', 1)
  loop
    insert into mc.block_entity (dimension, cx, cz, x, y, z, type)
    select r.dimension, r.x >> 4, r.z >> 4, r.x, r.y, r.z, split_part(r.new_state, '[', 1)
     where exists (select 1 from mc.chunk c where c.dimension = r.dimension and c.cx = r.x >> 4 and c.cz = r.z >> 4)
    on conflict (dimension, x, y, z) do update set type = excluded.type;
  end loop;
  -- fills (a section's worth of cells): whatever stood on a changed position is simply gone
  if exists (select 1 from nr n where n.kind = 'cells') then
    update mc.menu_state m set stale = true
     where m.open and m.dimension is not null and exists (select 1 from nr n where n.kind = 'cells' and n.dimension = m.dimension and m.x between n.x and n.x + 15 and m.y between n.y and n.y + 15 and m.z between n.z and n.z + 15
                                                           and get_bit(n.cells, ((m.y - n.y) << 8) | ((m.z - n.z) << 4) | (m.x - n.x)) = 1);
    delete from mc.container_slot c using nr n
     where n.kind = 'cells' and c.dimension = n.dimension and c.x between n.x and n.x + 15 and c.y between n.y and n.y + 15 and c.z between n.z and n.z + 15
       and get_bit(n.cells, ((c.y - n.y) << 8) | ((c.z - n.z) << 4) | (c.x - n.x)) = 1;
    delete from mc.furnace f using nr n
     where n.kind = 'cells' and f.dimension = n.dimension and f.x between n.x and n.x + 15 and f.y between n.y and n.y + 15 and f.z between n.z and n.z + 15
       and get_bit(n.cells, ((f.y - n.y) << 8) | ((f.z - n.z) << 4) | (f.x - n.x)) = 1;
  end if;
  return null;
end $$;
drop trigger if exists container_on_block_event on mc.block_event;
create trigger container_on_block_event after insert on mc.block_event referencing new table as nr for each statement execute function mc.container_on_block_event();
