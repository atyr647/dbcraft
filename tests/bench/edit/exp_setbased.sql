-- EXPERIMENT (not part of the migrations): mc_exp.set_blocks, the set-based batch edit.  Correct (tests/sql/290_world_batch.sql proves it against the original loop) but
-- slower than the loop at most sizes: see docs/PERF-EDIT.md.  Load it into a test database with `\i tests/bench/edit/exp_setbased.sql` to reproduce the numbers.
create schema if not exists mc_exp;
-- Batched edits: mc.set_blocks as a set-based pass instead of one mc.edit_section call per touched section.
--
-- The first version looped over the touched sections and called mc.edit_section (about a dozen statements each: 1 ms per section plus 4-5 us per edit, so 10,000
-- edits in 100 sections took about 190 ms).  This version does the same work for all sections at once, in a fixed number of statements:
--
--   0. validate, resolve the distinct block names once, create missing chunk rows, lock the touched sections (in the order the old loop locked them), and read the
--      stored sections and the chunks' heightmaps (as arrays of rows: separate statements, so that the big statement below never joins against a big table);
--   1. ONE statement computes and writes everything for the sections: for every edit the block that was at its position before it (the stored entry, or the
--      previous edit of the same position, through a window function: repeated positions behave exactly as sequential edits did), the effective changes (these
--      become the events, in the old order: by section, then by edit order), the new palette (names in order of first use), and the new packed data:
--        - same bit width (the common case): bit surgery on the affected 64-bit words only: per word the edited entries' masks and values are OR-ed together with
--          an aggregate, and the new data is the old bytes with those words replaced (substring of the gaps + the new words);
--        - bit width grows (palette outgrows 4/5/6/7/8 bits, or becomes the global palette): every entry of the section is recomputed in one set operation
--          (4,096 rows per such section) and packed with a grouped aggregate;
--      block and fluid counts come from the effective changes.  The same statement works out, per column whose top may have moved, the best qualifying edited
--      position and whether the old top was removed (these need only the edits and the heightmaps, not the written sections);
--   2. a last small statement finishes the heightmaps (a column whose top was removed is rescanned: that reads the stored sections, which by now hold the final
--      data), and one UPDATE writes version (+ changed sections of the chunk, what the loop did), dirty flag and heightmaps.
--
-- Why the statements are split like this: the planner cannot know how many rows a chain of CTEs produces (its estimate collapses to "1 row" after two joins), and then
-- picks nested loops that re-run whole sub-plans for every row (measured: 700 ms for 500 edits in 100 sections).  The statement that only joins CTEs runs with
-- nested loops disabled, so every join is a hash or merge join, linear in the number of edits; it touches no big table (stored sections and chunk rows arrive as
-- arrays, name and state-id lookups are per-row index probes in scalar subqueries), so nothing can turn into a scan of the world.  JIT is off: the penalty cost that
-- "disabled" nested loops add to the plan pushes its estimated cost over the JIT threshold, and compiling 300 functions took 4 seconds per call.
--
-- Results are identical to the loop's, row for row (tests/sql/290_world_batch.sql applies random batches through both and compares sections, chunks, events and
-- packets).  A handful of edits is cheaper through the old per-section path (fixed cost of the set-based statements), so small batches still use it.

do $$
begin
    create type mc_exp.batch_sec as (cx int, cz int, sy int, pal text[], bits int, data bytea, bc int, fc int);
exception when duplicate_object then null;
end $$;
do $$
begin
    create type mc_exp.batch_chunk as (cx int, cz int, ws smallint[], mb smallint[], nl smallint[]);
exception when duplicate_object then null;
end $$;
do $$
begin     -- one column whose three tops may move: current tops, the best qualifying edited height per kind, and whether the old top was removed
    create type mc_exp.batch_hmcol as (cx int, cz int, col int, h1 int, h2 int, h3 int, c1 int, c2 int, c3 int, r1 boolean, r2 boolean, r3 boolean);
exception when duplicate_object then null;
end $$;
do $$
begin
    create type mc_exp.batch_secs as (cx int, cz int, nsec int);
exception when duplicate_object then null;
end $$;
do $$
begin
    create type mc_exp.batch_chunk_upd as (cx int, cz int, nsec int, ws smallint[], mb smallint[], nl smallint[]);
exception when duplicate_object then null;
end $$;

create or replace function mc_exp.set_blocks(p_dim text, xs int[], ys int[], zs int[], blocks text[]) returns int
language plpgsql volatile set plan_cache_mode = force_custom_plan set jit = off as $$
-- custom plans on purpose: the statements below are planned for the real number of edits (a generic plan would assume a handful of rows)
declare
    n       int := cardinality(xs);
    d       mc.dimension%rowtype;
    grp     record;
    dn      text[];
    cn      text[];
    ci      int[];
    missing text;
    bad_sy  int;
    total   int := 0;
    sk_arr  mc_exp.batch_sec[];
    hm_arr  mc_exp.batch_chunk[];
    hmc_arr mc_exp.batch_hmcol[];
    secs_arr mc_exp.batch_secs[];
    upd_arr mc_exp.batch_chunk_upd[];
    v_nl    text;
begin
    if cardinality(ys) <> n or cardinality(zs) <> n or cardinality(blocks) <> n then
        raise exception 'set_blocks: the four arrays must have the same length';
    end if;
    if n = 0 then return 0; end if;
    if n <= 8 then                                            -- a handful of edits: the per-section path has no fixed cost
        for grp in
            select t.x >> 4 as cx, t.y >> 4 as sy, t.z >> 4 as cz,
                   array_agg(mc.section_idx(t.x, t.y, t.z) order by t.o) as idxs, array_agg(t.b order by t.o) as names
              from unnest(xs, ys, zs, blocks) with ordinality t(x, y, z, b, o)
             group by 1, 2, 3 order by 1, 3, 2
        loop
            total := total + mc.edit_section(p_dim, grp.cx, grp.sy, grp.cz, grp.idxs, grp.names);
        end loop;
        return total;
    end if;

    select * into d from mc.dimension where name = p_dim;
    if not found then raise exception 'unknown dimension %', p_dim; end if;
    select t.y >> 4 into bad_sy from unnest(xs, ys, zs) t(x, y, z)
     where (t.y >> 4) < (d.min_y >> 4) or (t.y >> 4) >= ((d.min_y + d.height) >> 4) order by t.x >> 4, t.z >> 4, t.y >> 4 limit 1;
    if bad_sy is not null then
        raise exception 'section % is outside dimension % (y % .. %)', bad_sy, p_dim, d.min_y, d.min_y + d.height - 1;
    end if;

    -- canonical state names, resolved once per distinct name (a bare block name means its default state; an unknown name is an error); index probes, no joins
    select array_agg(q.n order by q.n), array_agg(c.name order by q.n), array_agg(c.id order by q.n), (array_agg(q.n order by q.n) filter (where c.name is null))[1]
      into dn, cn, ci, missing
      from (select distinct b as n from unnest(blocks) b) q
      cross join lateral (select coalesce((select s.state_id from ref.block_state s where s.name = q.n),
                                          (select b.default_state from ref.block b where b.name = q.n)) as id) i
      cross join lateral (select (select s2.name from ref.block_state s2 where s2.state_id = i.id) as name, i.id as id) c;
    if missing is not null then perform mc.canon_state(missing); end if;                -- raises 'unknown block state ...'
    if dn is null or array_position(dn, null) is not null then raise exception 'set_blocks: block names must not be null'; end if;

    insert into mc.chunk (dimension, cx, cz)
    select distinct p_dim, t.x >> 4, t.z >> 4 from unnest(xs, zs) t(x, z) on conflict do nothing;
    perform 1 from mc.chunk_section s
      join (select distinct t.x >> 4 as cx, t.z >> 4 as cz, t.y >> 4 as sy from unnest(xs, ys, zs) t(x, y, z)) k on s.cx = k.cx and s.cz = k.cz and s.sy = k.sy
     where s.dimension = p_dim order by s.cx, s.cz, s.sy for update of s;

    -- the touched sections as stored (a missing section is single-value air), sorted by key; the data is copied once so that it is not decompressed on every access
    select array_agg(row(k.cx, k.cz, k.sy, coalesce(s.palette, array['minecraft:air']), coalesce(s.bits, 0)::int, coalesce(s.data, ''::bytea) || ''::bytea,
                         coalesce(s.block_count, 0)::int, coalesce(s.fluid_count, 0)::int)::mc_exp.batch_sec order by k.cx, k.cz, k.sy)
      into sk_arr
      from (select distinct t.x >> 4 as cx, t.z >> 4 as cz, t.y >> 4 as sy from unnest(xs, ys, zs) t(x, y, z)) k
      left join mc.chunk_section s on s.dimension = p_dim and s.cx = k.cx and s.cz = k.cz and s.sy = k.sy;
    -- the heightmaps of the touched chunks that have exact ones
    select array_agg(row(c.cx, c.cz, c.hm_world_surface, c.hm_motion_blocking, c.hm_motion_blocking_no_leaves)::mc_exp.batch_chunk order by c.cx, c.cz) into hm_arr
      from mc.chunk c
      join (select distinct t.x >> 4 as cx, t.z >> 4 as cz from unnest(xs, zs) t(x, z)) k on c.cx = k.cx and c.cz = k.cz
     where c.dimension = p_dim and c.hm_world_surface is not null and not c.hm_dirty;

    v_nl := current_setting('enable_nestloop');
    perform set_config('enable_nestloop', 'off', true);               -- see the header: hash joins only, for a statement that touches no big table
    with
    nm as materialized (
        select u.raw, u.canon, u.sid from unnest(dn, cn, ci) u(raw, canon, sid)),
    sk as materialized (select k.secno, k.cx, k.cz, k.sy, k.pal, k.bits, k.data, k.bc, k.fc from unnest(sk_arr) with ordinality k(cx, cz, sy, pal, bits, data, bc, fc, secno)),
    ed as materialized (                                       -- one row per edit: section number (rank of the section key), index inside the section, canonical block, state id
        select t.o, sk.secno, t.x >> 4 as cx, t.z >> 4 as cz, t.y >> 4 as sy, ((t.y & 15) << 8) | ((t.z & 15) << 4) | (t.x & 15) as idx, nm.canon as nm, nm.sid as sid
          from unnest(xs, ys, zs, blocks) with ordinality t(x, y, z, b, o)
          join nm on nm.raw = t.b
          join sk on sk.cx = t.x >> 4 and sk.cz = t.z >> 4 and sk.sy = t.y >> 4),
    e1 as materialized (                                       -- the stored block at every edited position
        select ed.o, ed.secno, ed.cx, ed.cz, ed.sy, ed.idx, ed.nm, ed.sid,
               case when sk.bits = 0 then sk.pal[1]
                    when cardinality(sk.pal) = 0 then
                         (select gs.name from ref.block_state gs where gs.state_id =
                              ((proto.i64_read(sk.data, (ed.idx / (64 / nullif(sk.bits, 0))) * 8) >> ((ed.idx % (64 / nullif(sk.bits, 0))) * sk.bits)) & ((1::bigint << sk.bits) - 1))::int)
                    else sk.pal[(((proto.i64_read(sk.data, (ed.idx / (64 / nullif(sk.bits, 0))) * 8) >> ((ed.idx % (64 / nullif(sk.bits, 0))) * sk.bits)) & ((1::bigint << sk.bits) - 1))::int) + 1] end as oname
          from ed join sk on sk.secno = ed.secno),
    ch as materialized (                                       -- each edit with the block before it: the previous edit of the same position, else the stored one
        select e1.*, coalesce(lag(e1.nm) over w, e1.oname) as pname, (lead(e1.o) over w is null) as is_last
          from e1 window w as (partition by secno, idx order by o)),
    flags as materialized (
        select q.n, mc.is_air(q.n) as a, mc.has_fluid(q.n) as f
          from (select nm as n from ch group by 1 union select pname from ch group by 1) q),
    chg as materialized (                                      -- effective changes only
        select ch.secno, ch.cx, ch.cz, ch.sy, ch.idx, ch.o, ch.nm, ch.pname, fn.a as a_new, fn.f as f_new, fo.a as a_old, fo.f as f_old
          from ch join flags fn on fn.n = ch.nm join flags fo on fo.n = ch.pname where ch.nm is distinct from ch.pname),
    secsum as materialized (
        select secno, sum((not a_new)::int - (not a_old)::int)::int as dbc, sum(f_new::int - f_old::int)::int as dfc from chg group by 1),
    fu as materialized (select secno, nm, min(o) as first from ed group by 1, 2),
    addn as materialized (                                     -- names this batch adds to a section's palette, in order of first use among ALL its edits
        select s.secno, array_agg(f.nm order by f.first) as add_names
          from sk s join fu f on f.secno = s.secno where cardinality(s.pal) > 0 and f.nm <> all (s.pal) group by 1),
    pl as materialized (                                       -- plan per changed section
        select s.secno, s.cx, s.cz, s.sy, s.pal, s.bits, s.data, s.bc + m.dbc as bc2, s.fc + m.dfc as fc2,
               case when cardinality(s.pal) = 0 then s.pal else s.pal || coalesce(a.add_names, '{}') end as npal,
               case when cardinality(s.pal) = 0 then 16 else mc.block_bits_for(cardinality(s.pal) + coalesce(cardinality(a.add_names), 0)) end as nb
          from sk s join secsum m on m.secno = s.secno left join addn a on a.secno = s.secno),
    pl2 as materialized (
        select pl.*, (pl.bits = 0 or pl.nb = pl.bits) as same_w, 64 / pl.nb as vpl,
               case when pl.bits = 0 then decode(repeat('00', (((4096 + 64 / pl.nb - 1) / (64 / pl.nb)) * 8)), 'hex') else pl.data end as bdata
          from pl),
    fin as not materialized (                                  -- the final edit of each position, with its entry value in the section's NEW palette
        select ch.secno, ch.idx, case when p.nb = 16 then ch.sid else array_position(p.npal, ch.nm) - 1 end as pos
          from ch join pl2 p on p.secno = ch.secno where ch.is_last),
    ---------------------------------------------------------------- same bit width: bit surgery on the affected words
    wd as materialized (
        select f.secno, f.idx / p.vpl as w, bit_or(((1::bigint << p.nb) - 1) << ((f.idx % p.vpl) * p.nb)) as m, bit_or(f.pos::bigint << ((f.idx % p.vpl) * p.nb)) as v
          from fin f join pl2 p on p.secno = f.secno where p.same_w group by 1, 2),
    wdw as materialized (                                      -- gap to the previous modified word and "last word of the section", computed on the NARROW rows
        select secno, w, m, v, coalesce(lag(w) over q, -1) as pw, (lead(w) over q is null) as last_w
          from wd window q as (partition by secno order by w)),
    seg as materialized (                                      -- the old bytes up to this word (the gap) + the new word (+ the tail after the section's last word)
        select x.secno, x.w,
               substring(p.bdata from x.pw * 8 + 9 for (x.w - x.pw - 1) * 8)
                 || int8send((proto.i64_read(p.bdata, x.w * 8) & ~x.m) | x.v)
                 || case when x.last_w then substring(p.bdata from (x.w + 1) * 8 + 1) else ''::bytea end as piece
          from wdw x join pl2 p on p.secno = x.secno),
    outa as materialized (
        select secno, string_agg(piece, ''::bytea order by w) as newdata from seg group by secno),
    ---------------------------------------------------------------- the bit width changes: recompute every entry of those sections and pack again
    rp as materialized (
        select p.secno, p.pal, p.bits, p.data, p.nb, p.vpl, (p.nb = 16 and cardinality(p.pal) > 0) as to_global,
               case when p.nb = 16 and cardinality(p.pal) > 0
                    then array(select (select b.state_id from ref.block_state b where b.name = u.n) from unnest(p.pal) with ordinality u(n, o) order by u.o) end as pids
          from pl2 p where not p.same_w),
    cells as materialized (
        select r.secno, r.nb, r.vpl, i.i as idx,
               coalesce(f.pos, case when r.to_global then r.pids[o.ent + 1] else o.ent end) as val
          from rp r cross join generate_series(0, 4095) i(i)
          cross join lateral (select (((proto.i64_read(r.data, (i.i / (64 / r.bits)) * 8) >> ((i.i % (64 / r.bits)) * r.bits)) & ((1::bigint << r.bits) - 1))::int) as ent) o
          left join fin f on f.secno = r.secno and f.idx = i.i),
    outb as materialized (
        select c.secno, string_agg(int8send(c.w), ''::bytea order by c.wi) as newdata
          from (select secno, idx / vpl as wi, bit_or(val::bigint << ((idx % vpl) * nb)) as w from cells group by secno, idx / vpl) c group by c.secno),
    ---------------------------------------------------------------- the writes
    outp as materialized (
        select p.cx, p.cz, p.sy, p.bc2, p.fc2, case when p.nb = 16 then '{}'::text[] else p.npal end as pal, p.nb as bits, coalesce(a.newdata, b.newdata) as data
          from pl2 p left join outa a on a.secno = p.secno left join outb b on b.secno = p.secno),
    upd as (
        insert into mc.chunk_section as s (dimension, cx, cz, sy, block_count, fluid_count, palette, bits, data, biome_palette, biome_bits, biome_data)
        select p_dim, o.cx, o.cz, o.sy, o.bc2, o.fc2, o.pal, o.bits, o.data, array[d.default_biome], 0, ''::bytea from outp o
        on conflict (dimension, cx, cz, sy) do update
           set block_count = excluded.block_count, fluid_count = excluded.fluid_count, palette = excluded.palette, bits = excluded.bits, data = excluded.data
        returning 1),
    ev as (
        insert into mc.block_event (dimension, x, y, z, old_state, new_state)
        select p_dim, c.cx * 16 + (c.idx & 15), c.sy * 16 + (c.idx >> 8), c.cz * 16 + ((c.idx >> 4) & 15), c.pname, c.nm from chg c order by c.secno, c.o
        returning 1),
    ---------------------------------------------------------------- heightmaps: columns whose tops may move, from the net effect on each position (stored block -> last edit)
    hm as materialized (select k.cx, k.cz, k.ws, k.mb, k.nl from unnest(hm_arr) k),
    posn as materialized (                                     -- positions whose block really changed, with their column, height value and the current tops
        select c.cx, c.cz, c.sy, c.idx, c.oname, c.nm as fname,
               (c.idx & 15) + 16 * ((c.idx >> 4) & 15) as col, c.sy * 16 + (c.idx >> 8) + 1 - d.min_y as val
          from ch c where c.is_last and c.oname is distinct from c.nm),
    nms as materialized (
        select q.n, mc.heightmap_flags(q.n) as f from (select oname as n from posn group by 1 union select fname from posn group by 1) q),
    cand as materialized (
        select p.cx, p.cz, p.col, p.val, fo.f as fof, fn.f as fnf,
               h.ws[p.col + 1] as h1, h.mb[p.col + 1] as h2, h.nl[p.col + 1] as h3
          from posn p join nms fo on fo.n = p.oname join nms fn on fn.n = p.fname join hm h on h.cx = p.cx and h.cz = p.cz
         where p.val >= least(h.ws[p.col + 1], h.mb[p.col + 1], h.nl[p.col + 1])),
    hmcols as materialized (
        select cx, cz, col, max(h1) as h1, max(h2) as h2, max(h3) as h3,
               max(val) filter (where fnf[1]) as c1, max(val) filter (where fnf[2]) as c2, max(val) filter (where fnf[3]) as c3,
               coalesce(bool_or(val = h1 and fof[1] and not fnf[1]), false) as r1,
               coalesce(bool_or(val = h2 and fof[2] and not fnf[2]), false) as r2,
               coalesce(bool_or(val = h3 and fof[3] and not fnf[3]), false) as r3
          from cand group by cx, cz, col),
    secs as materialized (select cx, cz, count(distinct sy)::int as nsec from chg group by 1, 2)
    select (select count(*)::int from ev), (select array_agg(row(h.cx, h.cz, h.col, h.h1, h.h2, h.h3, h.c1, h.c2, h.c3, h.r1, h.r2, h.r3)::mc_exp.batch_hmcol) from hmcols h),
           (select array_agg(row(s.cx, s.cz, s.nsec)::mc_exp.batch_secs order by s.cx, s.cz) from secs s), (select count(*) from upd)
      into total, hmc_arr, secs_arr, n;
    perform set_config('enable_nestloop', v_nl, true);

    if total = 0 then return 0; end if;

    -- finish the heightmaps: columns whose old top was removed are rescanned (reading the final sections); then the new arrays per chunk
    perform set_config('enable_nestloop', 'off', true);
    with hm as materialized (select k.cx, k.cz, k.ws, k.mb, k.nl from unnest(hm_arr) k),
    colnew as materialized (
        select k.cx, k.cz, k.col,
               case when k.r1 then greatest(coalesce(k.c1, 0), mc.column_top(p_dim, k.cx, k.cz, k.col, k.h1 - 2 + d.min_y, 1)) else greatest(k.h1, coalesce(k.c1, 0)) end as n1,
               case when k.r2 then greatest(coalesce(k.c2, 0), mc.column_top(p_dim, k.cx, k.cz, k.col, k.h2 - 2 + d.min_y, 2)) else greatest(k.h2, coalesce(k.c2, 0)) end as n2,
               case when k.r3 then greatest(coalesce(k.c3, 0), mc.column_top(p_dim, k.cx, k.cz, k.col, k.h3 - 2 + d.min_y, 3)) else greatest(k.h3, coalesce(k.c3, 0)) end as n3
          from unnest(hmc_arr) k)
    select array_agg(row(s.cx, s.cz, s.nsec, u.ws, u.mb, u.nl)::mc_exp.batch_chunk_upd order by s.cx, s.cz) into upd_arr
      from unnest(secs_arr) s
      left join lateral (
          select array(select coalesce(cn.n1, h.ws[g + 1]) from generate_series(0, 255) g left join colnew cn on cn.cx = s.cx and cn.cz = s.cz and cn.col = g order by g) as ws,
                 array(select coalesce(cn.n2, h.mb[g + 1]) from generate_series(0, 255) g left join colnew cn on cn.cx = s.cx and cn.cz = s.cz and cn.col = g order by g) as mb,
                 array(select coalesce(cn.n3, h.nl[g + 1]) from generate_series(0, 255) g left join colnew cn on cn.cx = s.cx and cn.cz = s.cz and cn.col = g order by g) as nl
            from hm h where h.cx = s.cx and h.cz = s.cz and exists (select 1 from colnew z where z.cx = s.cx and z.cz = s.cz)) u on true;
    perform set_config('enable_nestloop', v_nl, true);

    update mc.chunk c
       set version = c.version + u.nsec, dirty = true,
           hm_world_surface = coalesce(u.ws, c.hm_world_surface), hm_motion_blocking = coalesce(u.mb, c.hm_motion_blocking),
           hm_motion_blocking_no_leaves = coalesce(u.nl, c.hm_motion_blocking_no_leaves)
      from unnest(upd_arr) u
     where c.dimension = p_dim and c.cx = u.cx and c.cz = u.cz;
    return total;
end $$;
