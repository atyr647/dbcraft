-- Light engine, part 5: light of a set of chunks, from the stored blocks.  See docs/LIGHT.md.
--
-- mc.light_region(dim, cxs, czs) computes the sky and block light of the given chunks exactly as the vanilla engine leaves it, from the blocks of those chunks and of
-- their (existing) neighbours, and writes the light rows (mc.chunk_light).  A cell is reached by light from at most 14 cells away, so the chunk itself plus the ring of
-- its neighbours decide its light; chunks of one call share their neighbours' work, which is why the generators and the join call it for many chunks at once.
--
-- Which sections take part (the others cannot hold light that reaches a target chunk):
--   sky    every column is scanned from the top of the world down to the first cell that stops sky light (dampening > 0): the sections above are sources, the sections
--          that contain such cells are scanned until every column has one, and one more section below the lowest source section of the neighbourhood (light spreads
--          14 cells at most);
--   block  the sections that contain an emitting block state and their 26 neighbours.
create or replace function mc.light_region(p_dim text, p_cxs int[], p_czs int[], p_sky0_as_data boolean default false) returns int language plpgsql volatile set plan_cache_mode = force_generic_plan as $$
declare
    v_min_y  int;
    v_height int;
    v_min_sy int;
    v_nsec   int;
    v_max_sy int;
    h        int;
    ly       int;
    base     int;
    n        int;
    lo       int;
    wrote    int;
begin
    select d.min_y, d.height into v_min_y, v_height from mc.dimension d where d.name = p_dim;
    if not found then raise exception 'unknown dimension %', p_dim; end if;
    v_min_sy := v_min_y >> 4; v_nsec := v_height / 16; v_max_sy := v_min_sy + v_nsec - 1;
    perform mc.light_work_init();

    -- the chunks that take part: the targets and their existing neighbours
    insert into lw_chunk (cx, cz, tgt, top, carry)
    select c.cx, c.cz, c.is_tgt, (select max(s.sy) from mc.chunk_section s where s.dimension = p_dim and s.cx = c.cx and s.cz = c.cz and s.block_count > 0), repeat('0', 256)::bit(256)
      from (select k.cx, k.cz, bool_or(k.is_tgt) as is_tgt
              from (select t.cx + dx as cx, t.cz + dz as cz, (dx = 0 and dz = 0) as is_tgt
                      from (select unnest(p_cxs) as cx, unnest(p_czs) as cz) t, generate_series(-1, 1) dx, generate_series(-1, 1) dz) k
             group by k.cx, k.cz) c
      join mc.chunk ch on ch.dimension = p_dim and ch.cx = c.cx and ch.cz = c.cz;
    if not exists (select 1 from lw_chunk where tgt) then return 0; end if;

    ---------------------------------------------------------------------------------------------------- sky: columns from the top down
    select least(coalesce(max(top), v_min_sy - 1) + 1, v_max_sy + 1) into h from lw_chunk;
    select coalesce(max(i), 0) into base from lw_sec;
    for ly in reverse h .. v_min_sy - 1 loop
        with act as (select c.cx, c.cz, c.carry from lw_chunk c where not c.done),
        m as (
            select a.cx, a.cz, a.carry, s.sy as ssy, mm.op, mm.cl, mm.em_lvl, mm.em_mask, mm.sh
              from act a
              left join mc.chunk_section s on s.dimension = p_dim and s.cx = a.cx and s.cz = a.cz and s.sy = ly and s.block_count > 0
              left join lateral mc.light_secmasks(s.bits, s.data, s.palette) mm on s.sy is not null),
        calc as materialized (
            select m.cx, m.cz, m.ssy, coalesce(m.op, mc.lk_zero()) as op, m.em_lvl, m.em_mask, m.sh,
                   (a4 | repeat(m.carry::text, 16)::bit(4096)) as a
              from m,
                   lateral (select ~coalesce(m.cl, mc.lk_ones()) as q) q,
                   lateral (select q.q | (q.q << 256) as a1) l1,
                   lateral (select a1 | (a1 << 512) as a2) l2,
                   lateral (select a2 | (a2 << 1024) as a3) l3,
                   lateral (select a3 | (a3 << 2048) as a4) l4),
        ins as (
            insert into lw_sec (i, cx, sy, cz, pass, src, em_lvl, em_mask, sh, stored)
            select base + row_number() over (order by c.cx, c.cz), c.cx, ly, c.cz, ~c.op, ~c.a, c.em_lvl, c.em_mask, c.sh, c.ssy is not null from calc c
            returning 1)
        update lw_chunk k set carry = substring(c.a from 1 for 256)::bit(256),
                              done = bit_count(substring(c.a from 1 for 256)) = 256,
                              lowest = case when bit_count(substring(c.a from 1 for 256)) = 256 then ly else k.lowest end
          from calc c where k.cx = c.cx and k.cz = c.cz;
        select coalesce(max(i), 0) into base from lw_sec;
    end loop;
    update lw_chunk set lowest = v_min_sy - 1 where lowest is null;

    -- below the lowest source section of the neighbourhood: one section more (light spreads 14 cells), for the cells that can still be reached
    create temp table if not exists lw_lim (cx int, cz int, lim int, primary key (cx, cz)) on commit delete rows;
    delete from lw_lim;
    insert into lw_lim select c.cx, c.cz, (select min(o.lowest) from lw_chunk o where abs(o.cx - c.cx) <= 1 and abs(o.cz - c.cz) <= 1) - 1 from lw_chunk c;
    select max(lowest) - 1, min(lim) into h, lo from lw_chunk c join lw_lim l using (cx, cz);
    for ly in reverse h .. greatest(lo, v_min_sy - 1) loop
        with act as (select c.cx, c.cz from lw_chunk c join lw_lim l using (cx, cz) where c.lowest > ly and l.lim <= ly),
        m as (
            select a.cx, a.cz, s.sy as ssy, mm.op, mm.em_lvl, mm.em_mask, mm.sh
              from act a
              left join mc.chunk_section s on s.dimension = p_dim and s.cx = a.cx and s.cz = a.cz and s.sy = ly and s.block_count > 0
              left join lateral mc.light_secmasks(s.bits, s.data, s.palette) mm on s.sy is not null)
        insert into lw_sec (i, cx, sy, cz, pass, src, em_lvl, em_mask, sh, stored)
        select base + row_number() over (order by m.cx, m.cz), m.cx, ly, m.cz, ~coalesce(m.op, mc.lk_zero()), null, m.em_lvl, m.em_mask, m.sh, m.ssy is not null from m;
        select coalesce(max(i), 0) into base from lw_sec;
    end loop;

    ---------------------------------------------------------------------------------------------------- block: emitters and what surrounds them
    with em as (
        select s.cx, s.sy, s.cz from mc.chunk_section s join lw_chunk c on c.cx = s.cx and c.cz = s.cz
         where s.dimension = p_dim and s.block_count > 0
           and (cardinality(s.palette) = 0 or exists (select 1 from unnest(s.palette) u(nm) join mc.light_state l on l.name = u.nm and l.emission > 0))),
    nb as (
        select distinct e.cx + dx as cx, e.sy + dy as sy, e.cz + dz as cz from em e, generate_series(-1, 1) dx, generate_series(-1, 1) dy, generate_series(-1, 1) dz),
    new as (
        select nb.cx, nb.sy, nb.cz from nb join lw_chunk c on c.cx = nb.cx and c.cz = nb.cz
         where nb.sy between v_min_sy - 1 and v_max_sy + 1
           and not exists (select 1 from lw_sec x where x.cx = nb.cx and x.sy = nb.sy and x.cz = nb.cz)),
    m as (
        select w.cx, w.sy, w.cz, s.sy as ssy, mm.op, mm.em_lvl, mm.em_mask, mm.sh
          from new w
          left join mc.chunk_section s on s.dimension = p_dim and s.cx = w.cx and s.cz = w.cz and s.sy = w.sy and s.block_count > 0
          left join lateral mc.light_secmasks(s.bits, s.data, s.palette) mm on s.sy is not null)
    insert into lw_sec (i, cx, sy, cz, pass, src, em_lvl, em_mask, sh, stored)
    select base + row_number() over (order by m.cx, m.sy, m.cz), m.cx, m.sy, m.cz, ~coalesce(m.op, mc.lk_zero()), null, m.em_lvl, m.em_mask, m.sh, m.ssy is not null from m;

    perform mc.light_link();

    ---------------------------------------------------------------------------------------------------- waves
    insert into lw_em select s.i, 15, s.src from lw_sec s where s.src is not null and bit_count(s.src) > 0;
    perform mc.light_waves(1);
    delete from lw_em;
    insert into lw_em select s.i, u.l, u.m from lw_sec s, unnest(s.em_lvl, s.em_mask) u(l, m) where s.em_lvl is not null;
    perform mc.light_waves(2);

    ---------------------------------------------------------------------------------------------------- the light rows of the target chunks
    create temp table if not exists lw_ne (cx int, cz int, sy int) on commit delete rows;
    delete from lw_ne;
    insert into lw_ne select s.cx, s.cz, s.sy from mc.chunk_section s join lw_chunk c on c.cx = s.cx and c.cz = s.cz where s.dimension = p_dim and s.block_count > 0;
    create temp table if not exists lw_out (cx int, cz int, idx int, sky_kind text, sky bytea, block_kind text, block bytea) on commit delete rows;
    delete from lw_out;
    insert into lw_out
    select l.cx, l.cz, l.idx,
           case when x.skymax is null then (case when l.sy > l.top then 'data' else 'empty' end) when x.sk0 then 'empty' else 'data' end,
           case when x.skymax is null then (case when l.sy > l.top then mc.light_array_uniform(15) end)
                when x.sk0 then null when x.skfull then mc.light_array_uniform(15) else mc.light_array(x.s3, x.s2, x.s1, x.s0) end,
           case when x.blmax is null or x.bl0 then 'empty' else 'data' end,
           case when x.blmax is null or x.bl0 then null when x.blfull then mc.light_array_uniform(15) else mc.light_array(x.b3, x.b2, x.b1, x.b0) end
      from (select c.cx, c.cz, g.idx, v_min_sy + g.idx - 1 as sy, c.top from lw_chunk c, generate_series(0, v_nsec + 1) g(idx) where c.tgt) l
      left join lw_sec s on s.cx = l.cx and s.cz = l.cz and s.sy = l.sy
      left join lw_run rs on rs.kind = 1 and rs.i = s.i
      left join lw_run rb on rb.kind = 2 and rb.i = s.i
      left join lateral (
          select rs.i as skymax, bit_count(rs.c0 | rs.c1 | rs.c2 | rs.c3) = 0 as sk0, bit_count(rs.c0 & rs.c1 & rs.c2 & rs.c3) = 4096 as skfull,
                 rs.c3 as s3, rs.c2 as s2, rs.c1 as s1, rs.c0 as s0,
                 rb.i as blmax, bit_count(rb.c0 | rb.c1 | rb.c2 | rb.c3) = 0 as bl0, bit_count(rb.c0 & rb.c1 & rb.c2 & rb.c3) = 4096 as blfull,
                 rb.c3 as b3, rb.c2 as b2, rb.c1 as b1, rb.c0 as b0) x on true
     where exists (select 1 from lw_ne n where n.cx between l.cx - 1 and l.cx + 1 and n.cz between l.cz - 1 and l.cz + 1 and n.sy between l.sy - 1 and l.sy + 1);
    if p_sky0_as_data then
        update lw_out set sky_kind = 'data', sky = decode(repeat('00', 2048), 'hex') where idx = 0;
    end if;

    delete from mc.chunk_light l using lw_chunk c
     where c.tgt and l.dimension = p_dim and l.cx = c.cx and l.cz = c.cz and not exists (select 1 from lw_out o where o.cx = l.cx and o.cz = l.cz and o.idx = l.idx);
    insert into mc.chunk_light as l (dimension, cx, cz, idx, sky_kind, sky, block_kind, block)
    select p_dim, o.cx, o.cz, o.idx, o.sky_kind, o.sky, o.block_kind, o.block from lw_out o
    on conflict (dimension, cx, cz, idx) do update set sky_kind = excluded.sky_kind, sky = excluded.sky, block_kind = excluded.block_kind, block = excluded.block
     where (l.sky_kind, l.sky, l.block_kind, l.block) is distinct from (excluded.sky_kind, excluded.sky, excluded.block_kind, excluded.block);
    get diagnostics wrote = row_count;
    update mc.chunk k set light_ws = null, light_top = null from lw_chunk c where c.tgt and k.dimension = p_dim and k.cx = c.cx and k.cz = c.cz;
    return wrote;
end $$;
