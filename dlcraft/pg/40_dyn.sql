-- Dynamics: scheduled water ticks and random (grass) ticks.  Both read the PRE-step world set-based (one section fetch per distinct section, then a hash join of
-- positions against those sections), decide in SQL, and apply with one mc.set_blocks call.

create function mc.reset_sched() returns void language sql as $$ truncate mc.sched $$;
create function mc.sched_add(due bigint, x int, y int, z int) returns void language sql as $$
  insert into mc.sched (due, x, y, z) values (due, x, y, z) $$;
create function mc.sched_add_bulk(due bigint, xs int[], ys int[], zs int[]) returns void language sql as $$
  insert into mc.sched (due, x, y, z) select due, t.x, t.y, t.z from unnest(xs, ys, zs) as t(x, y, z) $$;
create function mc.sched_size() returns bigint language sql stable as $$ select count(*) from mc.sched $$;

-- SPEC 7.  Water at level L (state 6 + L) spreads to horizontal air neighbours at L + 1 (while <= 7) and falls into air below as level 1;
-- every candidate keeps its minimum level; candidates are set in (x, z, y) order and rescheduled for now + 5.
-- An ungenerated chunk reads as air, so such a candidate is still rescheduled (set_blocks skips it): SPEC 7 does not exempt it.
create function mc.dyn_step(p_now bigint) returns int language plpgsql as $$
declare
    xs int[]; ys int[]; zs int[]; sts int[];
    changed int := 0;
begin
    with d as (delete from mc.sched where due <= p_now returning x, y, z),
         dd as materialized (select distinct x, y, z from d),
         need as materialized (
            select x, y, z from dd
            union select x + 1, y, z from dd
            union select x - 1, y, z from dd
            union select x, y, z + 1 from dd
            union select x, y, z - 1 from dd
            union select x, y - 1, z from dd where y > -64),
         nk as materialized (
            select x, y, z, x >> 4 as cx, z >> 4 as cz, y >> 4 as sy, ((y & 15) << 8) | ((z & 15) << 4) | (x & 15) as idx from need),
         secs as materialized (
            select s.cx, s.cz, s.sy, s.palette, s.bits, s.data
              from mc.chunk_section s join (select distinct cx, cz, sy from nk) k on k.cx = s.cx and k.cz = s.cz and k.sy = s.sy),
         st as materialized (
            select nk.x, nk.y, nk.z, coalesce(mc.state_at(s.palette, s.bits, s.data, nk.idx), 0) as state
              from nk left join secs s on s.cx = nk.cx and s.cz = nk.cz and s.sy = nk.sy),
         water as (select dd.x, dd.y, dd.z, st.state - 6 as lvl from dd join st on st.x = dd.x and st.y = dd.y and st.z = dd.z
                    where st.state between 6 and 13),
         cand as (
            select w.x + o.dx as x, w.y as y, w.z + o.dz as z, w.lvl + 1 as lvl
              from water w cross join (values (1, 0), (-1, 0), (0, 1), (0, -1)) o(dx, dz) where w.lvl + 1 <= 7
            union all
            select w.x, w.y - 1, w.z, 1 from water w where w.y > -64),
         best as (select c.x, c.y, c.z, min(c.lvl) as lvl
                    from cand c join st on st.x = c.x and st.y = c.y and st.z = c.z where st.state = 0 group by c.x, c.y, c.z)
    select array_agg(x order by x, z, y), array_agg(y order by x, z, y), array_agg(z order by x, z, y), array_agg(6 + lvl order by x, z, y)
      into xs, ys, zs, sts from best;
    if xs is null then return 0; end if;
    changed := mc.set_blocks(xs, ys, zs, sts);
    insert into mc.sched (due, x, y, z) select p_now + 5, t.x, t.y, t.z from unnest(xs, ys, zs) as t(x, y, z);
    return changed;
end $$;

-- SPEC 7 random ticks: 3 picks per non-empty section of the chunk rectangle; a dirt block with air above and a horizontal grass neighbour becomes grass.
create function mc.random_ticks(p_now bigint, cx0 int, cz0 int, cx1 int, cz1 int) returns int language plpgsql as $$
declare
    xs int[]; ys int[]; zs int[];
    changed int := 0;
begin
    with picks as materialized (
            select s.cx, s.cz, s.sy, k.k, s.cx * 16 + (h.i & 15) as x, s.sy * 16 + (h.i >> 8) as y, s.cz * 16 + ((h.i >> 4) & 15) as z
              from mc.chunk_section s cross join generate_series(0, 2) k(k),
                   lateral (select mc.hash2((s.cx * 64 + s.sy + 4)::bigint, s.cz::bigint, p_now * 3 + k.k) & 4095 as i) h
             where s.cx between least(cx0, cx1) and greatest(cx0, cx1) and s.cz between least(cz0, cz1) and greatest(cz0, cz1) and s.block_count > 0),
         need as materialized (
            select x, y, z from picks
            union select x, y + 1, z from picks
            union select x + 1, y, z from picks union select x - 1, y, z from picks
            union select x, y, z + 1 from picks union select x, y, z - 1 from picks),
         nk as materialized (
            select x, y, z, x >> 4 as cx, z >> 4 as cz, y >> 4 as sy, ((y & 15) << 8) | ((z & 15) << 4) | (x & 15) as idx from need),
         secs as materialized (
            select s.cx, s.cz, s.sy, s.palette, s.bits, s.data
              from mc.chunk_section s join (select distinct cx, cz, sy from nk) k on k.cx = s.cx and k.cz = s.cz and k.sy = s.sy),
         st as materialized (
            select nk.x, nk.y, nk.z, coalesce(mc.state_at(s.palette, s.bits, s.data, nk.idx), 0) as state
              from nk left join secs s on s.cx = nk.cx and s.cz = nk.cz and s.sy = nk.sy),
         hit as (
            select p.cx, p.cz, p.sy, p.k, p.x, p.y, p.z
              from picks p
              join st c on c.x = p.x and c.y = p.y and c.z = p.z and c.state = 3
              join st u on u.x = p.x and u.y = p.y + 1 and u.z = p.z and u.state = 0
             where exists (select 1 from st n where n.state = 2 and n.y = p.y
                              and ((n.x = p.x + 1 and n.z = p.z) or (n.x = p.x - 1 and n.z = p.z) or (n.x = p.x and n.z = p.z + 1) or (n.x = p.x and n.z = p.z - 1)))),
         ord as (select h.*, row_number() over (order by h.cx, h.cz, h.sy, h.k) as o from hit h)
    select array_agg(x order by o), array_agg(y order by o), array_agg(z order by o) into xs, ys, zs from ord;
    if xs is null then return 0; end if;
    return mc.set_blocks(xs, ys, zs, array_fill(2, array[cardinality(xs)]));
end $$;
