-- World: generation, reads, edits (set_block / set_blocks / fill), chunk payloads and packets, hashing and analytics.
-- Edits are one read-modify-write per section (dbcraft's edit_section / fill_section): in place on the packed bytes when the palette index exists and
-- the bit width does not change, a set-based repack only when the palette outgrows the width.

create function mc.reset_world() returns void language sql as $$
  truncate mc.chunk, mc.chunk_section, mc.chunk_cache, mc.block_event restart identity $$;

------------------------------------------------------------------------------------------------ generation
-- 256 column heights once, then each section's 4096 states set-based, packed with bit_or / int8send / string_agg (no per-entry loop).
-- Sections above max(highest column, sea level 62) are all air: palette [0], bits 0, no data, no per-block work.
create function mc.gen_chunk(cx int, cz int) returns void language plpgsql as $$
declare
    hs  int[];
    top int;
begin
    if exists (select 1 from mc.chunk c where c.cx = gen_chunk.cx and c.cz = gen_chunk.cz) then return; end if;
    hs  := mc.chunk_heights(cx, cz);
    top := least(19, greatest((select max(h) from unnest(hs) h), 62) >> 4);
    insert into mc.chunk (cx, cz, version) values (cx, cz, 0);
    insert into mc.chunk_section (cx, cz, sy, block_count, palette, bits, data)
    with blk as materialized (
        select sy, i,
               case when y = -64 then 4
                    when y > h then case when y <= 62 then 6 else 0 end
                    when y = h then case when h <= 63 then 5 else 2 end
                    when y >= h - 3 then case when h <= 63 then 5 when y = h - 1 and (mc.hash2(x, z, 7) & 31) = 0 then 14 else 3 end
                    else mc.ore(r, y) end as st
          from (select sy, i, x, y, z, h, case when y > -64 and y < h - 3 then mc.ore_r(x, y, z) end as r
                  from generate_series(3, top) sy, generate_series(0, 4095) i,
                       lateral (select sy * 16 + (i >> 8) as y, gen_chunk.cx * 16 + (i & 15) as x, gen_chunk.cz * 16 + ((i >> 4) & 15) as z,
                                       hs[((i >> 4) & 15) * 16 + (i & 15) + 1] as h) c
                offset 0) q),
    -- sections -4 .. 2 lie entirely in the stone zone (heights are >= 52, so y <= 47 < h - 3) except the bedrock layer: every block is stone (1, the smallest
    -- palette entry, index 0, so the packed data is all zeros) except the ~0.4% ore rolls and the 256 bedrock blocks; only those are generated and patched in
    hit as materialized (
        select sy, i, st from (
            select sy, i, case when r is null then 4 else mc.ore(r, y) end as st
              from (select sy, i, y, case when sy = -4 and i < 256 then null else mc.ore_r(x, y, z) end as r
                      from generate_series(-4, 2) sy, generate_series(0, 4095) i,
                           lateral (select sy * 16 + (i >> 8) as y, gen_chunk.cx * 16 + (i & 15) as x, gen_chunk.cz * 16 + ((i >> 4) & 15) as z) c
                    offset 0) q) d
         where st <> 1),
    pal2 as (select sy, array_agg(st order by st) as pal from (select sy, 1 as st from generate_series(-4, 2) sy union select sy, st from hit) u group by sy),
    lng2 as (select h.sy, h.i / 16 as k, bit_or((array_position(p.pal, h.st) - 1)::bigint << ((h.i % 16) * 4)) as w
               from hit h join pal2 p using (sy) where cardinality(p.pal) > 1 group by 1, 2),
    dat2 as (select p.sy, string_agg(int8send(coalesce(l.w, 0)), ''::bytea order by k.k) as data
               from pal2 p cross join generate_series(0, 255) k(k) left join lng2 l on l.sy = p.sy and l.k = k.k
              where cardinality(p.pal) > 1 group by p.sy),
    pm  as (select sy, bit_or(1 << st) as mask, count(*) filter (where st <> 0) as bc from blk group by sy),
    pb  as (select sy, bc, pal, mc.bits_for(cardinality(pal)) as bits
              from (select sy, bc, array(select s from generate_series(0, 31) s where (mask >> s) & 1 = 1) as pal from pm) q),
    lng as materialized (
            select b.sy, b.i / (64 / p.bits) as k,
                   bit_or((array_position(p.pal, b.st) - 1)::bigint << ((b.i % (64 / p.bits)) * p.bits)) as w
              from blk b join pb p using (sy) where p.bits > 0 group by 1, 2),
    dat as (select sy, string_agg(int8send(w), ''::bytea order by k) as data from lng group by sy)
    select gen_chunk.cx, gen_chunk.cz, p.sy, p.bc, p.pal, p.bits, coalesce(d.data, '\x'::bytea) from pb p left join dat d using (sy)
    union all
    select gen_chunk.cx, gen_chunk.cz, p.sy, 4096, p.pal, mc.bits_for(cardinality(p.pal)), coalesce(d.data, '\x'::bytea) from pal2 p left join dat2 d using (sy)
    union all
    select gen_chunk.cx, gen_chunk.cz, sy, 0, array[0], 0, '\x'::bytea from generate_series(top + 1, 19) sy;
end $$;

create function mc.gen_area(cx0 int, cz0 int, cx1 int, cz1 int) returns int language plpgsql as $$
declare
    n int := 0; x int; z int;
begin
    for x in cx0 .. cx1 loop
        for z in cz0 .. cz1 loop
            if not exists (select 1 from mc.chunk c where c.cx = x and c.cz = z) then
                perform mc.gen_chunk(x, z);
                n := n + 1;
            end if;
        end loop;
    end loop;
    return n;
end $$;

------------------------------------------------------------------------------------------------ reads
create function mc.get_block(x int, y int, z int) returns int language sql stable parallel safe as $$
  select case when y < -64 or y > 319 then 0 else coalesce(
    (select mc.state_at(s.palette, s.bits, s.data, ((y & 15) << 8) | ((z & 15) << 4) | (x & 15))
       from mc.chunk_section s where s.cx = x >> 4 and s.cz = z >> 4 and s.sy = y >> 4), 0) end $$;

------------------------------------------------------------------------------------------------ edits
-- A palette index must already exist or is appended; the bit width grows only when the palette exceeds 2^bits (or from a single-value section).
create function mc.set_block(x int, y int, z int, state int) returns boolean language plpgsql as $$
declare
    v_pal  int[];
    v_bits int;
    v_data bytea;
    v_bc   int;
    v_idx  int := ((y & 15) << 8) | ((z & 15) << 4) | (x & 15);
    v_old  int;
    v_pi   int;
begin
    if y < -64 or y > 319 then return false; end if;
    select s.palette, s.bits, s.data, s.block_count into v_pal, v_bits, v_data, v_bc
      from mc.chunk_section s where s.cx = x >> 4 and s.cz = z >> 4 and s.sy = y >> 4;
    if not found then return false; end if;
    if v_bits = 0 then
        v_old := v_pal[1];
        if v_old = state then return false; end if;
        v_pal := v_pal || state;
        v_bits := 4;
        v_data := mc.entry_put(4, decode(repeat('00', 2048), 'hex'), v_idx, 1);
    else
        v_old := v_pal[1 + mc.entry_get(v_bits, v_data, v_idx)];
        if v_old = state then return false; end if;
        v_pi := array_position(v_pal, state);
        if v_pi is null then
            v_pal := v_pal || state;
            v_pi := cardinality(v_pal);
            if v_pi > (1 << v_bits) then
                v_data := mc.pack_entries(mc.unpack(v_bits, v_data), v_bits + 1);
                v_bits := v_bits + 1;
            end if;
        end if;
        v_data := mc.entry_put(v_bits, v_data, v_idx, v_pi - 1);
    end if;
    update mc.chunk_section s
       set block_count = v_bc + (case when state <> 0 then 1 else 0 end) - (case when v_old <> 0 then 1 else 0 end),
           palette = v_pal, bits = v_bits, data = v_data
     where s.cx = x >> 4 and s.cz = z >> 4 and s.sy = y >> 4;
    update mc.chunk c set version = c.version + 1 where c.cx = x >> 4 and c.cz = z >> 4;
    insert into mc.block_event (kind, x, y, z, old_state, new_state) values ('block', x, y, z, v_old, state);
    return true;
end $$;

-- Bulk form: edits applied in array order, every section read and written once, one version bump per chunk, events in array order.
create function mc.set_blocks(xs int[], ys int[], zs int[], states int[]) returns int language plpgsql as $$
declare
    g      record;
    n      int;
    v_pal  int[];
    v_bits int;
    v_data bytea;
    v_bc   int;
    v_idx  int;
    v_old  int;
    v_pi   int;
    v_st   int;
    v_dirty boolean;
    changed int := 0;
    ev_n   int[];
    ev_old int[];
    last_cx int; last_cz int;
    zero4  constant bytea := decode(repeat('00', 2048), 'hex');
begin
    for g in
        select t.cx, t.cz, t.sy, array_agg(t.n order by t.n) as ns
          from (select u.n::int as n, u.x >> 4 as cx, u.z >> 4 as cz, u.y >> 4 as sy
                  from unnest(xs, ys, zs) with ordinality u(x, y, z, n)) t
         group by t.cx, t.cz, t.sy order by t.cx, t.cz, t.sy
    loop
        select s.palette, s.bits, s.data, s.block_count into v_pal, v_bits, v_data, v_bc
          from mc.chunk_section s where s.cx = g.cx and s.cz = g.cz and s.sy = g.sy;
        if not found then continue; end if;
        v_dirty := false;
        foreach n in array g.ns loop
            v_st  := states[n];
            v_idx := ((ys[n] & 15) << 8) | ((zs[n] & 15) << 4) | (xs[n] & 15);
            if v_bits = 0 then
                v_old := v_pal[1];
                if v_old = v_st then continue; end if;
                v_pal := v_pal || v_st;
                v_bits := 4;
                v_data := mc.entry_put(4, zero4, v_idx, 1);
            else
                v_old := v_pal[1 + mc.entry_get(v_bits, v_data, v_idx)];
                if v_old = v_st then continue; end if;
                v_pi := array_position(v_pal, v_st);
                if v_pi is null then
                    v_pal := v_pal || v_st;
                    v_pi := cardinality(v_pal);
                    if v_pi > (1 << v_bits) then
                        v_data := mc.pack_entries(mc.unpack(v_bits, v_data), v_bits + 1);
                        v_bits := v_bits + 1;
                    end if;
                end if;
                v_data := mc.entry_put(v_bits, v_data, v_idx, v_pi - 1);
            end if;
            v_bc := v_bc + (case when v_st <> 0 then 1 else 0 end) - (case when v_old <> 0 then 1 else 0 end);
            v_dirty := true;
            changed := changed + 1;
            ev_n[changed] := n;
            ev_old[changed] := v_old;
        end loop;
        if v_dirty then
            update mc.chunk_section s set block_count = v_bc, palette = v_pal, bits = v_bits, data = v_data
             where s.cx = g.cx and s.cz = g.cz and s.sy = g.sy;
            if last_cx is distinct from g.cx or last_cz is distinct from g.cz then
                update mc.chunk c set version = c.version + 1 where c.cx = g.cx and c.cz = g.cz;
                last_cx := g.cx; last_cz := g.cz;
            end if;
        end if;
    end loop;
    if changed > 0 then
        insert into mc.block_event (kind, x, y, z, old_state, new_state)
        select 'block', xs[u.n], ys[u.n], zs[u.n], u.o, states[u.n] from unnest(ev_n, ev_old) u(n, o) order by u.n;
    end if;
    return changed;
end $$;

-- Fill of a box (section-local, inclusive) in one section.  Whole section: collapses to [state], bits 0 (only if something changes).
-- Partial: counts the changed entries first (a no-op leaves the palette alone), then rewrites the section set-based.
create type mc.fill_result as (n int, bc int, pal int[], bits int, data bytea);

create function mc.fill_section(p_bc int, p_bits int, p_pal int[], p_data bytea, lx0 int, lx1 int, ly0 int, ly1 int, lz0 int, lz1 int, p_state int)
returns mc.fill_result language plpgsql immutable parallel safe as $$
declare
    v_pi   int := array_position(p_pal, p_state);     -- 1-based, null when the state is not in the palette
    v_ent  int[];
    v_n    int;
    v_na   int;
    v_hex  text;
    v_bits int := p_bits;
    v_pal  int[] := p_pal;
begin
    if lx0 = 0 and lx1 = 15 and ly0 = 0 and ly1 = 15 and lz0 = 0 and lz1 = 15 then
        if v_pi is null then v_n := 4096;
        elsif p_bits = 0 then v_n := 0;
        elsif p_bits = 4 then                          -- nibbles are hex digits: count them in C
            v_hex := encode(p_data, 'hex');
            v_n := 4096 - (length(v_hex) - length(replace(v_hex, to_hex(v_pi - 1), '')));
        else
            v_n := 4096 - (select count(*) from unnest(mc.unpack(p_bits, p_data)) e where e = v_pi - 1);
        end if;
        if v_n = 0 then return (0, p_bc, p_pal, p_bits, p_data)::mc.fill_result; end if;
        return (v_n, case when p_state <> 0 then 4096 else 0 end, array[p_state], 0, '\x'::bytea)::mc.fill_result;
    end if;
    v_ent := mc.unpack(p_bits, p_data);
    select count(*) filter (where p_pal[e + 1] <> p_state), count(*) filter (where p_pal[e + 1] <> p_state and p_pal[e + 1] <> 0)
      into v_n, v_na
      from unnest(v_ent) with ordinality t(e, i)
     where ((i - 1) & 15) between lx0 and lx1 and (((i - 1) >> 4) & 15) between lz0 and lz1 and (((i - 1) >> 8) & 15) between ly0 and ly1;
    if v_n = 0 then return (0, p_bc, p_pal, p_bits, p_data)::mc.fill_result; end if;
    if v_pi is null then
        v_pal := v_pal || p_state;
        v_pi := cardinality(v_pal);
        if p_bits = 0 then v_bits := 4;
        elsif v_pi > (1 << p_bits) then v_bits := p_bits + 1;
        end if;
    end if;
    v_ent := array(select case when ((i - 1) & 15) between lx0 and lx1 and (((i - 1) >> 4) & 15) between lz0 and lz1 and (((i - 1) >> 8) & 15) between ly0 and ly1
                               then v_pi - 1 else e end
                     from unnest(v_ent) with ordinality t(e, i));
    return (v_n, p_bc + (case when p_state <> 0 then v_n else 0 end) - v_na, v_pal, v_bits, mc.pack_entries(v_ent, v_bits))::mc.fill_result;
end $$;

create function mc.fill(x1 int, y1 int, z1 int, x2 int, y2 int, z2 int, state int) returns int language plpgsql as $$
declare
    xa int := least(x1, x2);               xb int := greatest(x1, x2);
    ya int := greatest(-64, least(y1, y2)); yb int := least(319, greatest(y1, y2));
    za int := least(z1, z2);               zb int := greatest(z1, z2);
    s record;
    r mc.fill_result;
    ox int; oy int; oz int;
    total int := 0;
    last_cx int; last_cz int;
begin
    if ya > yb then return 0; end if;
    for s in select t.cx, t.cz, t.sy, t.block_count, t.palette, t.bits, t.data from mc.chunk_section t
              where t.cx between xa >> 4 and xb >> 4 and t.cz between za >> 4 and zb >> 4 and t.sy between ya >> 4 and yb >> 4
              order by t.cx, t.cz, t.sy
    loop
        ox := greatest(xa, s.cx * 16); oy := greatest(ya, s.sy * 16); oz := greatest(za, s.cz * 16);
        r := mc.fill_section(s.block_count, s.bits, s.palette, s.data,
                             ox - s.cx * 16, least(xb, s.cx * 16 + 15) - s.cx * 16, oy - s.sy * 16, least(yb, s.sy * 16 + 15) - s.sy * 16,
                             oz - s.cz * 16, least(zb, s.cz * 16 + 15) - s.cz * 16, state);
        if r.n > 0 then
            update mc.chunk_section u set block_count = r.bc, palette = r.pal, bits = r.bits, data = r.data
             where u.cx = s.cx and u.cz = s.cz and u.sy = s.sy;
            insert into mc.block_event (kind, x, y, z, old_state, new_state, cnt) values ('fill', ox, oy, oz, -1, state, r.n);
            total := total + r.n;
            if last_cx is distinct from s.cx or last_cz is distinct from s.cz then
                update mc.chunk c set version = c.version + 1 where c.cx = s.cx and c.cz = s.cz;
                last_cx := s.cx; last_cz := s.cz;
            end if;
        end if;
    end loop;
    return total;
end $$;

------------------------------------------------------------------------------------------------ chunk payload / packet / hash
create function mc.chunk_payload(cx int, cz int) returns bytea language sql stable parallel safe as $$
  select string_agg(mc.section_blob(s.block_count, s.bits, s.palette, s.data), ''::bytea order by s.sy)
    from mc.chunk_section s where s.cx = chunk_payload.cx and s.cz = chunk_payload.cz $$;

create function mc.chunk_packet(cx int, cz int) returns bytea language plpgsql as $$
declare
    v    bigint;
    pk   bytea;
    body bytea;
begin
    select c.version, k.packet into v, pk
      from mc.chunk c left join mc.chunk_cache k on k.cx = c.cx and k.cz = c.cz and k.version = c.version
     where c.cx = chunk_packet.cx and c.cz = chunk_packet.cz;
    if not found then return null; end if;
    if pk is not null then return pk; end if;
    body := '\x2c'::bytea || int4send(cx) || int4send(cz) || mc.chunk_payload(cx, cz);
    pk := mc.varint(length(body)) || body;
    insert into mc.chunk_cache (cx, cz, version, packet) values (cx, cz, v, pk)
    on conflict on constraint chunk_cache_pkey do update set version = excluded.version, packet = excluded.packet;
    return pk;
end $$;

create function mc.world_hash() returns bytea language sql stable as $$
  select sha256(coalesce(string_agg(int4send(s.cx) || int4send(s.cz) || int2send(s.sy::int2)
                                    || mc.section_blob(s.block_count, s.bits, s.palette, s.data), ''::bytea order by s.cx, s.cz, s.sy), '\x'::bytea))
    from mc.chunk_section s $$;

------------------------------------------------------------------------------------------------ analytics
-- block counts of one section restricted to the local column rectangle [lx0..lx1] x [lz0..lz1] (all y)
create function mc.sec_count(p_bits int, p_pal int[], p_data bytea, lx0 int, lx1 int, lz0 int, lz1 int) returns table(st int, n int)
language plpgsql immutable parallel safe as $$
declare v_hex text;
begin
    if p_bits = 0 then
        return query select p_pal[1], (lx1 - lx0 + 1) * (lz1 - lz0 + 1) * 16;
    elsif p_bits = 4 and lx0 = 0 and lx1 = 15 and lz0 = 0 and lz1 = 15 then
        v_hex := encode(p_data, 'hex');                -- whole section: count hex digits (= entries) per palette index
        return query select p_pal[v + 1], length(v_hex) - length(replace(v_hex, to_hex(v), ''))
                       from generate_series(0, cardinality(p_pal) - 1) v;
    else
        return query select p_pal[e + 1], count(*)::int
                       from unnest(mc.unpack(p_bits, p_data)) with ordinality t(e, i)
                      where ((i - 1) & 15) between lx0 and lx1 and (((i - 1) >> 4) & 15) between lz0 and lz1 group by 1;
    end if;
end $$;

create function mc.count_states(x1 int, z1 int, x2 int, z2 int) returns table(state int, n bigint) language sql stable parallel safe as $$
  select t.st, sum(t.n)::bigint
    from mc.chunk_section s,
         lateral mc.sec_count(s.bits, s.palette, s.data,
                              greatest(least(x1, x2), s.cx * 16) - s.cx * 16, least(greatest(x1, x2), s.cx * 16 + 15) - s.cx * 16,
                              greatest(least(z1, z2), s.cz * 16) - s.cz * 16, least(greatest(z1, z2), s.cz * 16 + 15) - s.cz * 16) t
   where s.cx between least(x1, x2) >> 4 and greatest(x1, x2) >> 4 and s.cz between least(z1, z2) >> 4 and greatest(z1, z2) >> 4
   group by t.st having sum(t.n) > 0 order by t.st $$;

create function mc.find_state(p_state int, x1 int, z1 int, x2 int, z2 int) returns table(x int, y int, z int) language sql stable parallel safe as $$
  select s.cx * 16 + ((t.i - 1) & 15), s.sy * 16 + ((t.i - 1) >> 8), s.cz * 16 + (((t.i - 1) >> 4) & 15)
    from mc.chunk_section s, lateral unnest(mc.unpack(s.bits, s.data)) with ordinality t(e, i)
   where s.cx between least(x1, x2) >> 4 and greatest(x1, x2) >> 4 and s.cz between least(z1, z2) >> 4 and greatest(z1, z2) >> 4
     and s.palette @> array[p_state] and s.palette[t.e + 1] = p_state
     and s.cx * 16 + ((t.i - 1) & 15) between least(x1, x2) and greatest(x1, x2)
     and s.cz * 16 + (((t.i - 1) >> 4) & 15) between least(z1, z2) and greatest(z1, z2)
   order by 1, 2, 3 $$;

create function mc.drain_block_events() returns table(id bigint, kind text, x int, y int, z int, old_state int, new_state int, cnt int)
language sql as $$
  with d as (delete from mc.block_event returning *)
  select d.id, d.kind, d.x, d.y, d.z, d.old_state, d.new_state, d.cnt from d order by d.id $$;
