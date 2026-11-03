-- The ORIGINAL mc.fill (sql/210_world_blocks.sql at commit 54bee0d, before the box fill with mc.fill_section), kept as bench_old.fill for the A/B benchmark
-- tests/bench/world/ab_fill.sql: whole sections become single-value sections and queue a 'section' event; every partial section goes through mc.edit_section (one
-- event row per changed block, heightmaps kept exact incrementally).  Verbatim apart from the schema and the name.
create schema if not exists bench_old;
create or replace function bench_old.fill(p_dim text, x1 int, y1 int, z1 int, x2 int, y2 int, z2 int, p_block text) returns int language plpgsql volatile as $$
declare
    d       mc.dimension%rowtype;
    nm      text := mc.canon_state(p_block);
    lo_x    int := least(x1, x2);  hi_x int := greatest(x1, x2);
    lo_y    int := least(y1, y2);  hi_y int := greatest(y1, y2);
    lo_z    int := least(z1, z2);  hi_z int := greatest(z1, z2);
    v_cx    int; v_cz int; v_sy int;
    a_x     int; b_x int; a_y int; b_y int; a_z int; b_z int;
    idxs    int[];
    covered int := 0;
begin
    select * into d from mc.dimension where name = p_dim;
    if not found then raise exception 'unknown dimension %', p_dim; end if;
    if lo_y < d.min_y or hi_y >= d.min_y + d.height then raise exception 'fill is outside dimension % (y % .. %)', p_dim, d.min_y, d.min_y + d.height - 1; end if;
    for v_cx in (lo_x >> 4) .. (hi_x >> 4) loop
      for v_cz in (lo_z >> 4) .. (hi_z >> 4) loop
        for v_sy in (lo_y >> 4) .. (hi_y >> 4) loop
            a_x := greatest(lo_x, v_cx * 16); b_x := least(hi_x, v_cx * 16 + 15);
            a_y := greatest(lo_y, v_sy * 16); b_y := least(hi_y, v_sy * 16 + 15);
            a_z := greatest(lo_z, v_cz * 16); b_z := least(hi_z, v_cz * 16 + 15);
            covered := covered + (b_x - a_x + 1) * (b_y - a_y + 1) * (b_z - a_z + 1);
            if b_x - a_x = 15 and b_y - a_y = 15 and b_z - a_z = 15 then
                -- whole section: becomes a single-value section, nothing to unpack
                insert into mc.chunk (dimension, cx, cz) values (p_dim, v_cx, v_cz) on conflict do nothing;
                insert into mc.chunk_section as s (dimension, cx, cz, sy, block_count, fluid_count, palette, bits, data, biome_palette)
                values (p_dim, v_cx, v_cz, v_sy, case when mc.is_air(nm) then 0 else 4096 end, case when mc.has_fluid(nm) then 4096 else 0 end,
                        array[nm], 0, '\x', array[d.default_biome])
                on conflict (dimension, cx, cz, sy) do update
                   set block_count = excluded.block_count, fluid_count = excluded.fluid_count, palette = excluded.palette, bits = 0, data = '\x';
                update mc.chunk c set version = c.version + 1, dirty = true, hm_dirty = true where c.dimension = p_dim and c.cx = v_cx and c.cz = v_cz;
                insert into mc.block_event (kind, dimension, x, y, z, old_state, new_state) values ('section', p_dim, v_cx * 16, v_sy * 16, v_cz * 16, '*', nm);
            else
                idxs := array(select mc.section_idx(x, y, z) from generate_series(a_x, b_x) x, generate_series(a_y, b_y) y, generate_series(a_z, b_z) z);
                perform mc.edit_section(p_dim, v_cx, v_sy, v_cz, idxs, array_fill(nm, array[cardinality(idxs)]), true);
            end if;
        end loop;
      end loop;
    end loop;
    return covered;
end $$;
