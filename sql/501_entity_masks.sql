-- Block collision lookup for entities: per-section solidity bitmasks (mc.solid_mask), built lazily and rebuilt when the chunk's version moved.
-- A cell test is get_bit(mask, ((y & 15) * 16 + (z & 15)) * 16 + (x & 15)); a section with solid_cnt = 0 needs no cell tests at all.

create or replace function mc.state_solid(p_state int) returns boolean language sql stable as $$
  select coalesce((select bc.solid from ref.block_state s join mc.block_class bc on bc.name = s.block where s.state_id = p_state), false) $$;

create or replace function mc.cell_friction(p_dim text, x int, y int, z int) returns real language sql stable as $$
  select coalesce((select bc.friction from mc.block_class bc where bc.name = split_part(mc.get_block(p_dim, x, y, z), '[', 1)), 0.6::real) $$;

-- (Re)build the mask of one section.  A missing chunk or section is stored as "all passable" with ver = -1 so the lookup does not repeat.
create or replace function mc.entity_build_mask(p_dim text, p_cx int, p_cz int, p_sy int) returns void language plpgsql volatile as $$
declare s mc.chunk_section; v bigint; sol int[]; idx int[]; m bytea; cnt int; slip boolean := false; zero bytea := decode(repeat('00', 512), 'hex');
begin
    select c.version into v from mc.chunk c where c.dimension = p_dim and c.cx = p_cx and c.cz = p_cz;
    select * into s from mc.chunk_section t where t.dimension = p_dim and t.cx = p_cx and t.cz = p_cz and t.sy = p_sy;
    if v is null or s.dimension is null then
        insert into mc.solid_mask (dimension, cx, cz, sy, ver, solid_cnt, slippery, mask) values (p_dim, p_cx, p_cz, p_sy, coalesce(v, -1), 0, false, zero)
        on conflict (dimension, cx, cz, sy) do update set ver = excluded.ver, solid_cnt = 0, slippery = false, mask = excluded.mask;
        return;
    end if;
    if cardinality(s.palette) > 0 then
        select array_agg(case when coalesce(bc.solid, false) then 1 else 0 end order by u.ord), coalesce(bool_or(coalesce(bc.friction, 0.6::real) <> 0.6::real), false)
          into sol, slip
          from unnest(s.palette) with ordinality u(nm, ord) left join mc.block_class bc on bc.name = split_part(u.nm, '[', 1);
    end if;
    if s.bits = 0 then
        cnt := sol[1] * 4096;
        m := decode(repeat(case when sol[1] = 1 then 'ff' else '00' end, 512), 'hex');
    else
        idx := mc.unpack_longs(s.data, s.bits, 4096);
        if cardinality(s.palette) > 0 then
            select decode(string_agg(lpad(to_hex(q.bv), 2, '0'), '' order by q.b), 'hex'), sum(q.bits)::int into m, cnt
              from (select b, sum(sol[idx[b * 8 + k + 1] + 1] << k) as bv, sum(sol[idx[b * 8 + k + 1] + 1]) as bits
                      from generate_series(0, 511) b, generate_series(0, 7) k group by b) q;
        else                                    -- global palette: entries are state ids (rare)
            select decode(string_agg(lpad(to_hex(q.bv), 2, '0'), '' order by q.b), 'hex'), sum(q.bits)::int into m, cnt
              from (select b, sum((case when mc.state_solid(idx[b * 8 + k + 1]) then 1 else 0 end) << k) as bv, sum(case when mc.state_solid(idx[b * 8 + k + 1]) then 1 else 0 end) as bits
                      from generate_series(0, 511) b, generate_series(0, 7) k group by b) q;
        end if;
    end if;
    insert into mc.solid_mask (dimension, cx, cz, sy, ver, solid_cnt, slippery, mask) values (p_dim, p_cx, p_cz, p_sy, v, cnt, slip, m)
    on conflict (dimension, cx, cz, sy) do update set ver = excluded.ver, solid_cnt = excluded.solid_cnt, slippery = excluded.slippery, mask = excluded.mask;
end $$;

-- The integer cell box swept by an entity moving by (vx, vy, vz): [x0..x1] x [y0..y1] x [z0..z1], with the 1e-7 epsilon of vanilla's collision code.
create or replace function mc.entity_sweep(x float8, y float8, z float8, vx float8, vy float8, vz float8, hw float8, h float8,
                                           out x0 int, out x1 int, out y0 int, out y1 int, out z0 int, out z1 int) language sql immutable parallel safe as $$
  select floor(least(x - hw, x - hw + vx) + 1e-7)::int, floor(greatest(x + hw, x + hw + vx) - 1e-7)::int,
         floor(least(y, y + vy) + 1e-7)::int,           floor(greatest(y + h, y + h + vy) - 1e-7)::int,
         floor(least(z - hw, z - hw + vz) + 1e-7)::int, floor(greatest(z + hw, z + hw + vz) - 1e-7)::int $$;
