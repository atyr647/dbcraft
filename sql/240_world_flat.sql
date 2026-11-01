-- Flat world generator (reference implementation; see sql/245_world_gen.sql for the fast path): one block type per y layer, from mc.flat_layer (vanilla's default preset is bedrock, 2 x dirt, grass_block).
-- Sections that are entirely air are not stored (a missing section reads as air with the dimension's default biome).
-- The palette is in order of first appearance from the bottom up, like vanilla's generator, so a generated chunk is byte-identical to the vanilla one.

-- The reference implementation: builds one chunk section by section and derives heightmaps and light the generic way.  Since sql/245 it is used to build
-- the TEMPLATE chunk that mc.generate_flat_batch copies (and by the tests that prove the copy is identical); mc.generate_flat is the fast entry point.
create or replace function mc.generate_flat_slow(p_dim text, p_cx int, p_cz int, p_replace boolean default false) returns boolean language plpgsql volatile as $$
declare
    d         mc.dimension%rowtype;
    sy        int;
    layer     text[];
    pal       text[];
    per_idx   int[];
    bits      int;
    nonair    int;
    fluids    int;
begin
    select * into d from mc.dimension where name = p_dim;
    if not found then raise exception 'unknown dimension %', p_dim; end if;
    if exists (select 1 from mc.chunk c where c.dimension = p_dim and c.cx = p_cx and c.cz = p_cz) then
        if not p_replace then return false; end if;
        delete from mc.chunk c where c.dimension = p_dim and c.cx = p_cx and c.cz = p_cz;
    end if;
    insert into mc.chunk (dimension, cx, cz) values (p_dim, p_cx, p_cz);

    for sy in (d.min_y >> 4) .. ((d.min_y + d.height) >> 4) - 1 loop
        -- the block of each of the 16 y layers of this section
        layer := array(select coalesce((select mc.canon_state(f.block) from mc.flat_layer f where f.dimension = p_dim and f.y = sy * 16 + ly), 'minecraft:air')
                       from generate_series(0, 15) ly order by ly);
        select count(*) filter (where not mc.is_air(n)), count(*) filter (where mc.has_fluid(n)) into nonair, fluids from unnest(layer) n;
        continue when nonair = 0;
        pal := array(select n from (select n, min(o) as first from unnest(layer) with ordinality t(n, o) group by n) q order by first);
        per_idx := array(select array_position(pal, n) - 1 from unnest(layer) with ordinality t(n, o) order by o);
        bits := case when cardinality(pal) = 1 then 0 else greatest(4, mc.ceillog2(cardinality(pal))) end;
        insert into mc.chunk_section (dimension, cx, cz, sy, block_count, fluid_count, palette, bits, data, biome_palette)
        values (p_dim, p_cx, p_cz, sy, nonair * 256, fluids * 256, pal, bits,
                case when bits = 0 then '\x'::bytea
                     else mc.pack_longs(array(select per_idx[(i >> 8) + 1] from generate_series(0, 4095) i order by i), bits) end,
                array[d.default_biome]);
    end loop;

    perform mc.ensure_chunk_current(p_dim, p_cx, p_cz);
    return true;
end $$;
