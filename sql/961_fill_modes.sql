-- The modes of /fill (docs/WORLD.md "Large fills", "Fill modes"): replace [filter], keep, outline, hollow.  `destroy` is refused (it drops items and sends a break effect for every
-- block, which nothing here produces).  mc.fill (sql/210) stays the default mode (replace, no filter) and keeps its own, leaner, loop.
--
-- A mode is a set of boxes per section and a filter, handed to mc.fill_section_core (sql/210), which does the work word by word on the packed section data:
--   * replace <filter>   one box, only the positions whose state matches the filter.  The filter is a block ('stone' or 'minecraft:stone': every state of it), a block with
--                        properties ('oak_log[axis=x]': every state of the block with those properties), or a block tag ('#minecraft:logs', nested tags included).
--   * keep               one box, only the positions that are air (air, cave_air, void_air).
--   * outline            the six faces of the box (disjoint slabs), the inside is left alone.
--   * hollow             the faces get the block, the inside becomes air.
-- Vanilla visits the positions of the box once, x fastest, then y, then z, and puts every position whose state changed into the section's set; the set therefore holds the changed
-- positions in that order whatever the mode.  Here every section gets ONE 'cells' event with the union of the changed positions of its boxes, and mc.shortset_order is applied to
-- the positions in the same order (z, y, x), so the packets are those of vanilla's loop.  `outline` and `keep` put one block everywhere they change (new_state = the block, the
-- packet is built by the fill as for mc.fill); `hollow` puts two blocks in one section (new_state = '*': the broadcast reads the states from the section).
-- Sections with a global palette (more than 256 states) go position by position through mc.edit_section, in the order of vanilla's loop.
-- Returns the number of blocks changed (vanilla's /fill reports that number; mc.fill returns the number of blocks in the box).

-- The union of two bit maps of mc.block_event.cells (NULL is the empty map).
create or replace function mc.bm_or(a bytea, b bytea) returns bytea language sql immutable parallel safe as $$
  select case when a is null then b when b is null then a else
    decode(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(
             regexp_replace((('x' || encode(a, 'hex'))::bit(4096) | ('x' || encode(b, 'hex'))::bit(4096))::text, '(....)', '\1 ', 'g'),
             '0000 ', '0'), '0001 ', '1'), '0010 ', '2'), '0011 ', '3'), '0100 ', '4'), '0101 ', '5'), '0110 ', '6'), '0111 ', '7'),
             '1000 ', '8'), '1001 ', '9'), '1010 ', 'a'), '1011 ', 'b'), '1100 ', 'c'), '1101 ', 'd'), '1110 ', 'e'), '1111 ', 'f'), 'hex') end $$;

-- The block states a /fill filter stands for (see above).  An unknown block or tag, or properties no state has, is an error (vanilla refuses them too).
create or replace function mc.fill_filter_states(p_filter text) returns text[] language plpgsql stable as $$
declare f text := btrim(p_filter); nm text; props jsonb := '{}'; res text[]; q text;
begin
    if f like '#%' then
        nm := substr(f, 2); if position(':' in nm) = 0 then nm := 'minecraft:' || nm; end if;
        res := array(with recursive t(tag) as (select nm union select substr(m.member, 2) from t join ref.dp_tag_member m on m.registry = 'minecraft:block' and m.tag = t.tag and m.member like '#%')
                     select distinct s.name from t join ref.dp_tag_member m on m.registry = 'minecraft:block' and m.tag = t.tag and m.member not like '#%' join ref.block_state s on s.block = m.member order by 1);
        if not exists (select 1 from ref.dp_tag where registry = 'minecraft:block' and tag = nm) then raise exception 'unknown block tag %', f; end if;
    else
        if position('[' in f) > 0 then
            nm := split_part(f, '[', 1);
            props := coalesce((select jsonb_object_agg(btrim(split_part(kv, '=', 1)), btrim(split_part(kv, '=', 2))) from unnest(string_to_array(rtrim(split_part(f, '[', 2), ']'), ',')) kv where btrim(kv) <> ''), '{}');
        else nm := f; end if;
        if position(':' in nm) = 0 then nm := 'minecraft:' || nm; end if;
        if not exists (select 1 from ref.block where name = nm) then raise exception 'unknown block %', nm; end if;
        res := array(select s.name from ref.block_state s where s.block = nm and s.properties @> props order by s.state_id);
    end if;
    if cardinality(res) = 0 then raise exception 'the filter % matches no block state', p_filter; end if;
    return res;
end $$;

-- The boxes of a mode in absolute coordinates: kind 0 = the block, kind 1 = air inside a hollow box.  (outline and hollow: the faces as six disjoint slabs; a box with no inside
-- is all faces.)
create or replace function mc.fill_boxes(p_mode text, lo_x int, hi_x int, lo_y int, hi_y int, lo_z int, hi_z int)
returns table (kind int, x1 int, x2 int, y1 int, y2 int, z1 int, z2 int) language sql immutable parallel safe as $$
  select v.kind, v.x1, v.x2, v.y1, v.y2, v.z1, v.z2 from (values
    (0, lo_x, lo_x, lo_y, hi_y, lo_z, hi_z, true),
    (0, hi_x, hi_x, lo_y, hi_y, lo_z, hi_z, hi_x > lo_x),
    (0, lo_x + 1, hi_x - 1, lo_y, lo_y, lo_z, hi_z, true),
    (0, lo_x + 1, hi_x - 1, hi_y, hi_y, lo_z, hi_z, hi_y > lo_y),
    (0, lo_x + 1, hi_x - 1, lo_y + 1, hi_y - 1, lo_z, lo_z, true),
    (0, lo_x + 1, hi_x - 1, lo_y + 1, hi_y - 1, hi_z, hi_z, hi_z > lo_z),
    (1, lo_x + 1, hi_x - 1, lo_y + 1, hi_y - 1, lo_z + 1, hi_z - 1, true)) v(kind, x1, x2, y1, y2, z1, z2, ok)
  where p_mode in ('outline', 'hollow') and v.ok and (v.kind = 0 or p_mode = 'hollow') and v.x1 <= v.x2 and v.y1 <= v.y2 and v.z1 <= v.z2
  union all
  select 0, lo_x, hi_x, lo_y, hi_y, lo_z, hi_z where p_mode not in ('outline', 'hollow') $$;

create or replace function mc.fill_mode(p_dim text, x1 int, y1 int, z1 int, x2 int, y2 int, z2 int, p_block text, p_mode text default 'replace', p_filter text default null)
returns int language plpgsql volatile as $$
declare
    d       mc.dimension%rowtype;
    mode    text := lower(p_mode);
    nm      text := mc.canon_state(p_block);
    lo_x    int := least(x1, x2);  hi_x int := greatest(x1, x2);
    lo_y    int := least(y1, y2);  hi_y int := greatest(y1, y2);
    lo_z    int := least(z1, z2);  hi_z int := greatest(z1, z2);
    filt    text[];
    v_cx    int; v_cz int; v_sy int;
    bx      record; a_x int; b_x int; a_y int; b_y int; a_z int; b_z int;
    fr      record; ub bytea; mixed boolean; csec int; nsec int; total int := 0; r int; pc int;
    idxs    int[]; names text[];
    wx int; wy int; wz int; old text; tgt text; on_shell boolean;
    watched boolean; st int; any_view boolean;
    ev_cx   int[] := '{}'; ev_y int[] := '{}'; ev_cz int[] := '{}'; ev_bm bytea[] := '{}'; ev_st text[] := '{}'; ev_pkt bytea[] := '{}'; ne int := 0;
begin
    if mode = 'destroy' then raise exception 'fill ... destroy is not supported: it drops the blocks'' items and sends a break effect for every block'; end if;
    if mode not in ('replace', 'keep', 'outline', 'hollow') then raise exception 'unknown fill mode % (replace, keep, outline, hollow)', p_mode; end if;
    if p_filter is not null and mode <> 'replace' then raise exception 'a filter belongs to the replace mode'; end if;
    select * into d from mc.dimension where name = p_dim;
    if not found then raise exception 'unknown dimension %', p_dim; end if;
    if lo_y < d.min_y or hi_y >= d.min_y + d.height then raise exception 'fill is outside dimension % (y % .. %)', p_dim, d.min_y, d.min_y + d.height - 1; end if;
    if mode = 'keep' then filt := array(select s.name from ref.block_state s where s.block in ('minecraft:air', 'minecraft:cave_air', 'minecraft:void_air') order by s.state_id);
    elsif p_filter is not null then filt := mc.fill_filter_states(p_filter); end if;
    select exists (select 1 from net.conn c where c.state = 'play' and not c.closing and c.view_cx is not null) into any_view;
    insert into mc.chunk (dimension, cx, cz)
    select p_dim, cx, cz from generate_series(lo_x >> 4, hi_x >> 4) cx, generate_series(lo_z >> 4, hi_z >> 4) cz on conflict do nothing;
    for v_cx in (lo_x >> 4) .. (hi_x >> 4) loop
      for v_cz in (lo_z >> 4) .. (hi_z >> 4) loop
        csec := 0; watched := null;
        for v_sy in (lo_y >> 4) .. (hi_y >> 4) loop
            ub := null; mixed := false; nsec := 0;
            -- a section with a global palette (no palette entries) or one so full that a new block could outgrow it takes the slow way from the start
            select cardinality(s.palette) into pc from mc.chunk_section s where s.dimension = p_dim and s.cx = v_cx and s.cz = v_cz and s.sy = v_sy;
            r := case when pc = 0 or pc >= 255 then -1 else 0 end;
            for bx in select * from mc.fill_boxes(mode, lo_x, hi_x, lo_y, hi_y, lo_z, hi_z) where r <> -1 loop
                a_x := greatest(bx.x1, v_cx * 16); b_x := least(bx.x2, v_cx * 16 + 15);
                a_y := greatest(bx.y1, v_sy * 16); b_y := least(bx.y2, v_sy * 16 + 15);
                a_z := greatest(bx.z1, v_cz * 16); b_z := least(bx.z2, v_cz * 16 + 15);
                continue when a_x > b_x or a_y > b_y or a_z > b_z;
                select * into fr from mc.fill_section_core(p_dim, v_cx, v_sy, v_cz, a_x & 15, b_x & 15, a_y & 15, b_y & 15, a_z & 15, b_z & 15,
                                                          case when bx.kind = 0 then nm else 'minecraft:air' end, d.default_biome, case when bx.kind = 0 then filt end);
                if fr.changed = -1 then raise exception 'fill_section_core refused a section it was expected to take (% % %)', v_cx, v_sy, v_cz; end if;
                if fr.changed > 0 then
                    nsec := nsec + fr.changed; ub := mc.bm_or(ub, fr.bm);
                    if bx.kind = 1 and nm <> 'minecraft:air' then mixed := true; end if;
                end if;
            end loop;
            if r = -1 then
                -- position by position, in the order of vanilla's loop (z, y, x), with the block each position gets in this mode
                idxs := '{}'; names := '{}';
                for wz in greatest(lo_z, v_cz * 16) .. least(hi_z, v_cz * 16 + 15) loop
                  for wy in greatest(lo_y, v_sy * 16) .. least(hi_y, v_sy * 16 + 15) loop
                    for wx in greatest(lo_x, v_cx * 16) .. least(hi_x, v_cx * 16 + 15) loop
                        on_shell := wx in (lo_x, hi_x) or wy in (lo_y, hi_y) or wz in (lo_z, hi_z);
                        old := mc.get_block(p_dim, wx, wy, wz);
                        tgt := case mode when 'outline' then case when on_shell then nm end
                                         when 'hollow' then case when on_shell then nm else 'minecraft:air' end
                                         when 'keep' then case when mc.is_air(old) then nm end
                                         else case when filt is null or old = any (filt) then nm end end;
                        continue when tgt is null or old = tgt;
                        idxs := idxs || mc.section_idx(wx, wy, wz); names := names || tgt;
                    end loop;
                  end loop;
                end loop;
                if cardinality(idxs) > 0 then total := total + mc.edit_section(p_dim, v_cx, v_sy, v_cz, idxs, names, true); end if;
            elsif nsec > 0 then
                csec := csec + 1; ne := ne + 1; total := total + nsec;
                if watched is null then watched := any_view and mc.chunk_watched(v_cx, v_cz); end if;
                if watched and not mixed and st is null then st := mc.block_state_id(nm); end if;
                ev_cx := array_append(ev_cx, v_cx); ev_y := array_append(ev_y, v_sy); ev_cz := array_append(ev_cz, v_cz); ev_bm := array_append(ev_bm, ub);
                ev_st := array_append(ev_st, case when mixed then '*' else nm end);
                ev_pkt := array_append(ev_pkt, case when watched and not mixed then mc.fill_packet(v_cx, v_sy, v_cz, ub, st) end);
            end if;
        end loop;
        if csec > 0 then
            update mc.chunk c set version = c.version + csec, dirty = true, hm_dirty = true where c.dimension = p_dim and c.cx = v_cx and c.cz = v_cz;
        end if;
      end loop;
    end loop;
    if ne > 0 then
        insert into mc.block_event (kind, dimension, x, y, z, old_state, new_state, cells, pkt)
        select 'cells', p_dim, e.cx * 16, e.sy * 16, e.cz * 16, '*', e.st, e.bm, e.pkt from unnest(ev_cx, ev_y, ev_cz, ev_bm, ev_st, ev_pkt) with ordinality e(cx, sy, cz, bm, st, pkt, o) order by e.o;
    end if;
    return total;
end $$;
