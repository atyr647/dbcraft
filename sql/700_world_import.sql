-- World import support (tools/world_import.py, docs/WORLD-IMPORT.md).
--
-- The importer bulk-loads sections straight from Anvil region files with block_count = -1 ("not counted yet"); mc.import_recount then fills block_count and
-- fluid_count with the same name-based classification the rest of the world module uses (mc.is_air, mc.has_fluid), set-based, in one statement.
-- Counting here instead of in Python keeps the importer fast: a Python loop over 4,096 entries per section would be the whole import time.

-- Non-air and fluid-bearing block counts of one section in the wire format (palette names + packed longs).
-- bits = 0: single value; palette empty (global palette): the entries are block-state ids.
create or replace function mc.section_counts(p_palette text[], p_bits int, p_data bytea, out block_count int, out fluid_count int)
language plpgsql stable as $$
begin
    if p_bits = 0 then
        block_count := case when mc.is_air(p_palette[1]) then 0 else 4096 end;
        fluid_count := case when mc.has_fluid(p_palette[1]) then 4096 else 0 end;
        return;
    end if;
    if coalesce(cardinality(p_palette), 0) = 0 then
        select coalesce(sum(h.c) filter (where not mc.is_air(s.name)), 0)::int, coalesce(sum(h.c) filter (where mc.has_fluid(s.name)), 0)::int
          into block_count, fluid_count
          from (select u.i, count(*) c from unnest(mc.unpack_longs(p_data, p_bits, 4096)) u(i) group by u.i) h
          join ref.block_state s on s.state_id = h.i;
    else
        select coalesce(sum(h.c) filter (where not mc.is_air(p_palette[h.i + 1])), 0)::int, coalesce(sum(h.c) filter (where mc.has_fluid(p_palette[h.i + 1])), 0)::int
          into block_count, fluid_count
          from (select u.i, count(*) c from unnest(mc.unpack_longs(p_data, p_bits, 4096)) u(i) group by u.i) h;
    end if;
end $$;

-- Counts every section of a dimension that the importer left at -1.  Returns the number of sections counted.
create or replace function mc.import_recount(p_dim text) returns int language sql volatile as $$
    with u as (
        update mc.chunk_section s set block_count = c.block_count, fluid_count = c.fluid_count
          from (select t.dimension, t.cx, t.cz, t.sy, k.block_count, k.fluid_count
                  from mc.chunk_section t, lateral mc.section_counts(t.palette, t.bits, t.data) k
                 where t.dimension = p_dim and t.block_count = -1) c
         where s.dimension = c.dimension and s.cx = c.cx and s.cz = c.cz and s.sy = c.sy
        returning 1)
    select count(*)::int from u $$;

-- Game rules of an imported world, readable and editable.  (The game module does not read them yet: the table is where an import puts them.)
create table if not exists mc.game_rule (
    name  text primary key,                 -- minecraft:max_entity_cramming
    value text not null                     -- 'true' / 'false' / a number, as text
);
