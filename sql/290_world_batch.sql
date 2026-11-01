-- Batched edits: mc.set_blocks.
--
-- The first version looped over the touched sections and called mc.edit_section for each (about a dozen statements per section: dimension, block names, chunk row,
-- section read, section write, chunk write with heightmaps, events).  Measured: about 0.5 ms per section plus 5-7 us per edit, so 10,000 edits in 100 sections took
-- 135 ms of CPU and 10,000 edits in 1,000 sections 550 ms.  This version keeps the loop but removes what is repeated:
--   * the dimension and the block names are resolved ONCE per batch (one statement), not once per section;
--   * a section costs two statements (mc.edit_section_core: read it, write it);
--   * the chunk row is read once and written once per CHUNK (version += its changed sections, dirty, heightmaps), with the heightmaps kept in local arrays while the
--     chunk's sections are processed (they come in key order, so a chunk's sections are consecutive);
--   * the heightmap rules are applied inline per change (a placed block above the top raises it; removing the top rescans the column with mc.column_top, reading the
--     sections written so far) instead of three function calls per change;
--   * all events of the batch are queued with ONE insert at the end, in the order the loop produced them.
-- A set-based version (every phase one statement over all edits, window function for repeated positions, bit surgery with aggregates) was written and verified first
-- (tests/bench/edit/exp_setbased.sql, schema mc_exp): it is slower at most sizes, because the executor charges about 0.3-0.5 us per row per plan node and the pipeline
-- has fifteen nodes; see docs/PERF-EDIT.md.
--
-- Results are identical to the original loop's, row for row (tests/sql/290_world_batch.sql applies random batches through both and compares sections, chunks, events and
-- packets).

create or replace function mc.set_blocks(p_dim text, xs int[], ys int[], zs int[], blocks text[]) returns int
language plpgsql volatile set plan_cache_mode = force_generic_plan as $$
declare
    n        int := cardinality(xs);
    d        mc.dimension%rowtype;
    grp      record;
    dn       text[];
    cn       text[];
    missing  text;
    res      mc.sec_edit_result;
    total    int := 0;
    -- chunk-level state, kept while the (consecutive) sections of one chunk are processed
    cur_cx   int;
    cur_cz   int;
    cur_secs int := 0;                 -- changed sections of the current chunk (its version moves by this much)
    hm_ok    boolean := false;         -- the chunk has exact heightmaps that this batch maintains
    hm_ch    boolean := false;         -- ... and they changed
    hws      smallint[];
    hmb      smallint[];
    hmn      smallint[];
    -- the events of the whole batch, in order
    ev_x     int[] := '{}';
    ev_y     int[] := '{}';
    ev_z     int[] := '{}';
    ev_old   text[] := '{}';
    ev_new   text[] := '{}';
    evn      int := 0;
    -- per-batch memo of the heightmap flags of a block name (three flags per name: world_surface, motion_blocking, motion_blocking_no_leaves)
    hn       text[] := '{}';
    hfl      boolean[] := '{}';
    k        int;
    j        int;
    i        int;
    col      int;
    val      int;
    h1 int; h2 int; h3 int;
    ofl      boolean[]; nfl boolean[];
    px int; py int; pz int;
    r_idx    int[];
    r_old    text[];
    r_new    text[];
begin
    if cardinality(ys) <> n or cardinality(zs) <> n or cardinality(blocks) <> n then
        raise exception 'set_blocks: the four arrays must have the same length';
    end if;
    if n = 0 then return 0; end if;
    select * into d from mc.dimension where name = p_dim;
    if not found then raise exception 'unknown dimension %', p_dim; end if;

    -- canonical state names, once per distinct name in the batch (a bare block name means its default state; an unknown name is an error)
    select array_agg(q.n order by q.n), array_agg(coalesce(s.name, ds.name) order by q.n), (array_agg(q.n order by q.n) filter (where coalesce(s.name, ds.name) is null))[1]
      into dn, cn, missing
      from (select distinct b as n from unnest(blocks) b) q
      left join ref.block_state s on s.name = q.n
      left join ref.block b on b.name = q.n
      left join ref.block_state ds on ds.state_id = b.default_state;
    if missing is not null then perform mc.canon_state(missing); end if;                -- raises 'unknown block state ...'

    -- the chunk rows exist before their sections are written (the foreign key); as the original did, this happens even for edits that turn out to change nothing
    insert into mc.chunk (dimension, cx, cz)
    select distinct p_dim, t.x >> 4, t.z >> 4 from unnest(xs, zs) t(x, z) on conflict do nothing;

    -- sections in key order: concurrent batches lock in the same order
    for grp in
        select t.x >> 4 as cx, t.z >> 4 as cz, t.y >> 4 as sy,
               array_agg(((t.y & 15) << 8) | ((t.z & 15) << 4) | (t.x & 15) order by t.o) as idxs, array_agg(t.b order by t.o) as names
          from unnest(xs, ys, zs, blocks) with ordinality t(x, y, z, b, o)
         group by 1, 2, 3 order by 1, 2, 3
    loop
        if grp.sy < (d.min_y >> 4) or grp.sy >= ((d.min_y + d.height) >> 4) then
            raise exception 'section % is outside dimension % (y % .. %)', grp.sy, p_dim, d.min_y, d.min_y + d.height - 1;
        end if;
        -- a new chunk: write the previous one, read this one
        if cur_cx is distinct from grp.cx or cur_cz is distinct from grp.cz then
            if cur_cx is not null and cur_secs > 0 then
                if hm_ch then
                    update mc.chunk c set version = c.version + cur_secs, dirty = true, hm_world_surface = hws, hm_motion_blocking = hmb, hm_motion_blocking_no_leaves = hmn
                     where c.dimension = p_dim and c.cx = cur_cx and c.cz = cur_cz;
                else
                    update mc.chunk c set version = c.version + cur_secs, dirty = true where c.dimension = p_dim and c.cx = cur_cx and c.cz = cur_cz;
                end if;
            end if;
            cur_cx := grp.cx; cur_cz := grp.cz; cur_secs := 0; hm_ch := false;
            select c.hm_world_surface, c.hm_motion_blocking, c.hm_motion_blocking_no_leaves, c.hm_world_surface is not null and not c.hm_dirty into hws, hmb, hmn, hm_ok
              from mc.chunk c where c.dimension = p_dim and c.cx = cur_cx and c.cz = cur_cz;
        end if;

        res := mc.edit_section_core(p_dim, grp.cx, grp.sy, grp.cz, grp.idxs, grp.names, dn, cn, d.default_biome);
        if res.changed = 0 then continue; end if;
        total := total + res.changed;
        cur_secs := cur_secs + 1;
        r_idx := res.ev_idx; r_old := res.ev_old; r_new := res.ev_new;      -- plain local arrays: indexing a field of a composite variable copies the array on every access

        for k in 1 .. res.changed loop
            i := r_idx[k];
            px := grp.cx * 16 + (i & 15); py := grp.sy * 16 + (i >> 8); pz := grp.cz * 16 + ((i >> 4) & 15);
            evn := evn + 1;
            ev_x[evn] := px; ev_y[evn] := py; ev_z[evn] := pz; ev_old[evn] := r_old[k]; ev_new[evn] := r_new[k];
            -- heightmaps: exact incrementally; an edit below the top of every kind cannot change them (as in mc.edit_section)
            if hm_ok then
                col := (i & 15) + 16 * ((i >> 4) & 15);
                val := py + 1 - d.min_y;
                h1 := hws[col + 1]; h2 := hmb[col + 1]; h3 := hmn[col + 1];
                continue when val < least(h1, h2, h3);
                j := array_position(hn, r_old[k]);
                if j is null then hn := hn || r_old[k]; hfl := hfl || mc.heightmap_flags(r_old[k]); j := cardinality(hn); end if;
                ofl := hfl[(j - 1) * 3 + 1 : (j - 1) * 3 + 3];
                j := array_position(hn, r_new[k]);
                if j is null then hn := hn || r_new[k]; hfl := hfl || mc.heightmap_flags(r_new[k]); j := cardinality(hn); end if;
                nfl := hfl[(j - 1) * 3 + 1 : (j - 1) * 3 + 3];
                -- (what mc.hm_step does: a qualifying block above the top raises it; removing the top re-finds it below)
                if nfl[1] and val > h1 then hws[col + 1] := val; hm_ch := true;
                elsif ofl[1] and not nfl[1] and val = h1 then hws[col + 1] := mc.column_top(p_dim, grp.cx, grp.cz, col, val - 2 + d.min_y, 1); hm_ch := true; end if;
                if nfl[2] and val > h2 then hmb[col + 1] := val; hm_ch := true;
                elsif ofl[2] and not nfl[2] and val = h2 then hmb[col + 1] := mc.column_top(p_dim, grp.cx, grp.cz, col, val - 2 + d.min_y, 2); hm_ch := true; end if;
                if nfl[3] and val > h3 then hmn[col + 1] := val; hm_ch := true;
                elsif ofl[3] and not nfl[3] and val = h3 then hmn[col + 1] := mc.column_top(p_dim, grp.cx, grp.cz, col, val - 2 + d.min_y, 3); hm_ch := true; end if;
            end if;
        end loop;
    end loop;

    -- the last chunk
    if cur_cx is not null and cur_secs > 0 then
        if hm_ch then
            update mc.chunk c set version = c.version + cur_secs, dirty = true, hm_world_surface = hws, hm_motion_blocking = hmb, hm_motion_blocking_no_leaves = hmn
             where c.dimension = p_dim and c.cx = cur_cx and c.cz = cur_cz;
        else
            update mc.chunk c set version = c.version + cur_secs, dirty = true where c.dimension = p_dim and c.cx = cur_cx and c.cz = cur_cz;
        end if;
    end if;

    -- all events of the batch, in order
    if evn > 0 then
        insert into mc.block_event (dimension, x, y, z, old_state, new_state)
        select p_dim, e.x, e.y, e.z, e.o, e.n from unnest(ev_x, ev_y, ev_z, ev_old, ev_new) with ordinality e(x, y, z, o, n, ord) order by e.ord;
    end if;
    return total;
end $$;
