-- Entity physics: ONE set-based statement per tick for all awake entities.  A port of tools/entity/model.py, which reproduces vanilla 26.3's ItemEntity
-- (read from the bytecode of ItemEntity.tick / Entity.move) exactly on four recorded per-tick trajectories (docs/ENTITY.md).
--
-- Per tick and entity:  vy -= gravity; move (axis order Y, then X before Z if |vx| >= |vz| else Z before X; each axis clipped by solid unit cells; the collided movement is applied
-- only if its squared length is above 1e-7; a clipped axis zeroes its velocity component; on_ground = vertical movement clipped while moving down);
-- items then apply drag 0.98F (0.6F * 0.98F on the ground) horizontally and 0.98F vertically, and bounce -0.5 if on the ground moving down.
-- Items at rest skip the move and the drag (vanilla wakes them every 4th tick, when (age + id) % 4 = 0; gravity accumulates meanwhile: here it is added lazily from phys_tick);
-- once an item is supported and its horizontal speed is below the movement threshold it goes to DEEP SLEEP and costs nothing until a block changes next to it.

-- ordinary (unblocked) movement, the same rules as the collision function with no blockers
create or replace function mc.entity_move_free(px float8, py float8, pz float8, vx float8, vy float8, vz float8,
    out nx float8, out ny float8, out nz float8, out nvx float8, out nvy float8, out nvz float8, out og boolean) language sql immutable parallel safe as $$
  select case when s > 1e-7 then px + gx else px end, case when s > 1e-7 then py + gy else py end, case when s > 1e-7 then pz + gz else pz end,
         case when gx <> vx then 0::float8 else vx end, case when gy <> vy then 0::float8 else vy end, case when gz <> vz then 0::float8 else vz end,
         (gy <> vy) and vy < 0
  from (select g.gx, g.gy, g.gz, g.gx * g.gx + g.gy * g.gy + g.gz * g.gz as s
          from (select case when abs(vx) < 1e-7 then 0::float8 else vx end as gx, case when abs(vy) < 1e-7 then 0::float8 else vy end as gy,
                       case when abs(vz) < 1e-7 then 0::float8 else vz end as gz) g) q
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

create or replace function mc.entity_physics(p_tick bigint) returns int language plpgsql volatile as $$
declare n int;
begin
    -- 1. the solidity masks of the sections the active entities sweep (missing or stale ones are (re)built)
    perform mc.entity_build_mask(s.dimension, s.cx, s.cz, s.sy)
    from (select distinct a.dimension, qx as cx, qz as cz, qy as sy
            from mc.entity_active(p_tick) a
            cross join lateral mc.entity_sweep(a.x, a.y, a.z, a.vx, a.vy, a.vz, a.hw, a.h) w
            cross join lateral generate_series(w.x0 >> 4, w.x1 >> 4) qx
            cross join lateral generate_series(w.y0 >> 4, w.y1 >> 4) qy
            cross join lateral generate_series(w.z0 >> 4, w.z1 >> 4) qz) s
    left join mc.chunk ch on ch.dimension = s.dimension and ch.cx = s.cx and ch.cz = s.cz
    left join mc.solid_mask m on m.dimension = s.dimension and m.cx = s.cx and m.cz = s.cz and m.sy = s.sy
    where m.ver is distinct from coalesce(ch.version, -1);

    -- 2. one statement: sweep, find the solid cells, move, apply drag, update the rows
    with a as materialized (
        select a.*, w.x0, w.x1, w.y0, w.y1, w.z0, w.z1
        from mc.entity_active(p_tick) a
        cross join lateral mc.entity_sweep(a.x, a.y, a.z, a.vx, a.vy, a.vz, a.hw, a.h) w
    ), hits as (
        select a.id, qx as sx, qy as sy, qz as sz, m.mask, m.slippery, a.x0, a.x1, a.y0, a.y1, a.z0, a.z1
        from a
        cross join lateral generate_series(a.x0 >> 4, a.x1 >> 4) qx
        cross join lateral generate_series(a.y0 >> 4, a.y1 >> 4) qy
        cross join lateral generate_series(a.z0 >> 4, a.z1 >> 4) qz
        join mc.solid_mask m on m.dimension = a.dimension and m.cx = qx and m.cz = qz and m.sy = qy
        where m.solid_cnt > 0
    ), cells as (
        select h.id, bx, by, bz, h.slippery
        from hits h
        cross join lateral generate_series(greatest(h.x0, h.sx * 16), least(h.x1, h.sx * 16 + 15)) bx
        cross join lateral generate_series(greatest(h.y0, h.sy * 16), least(h.y1, h.sy * 16 + 15)) by
        cross join lateral generate_series(greatest(h.z0, h.sz * 16), least(h.z1, h.sz * 16 + 15)) bz
        where get_bit(h.mask, ((by & 15) * 16 + (bz & 15)) * 16 + (bx & 15)) = 1
    ), bl as (
        select id, array_agg(bx) as bxs, array_agg(by) as bys, array_agg(bz) as bzs, bool_or(slippery) as slip from cells group by id
    ), moved as (
        select a.id, a.kind, a.gx, a.gz, f.*, false as slip from a cross join lateral mc.entity_move_free(a.x, a.y, a.z, a.vx, a.vy, a.vz) f
         where not exists (select 1 from bl where bl.id = a.id)
        union all
        select a.id, a.kind, a.gx, a.gz, f.*, bl.slip
          from a join bl on bl.id = a.id
          cross join lateral mc.entity_move(a.x, a.y, a.z, a.vx, a.vy, a.vz, a.hw, a.h, bl.bxs, bl.bys, bl.bzs) f
    ), fin as (
        select m.id, m.nx, m.ny, m.nz, m.og,
               case when m.kind = 'item' then m.nvx * m.fr else m.nvx end as fvx,
               case when m.kind = 'item' and m.og and m.nvy * 0.98::real::float8 < 0 then m.nvy * 0.98::real::float8 * -0.5 else m.nvy * 0.98::real::float8 end as fvy,
               case when m.kind = 'item' then m.nvz * m.fr else m.nvz end as fvz,
               m.kind, m.gx, m.gz
        from (select mv.*, case when mv.og then (case when mv.slip then mc.cell_friction('minecraft:overworld', floor(mv.nx)::int, floor(mv.ny - 0.500001)::int, floor(mv.nz)::int) else 0.6::real end * 0.98::real)::float8
                                else 0.98::real::float8 end as fr
                from moved mv) m
    )
    update mc.entity e set
        x = f.nx, y = f.ny, z = f.nz,
        vx = case when f.deep and f.kind = 'item' then 0 else f.fvx end, vy = f.fvy, vz = case when f.deep and f.kind = 'item' then 0 else f.fvz end,
        on_ground = f.og, phys_tick = p_tick, deep_sleep = f.deep,
        cx = case when floor(f.nx / 16)::int = e.cx then e.cx else floor(f.nx / 16)::int end,
        cz = case when floor(f.nz / 16)::int = e.cz then e.cz else floor(f.nz / 16)::int end
    from (select fin.*, fin.og and ((fin.kind = 'item' and fin.fvx * fin.fvx + fin.fvz * fin.fvz <= 1e-7)
                                    or (fin.kind = 'mob' and fin.gx = 0 and fin.gz = 0)) as deep from fin) f
    where e.id = f.id;
    get diagnostics n = row_count;
    return n;
end $$;

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
