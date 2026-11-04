-- Entity physics: ONE set-based statement per tick for all awake entities.  A port of tools/entity/model.py, which reproduces vanilla 26.3's ItemEntity
-- (read from the bytecode of ItemEntity.tick / Entity.move) exactly on four recorded per-tick trajectories (docs/ENTITY.md).
--
-- Per tick and entity:  vy -= gravity; move (axis order Y, then X before Z if |vx| >= |vz| else Z before X; each axis clipped by solid unit cells; the collided movement is applied
-- only if its squared length is above 1e-7; a clipped axis zeroes its velocity component; on_ground = vertical movement clipped while moving down);
-- items then apply drag 0.98F (0.6F * 0.98F on the ground) horizontally and 0.98F vertically, and bounce -0.5 if on the ground moving down.
-- Items at rest skip the move and the drag (vanilla wakes them every 4th tick, when (age + id) % 4 = 0; gravity accumulates meanwhile: here it is added lazily from phys_tick);
-- once an item is supported and its horizontal speed is below the movement threshold it goes to DEEP SLEEP and costs nothing until a block changes next to it.

-- ordinary (unblocked) movement, the same rules as the collision function with no blockers
create or replace function mc.entity_move_free(px float8, py float8, pz float8, vx float8, vy float8, vz float8)
returns table (nx float8, ny float8, nz float8, nvx float8, nvy float8, nvz float8, og boolean) language sql immutable parallel safe rows 1 as $$
  select case when g.s > 1e-7 then px + g.gx else px end, case when g.s > 1e-7 then py + g.gy else py end, case when g.s > 1e-7 then pz + g.gz else pz end,
         case when g.gx <> vx then 0::float8 else vx end, case when g.gy <> vy then 0::float8 else vy end, case when g.gz <> vz then 0::float8 else vz end,
         (g.gy <> vy) and vy < 0
  from (select q.gx, q.gy, q.gz, q.gx * q.gx + q.gy * q.gy + q.gz * q.gz as s
          from (select case when abs(vx) < 1e-7 then 0::float8 else vx end as gx, case when abs(vy) < 1e-7 then 0::float8 else vy end as gy,
                       case when abs(vz) < 1e-7 then 0::float8 else vz end as gz) q) g
$$;

-- movement against solid unit cells (bxs/bys/bzs: the solid cells of the swept box)
create or replace function mc.entity_move(px float8, py float8, pz float8, vx float8, vy float8, vz float8, hw float8, h float8, bxs int[], bys int[], bzs int[],
    out nx float8, out ny float8, out nz float8, out nvx float8, out nvy float8, out nvz float8, out og boolean) language plpgsql immutable parallel safe as $$
declare n int := coalesce(cardinality(bxs), 0);
        lo float8[] := array[px - hw, py, pz - hw]; hi float8[] := array[px + hw, py + h, pz + hw];
        v float8[] := array[vx, vy, vz]; got float8[] := array[0, 0, 0]; ord int[];
        a int; i int; o int; d float8; s0 float8; s1 float8; best float8; c int; ok boolean; eps constant float8 := 1e-7;
begin
    ord := case when abs(vx) >= abs(vz) then array[2, 1, 3] else array[2, 3, 1] end;
    for st in 1..3 loop
        a := ord[st]; d := v[a];
        if abs(d) < eps then continue; end if;
        s0 := case when d < 0 then lo[a] + d else lo[a] end; s1 := case when d < 0 then hi[a] else hi[a] + d end;
        best := d;
        for i in 1..n loop
            ok := true;
            for o in 1..3 loop
                c := case o when 1 then bxs[i] when 2 then bys[i] else bzs[i] end;
                if o = a then
                    if not (c < s1 - eps and c + 1 > s0 + eps) then ok := false; exit; end if;
                elsif not (c < hi[o] - eps and c + 1 > lo[o] + eps) then ok := false; exit; end if;
            end loop;
            if ok then
                c := case a when 1 then bxs[i] when 2 then bys[i] else bzs[i] end;
                if d < 0 then best := greatest(best, c + 1 - lo[a]); else best := least(best, c - hi[a]); end if;
            end if;
        end loop;
        got[a] := best; lo[a] := lo[a] + best; hi[a] := hi[a] + best;
    end loop;
    if got[1] * got[1] + got[2] * got[2] + got[3] * got[3] > eps then
        nx := lo[1] + hw; ny := lo[2]; nz := lo[3] + hw;
    else
        nx := px; ny := py; nz := pz;
    end if;
    nvx := case when got[1] <> vx then 0 else vx end;
    nvy := case when got[2] <> vy then 0 else vy end;
    nvz := case when got[3] <> vz then 0 else vz end;
    og := got[2] <> vy and vy < 0;
end $$;

-- The entities that are processed this tick, with the velocity they start the move with (gravity added; mobs walk at their goal velocity).
create or replace function mc.entity_active(p_tick bigint)
returns table (id int, dimension text, x float8, y float8, z float8, vx float8, vy float8, vz float8, on_ground boolean, hw float8, h float8, kind text, cx int, cz int, gx float8, gz float8)
language sql stable parallel safe as $$
  select e.id, e.dimension, e.x, e.y, e.z,
         case when p.kind = 'mob' then e.gx else e.vx end,
         e.vy - p.gravity * (p_tick - e.phys_tick),
         case when p.kind = 'mob' then e.gz else e.vz end,
         e.on_ground, p.width / 2, p.height, p.kind, e.cx, e.cz, e.gx, e.gz
  from mc.entity e join mc.entity_type_param p on p.type = e.type
  where not e.deep_sleep
    and (p.kind = 'mob'
         or not (e.on_ground and e.vx * e.vx + e.vz * e.vz <= 9.999999747378752e-06)
         or (p_tick - e.born_tick + e.id) % 4 = 0)
$$;

-- Masks are invalidated by a trigger (any change of a section row deletes its mask); a missing mask is built the first time an entity sweeps the section.
create or replace function mc.entity_mask_invalidate() returns trigger language plpgsql as $$
begin
    if tg_op = 'DELETE' then delete from mc.solid_mask where dimension = old.dimension and cx = old.cx and cz = old.cz and sy = old.sy;
    else delete from mc.solid_mask where dimension = new.dimension and cx = new.cx and cz = new.cz and sy = new.sy; end if;
    return null;
end $$;
drop trigger if exists entity_mask_invalidate on mc.chunk_section;
create trigger entity_mask_invalidate after insert or update or delete on mc.chunk_section for each row execute function mc.entity_mask_invalidate();

-- One tick for all awake entities.  Step 1 is ONE read-only statement (sweep, solid cells, move, drag) that returns arrays; step 2 updates through unnest, which
-- gives primary-key probes whatever the row estimates are (a join against the whole table was 25 ms of sequential scanning at 10,000 entities).
-- An entity that sweeps a section whose mask is not built yet waits this tick; the masks of the missing sections are built after the update.
create or replace function mc.entity_physics_ids(p_tick bigint) returns int[] language plpgsql volatile as $$
declare ids int[]; nxs float8[]; nys float8[]; nzs float8[]; vxs float8[]; vys float8[]; vzs float8[]; ogs boolean[]; deeps boolean[]; ncxs int[]; nczs int[];
        m_dim text[]; m_cx int[]; m_cz int[]; m_sy int[]; n int := 0;
begin
    -- nothing awake outside the lanes (the usual case with mobs in lanes and items asleep): one probe of the partial index instead of the planning and set-up of the statement below
    if to_regclass('mc.entity_lane') is not null and not exists (select 1 from mc.entity e where not e.deep_sleep and e.lane_until = 0) then return '{}'::int[]; end if;
    with a as materialized (
        select a.*, w.x0, w.x1, w.y0, w.y1, w.z0, w.z1
        from mc.entity_active(p_tick) a
        cross join lateral mc.entity_sweep(a.x, a.y, a.z, a.vx, a.vy, a.vz, a.hw, a.h) w
    ), probes as (
        -- every section of the swept box, probed by primary key (a correlated LIMIT 1 keeps the planner from turning the probe into a scan)
        select a.id, a.dimension, s.qx, s.qy, s.qz, m.mask, m.slippery, m.solid_cnt, m.dimension is null as unknown, a.x0, a.x1, a.y0, a.y1, a.z0, a.z1
        from a
        cross join lateral generate_series(0, ((a.x1 >> 4) - (a.x0 >> 4) + 1) * ((a.y1 >> 4) - (a.y0 >> 4) + 1) * ((a.z1 >> 4) - (a.z0 >> 4) + 1) - 1) k
        cross join lateral (select (a.x0 >> 4) + k % ((a.x1 >> 4) - (a.x0 >> 4) + 1) as qx,
                                   (a.y0 >> 4) + (k / ((a.x1 >> 4) - (a.x0 >> 4) + 1)) % ((a.y1 >> 4) - (a.y0 >> 4) + 1) as qy,
                                   (a.z0 >> 4) + k / (((a.x1 >> 4) - (a.x0 >> 4) + 1) * ((a.y1 >> 4) - (a.y0 >> 4) + 1)) as qz) s
        left join lateral (select mm.mask, mm.slippery, mm.solid_cnt, mm.dimension from mc.solid_mask mm
                            where mm.dimension = a.dimension and mm.cx = s.qx and mm.cz = s.qz and mm.sy = s.qy limit 1) m on true
    ), miss as (
        select distinct dimension, qx, qy, qz from probes where unknown
    ), unk as (
        select distinct id from probes where unknown
    ), cells as (
        -- the solid cells inside the swept box: one counter per hit, coordinates by division (cross joins of series plan badly)
        select h.id, c.bx, c.by, c.bz, h.slippery
        from probes h
        cross join lateral (select greatest(h.x0, h.qx * 16) as x0, least(h.x1, h.qx * 16 + 15) as x1, greatest(h.y0, h.qy * 16) as y0, least(h.y1, h.qy * 16 + 15) as y1,
                                   greatest(h.z0, h.qz * 16) as z0, least(h.z1, h.qz * 16 + 15) as z1) r
        cross join lateral generate_series(0, (r.x1 - r.x0 + 1) * (r.y1 - r.y0 + 1) * (r.z1 - r.z0 + 1) - 1) k
        cross join lateral (select r.x0 + k % (r.x1 - r.x0 + 1) as bx, r.y0 + (k / (r.x1 - r.x0 + 1)) % (r.y1 - r.y0 + 1) as by,
                                   r.z0 + k / ((r.x1 - r.x0 + 1) * (r.y1 - r.y0 + 1)) as bz) c
        where not h.unknown and h.solid_cnt > 0 and get_bit(h.mask, ((c.by & 15) * 16 + (c.bz & 15)) * 16 + (c.bx & 15)) = 1
    ), bl as (
        select id, array_agg(bx) as bxs, array_agg(by) as bys, array_agg(bz) as bzs, bool_or(slippery) as slip from cells group by id
    ), moved as (
        select a.id, a.kind, a.gx, a.gz, f.*, false as slip from a cross join lateral mc.entity_move_free(a.x, a.y, a.z, a.vx, a.vy, a.vz) f
         where not exists (select 1 from bl where bl.id = a.id) and not exists (select 1 from unk where unk.id = a.id)
        union all
        select a.id, a.kind, a.gx, a.gz, f.*, bl.slip
          from a join bl on bl.id = a.id
          cross join lateral mc.entity_move(a.x, a.y, a.z, a.vx, a.vy, a.vz, a.hw, a.h, bl.bxs, bl.bys, bl.bzs) f
         where not exists (select 1 from unk where unk.id = a.id)
    ), fin as (
        select m.id, m.nx, m.ny, m.nz, m.og, m.kind, m.gx, m.gz,
               case when m.kind = 'item' then m.nvx * m.fr else m.nvx end as fvx,
               case when m.kind = 'item' and m.og and m.nvy * 0.98::real::float8 < 0 then m.nvy * 0.98::real::float8 * -0.5 else m.nvy * 0.98::real::float8 end as fvy,
               case when m.kind = 'item' then m.nvz * m.fr else m.nvz end as fvz
        from (select mv.*, case when mv.og then (case when mv.slip then mc.cell_friction('minecraft:overworld', floor(mv.nx)::int, floor(mv.ny - 0.500001)::int, floor(mv.nz)::int) else 0.6::real end * 0.98::real)::float8
                                else 0.98::real::float8 end as fr
                from moved mv) m
    ), fin2 as (
        select f.*, f.og and ((f.kind = 'item' and f.fvx * f.fvx + f.fvz * f.fvz <= 1e-7) or (f.kind = 'mob' and f.gx = 0 and f.gz = 0)) as deep from fin f
    )
    select (select array_agg(f.id) from fin2 f), (select array_agg(f.nx) from fin2 f), (select array_agg(f.ny) from fin2 f), (select array_agg(f.nz) from fin2 f),
           (select array_agg(case when f.deep and f.kind = 'item' then 0 else f.fvx end) from fin2 f), (select array_agg(f.fvy) from fin2 f),
           (select array_agg(case when f.deep and f.kind = 'item' then 0 else f.fvz end) from fin2 f),
           (select array_agg(f.og) from fin2 f), (select array_agg(f.deep) from fin2 f),
           (select array_agg(floor(f.nx / 16)::int) from fin2 f), (select array_agg(floor(f.nz / 16)::int) from fin2 f),
           (select array_agg(dimension) from miss), (select array_agg(qx) from miss), (select array_agg(qz) from miss), (select array_agg(qy) from miss)
      into ids, nxs, nys, nzs, vxs, vys, vzs, ogs, deeps, ncxs, nczs, m_dim, m_cx, m_cz, m_sy;

    if ids is not null then
        update mc.entity e set x = u.nx, y = u.ny, z = u.nz, vx = u.vx, vy = u.vy, vz = u.vz, on_ground = u.og, phys_tick = p_tick, deep_sleep = u.deep, cx = u.ncx, cz = u.ncz
          from unnest(ids, nxs, nys, nzs, vxs, vys, vzs, ogs, deeps, ncxs, nczs) as u(id, nx, ny, nz, vx, vy, vz, og, deep, ncx, ncz)
         where e.id = u.id;
        get diagnostics n = row_count;
    end if;
    if m_dim is not null then
        perform mc.entity_build_mask(m_dim[i], m_cx[i], m_cz[i], m_sy[i]) from generate_series(1, cardinality(m_dim)) i;
    end if;
    return coalesce(ids, '{}'::int[]);
end $$;
-- the same, returning only how many entities were processed
create or replace function mc.entity_physics(p_tick bigint) returns int language sql volatile as $$ select cardinality(mc.entity_physics_ids(p_tick)) $$;

-- A block changed: entities in deep sleep next to it wake up.  Their gravity then accumulates from the last 4-tick phase boundary, as it would have in vanilla.
create or replace function mc.entity_wake_on_block_event() returns trigger language plpgsql as $$
declare t bigint;
begin
    select game_time into t from mc.game_state limit 1;
    update mc.entity e set deep_sleep = false,
           phys_tick = case when e.type = 'minecraft:item' then t - ((t - e.born_tick + e.id) % 4) else t end
      from (select distinct dimension, x, y, z from new_ev) ev
     where e.deep_sleep and e.dimension = ev.dimension
       and e.cx in ((ev.x - 1) >> 4, ev.x >> 4, (ev.x + 1) >> 4) and e.cz in ((ev.z - 1) >> 4, ev.z >> 4, (ev.z + 1) >> 4)
       and abs(floor(e.x)::int - ev.x) <= 1 and abs(floor(e.z)::int - ev.z) <= 1 and floor(e.y)::int - ev.y between -1 and 2;
    return null;
end $$;
drop trigger if exists entity_wake on mc.block_event;
create trigger entity_wake after insert on mc.block_event referencing new table as new_ev for each statement execute function mc.entity_wake_on_block_event();
