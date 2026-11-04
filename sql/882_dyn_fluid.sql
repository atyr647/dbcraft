-- World dynamics, part 3: the fluid rules of vanilla's FlowingFluid / WaterFluid / LavaFluid / LiquidBlock, as pure functions over the section array of sql/881.
-- Every rule below was read from the 26.3 bytecode (javap -c -p net.minecraft.world.level.material.FlowingFluid and the classes around it) and is named after the method it
-- reproduces.  They only READ the world (p_secs); the engine (sql/884) applies what they return.
--
-- Fluid states are coded as F = family * 16 + level, family 0 water / 1 lava, level = LiquidBlock's `level` property: 0 source, 1..7 flowing (amount 8 - level), 8 falling flowing
-- (amount 8), and -1 for "no fluid".  The block state of a code is mc.dyn_vec.k[7 + F].  A fluid's TYPE (vanilla compares Fluid instances, and ticks are scheduled per type) is
-- source or flowing: code family * 2 + (level = 0 ? 0 : 1).
--
-- Arguments shared by the rule functions: p_secs, p_gm = {sy0, cz0, cx0, ncz, ncx, then the map from the grid of slots to rows of p_secs} (the section block, see mc.dyn_at), and the state arrays of mc.dyn_vec
-- (p_fl flags, p_fa fluid amount, p_co collision shape per state, p_sk shape kind, p_oc the occlusion bit table, p_ns the number of shapes).
-- Directions are numbered as vanilla's Direction enum: 0 DOWN, 1 UP, 2 NORTH, 3 SOUTH, 4 WEST, 5 EAST.

-- the state id at a position of the section block
create or replace function mc.dyn_at(p_secs int4[], p_gm int4[], x int, y int, z int) returns int language sql immutable parallel safe as $$
  select p_secs[p_gm[5 + ((((y >> 4) - p_gm[1]) * p_gm[4] + ((z >> 4) - p_gm[2])) * p_gm[5] + ((x >> 4) - p_gm[3]) + 1)]][(((y & 15) << 8) | ((z & 15) << 4) | (x & 15)) + 1] $$;

create or replace function mc.dyn_dx(d int) returns int language sql immutable parallel safe as $$ select case d when 4 then -1 when 5 then 1 else 0 end $$;
create or replace function mc.dyn_dy(d int) returns int language sql immutable parallel safe as $$ select case d when 0 then -1 when 1 then 1 else 0 end $$;
create or replace function mc.dyn_dz(d int) returns int language sql immutable parallel safe as $$ select case d when 2 then -1 when 3 then 1 else 0 end $$;
create or replace function mc.dyn_opp(d int) returns int language sql immutable parallel safe as $$ select d # 1 $$;           -- DOWN<->UP, NORTH<->SOUTH, WEST<->EAST

-- the fluid state code of a block state, -1 when its fluid state is empty
create or replace function mc.dyn_fstate(p_fl int4[], p_fa int2[], sid int) returns int language sql immutable parallel safe as $$
  select case when (p_fl[sid + 1] & 8) <> 0 then (case when (p_fl[sid + 1] & 32) <> 0 then 0 when (p_fl[sid + 1] & 64) <> 0 then 8 else 8 - p_fa[sid + 1] end)
              when (p_fl[sid + 1] & 16) <> 0 then 16 + (case when (p_fl[sid + 1] & 32) <> 0 then 0 when (p_fl[sid + 1] & 64) <> 0 then 8 else 8 - p_fa[sid + 1] end)
              else -1 end $$;
-- the fluid TYPE of a state code (0 water, 1 flowing water, 2 lava, 3 flowing lava), -1 for none
create or replace function mc.dyn_ftype(f int) returns int language sql immutable parallel safe as $$
  select case when f < 0 then -1 else (f >> 4) * 2 + (case when (f & 15) = 0 then 0 else 1 end) end $$;
-- FluidState.getAmount() of a state code
create or replace function mc.dyn_famount(f int) returns int language sql immutable parallel safe as $$
  select case when f < 0 then 0 when (f & 15) = 0 or (f & 15) = 8 then 8 else 8 - (f & 15) end $$;

-- FlowingFluid.canPassThroughWall(dir, from, to): the fluid at `from` may enter `to` through the face in direction dir, by the two collision shapes
create or replace function mc.dyn_pass_wall(p_fs int, p_ts int, p_dir int, p_co int4[], p_sk int2[], p_oc bytea, p_ns int) returns boolean language plpgsql immutable parallel safe as $$
declare tk int := coalesce(p_sk[p_co[p_ts + 1] + 1], 1); fk int := coalesce(p_sk[p_co[p_fs + 1] + 1], 1);
begin
    if tk = 1 or fk = 1 then return false; end if;                    -- a full block on either side
    if tk = 0 or fk = 0 then return true; end if;                     -- one side empty: the other shape alone cannot cover the face
    return get_bit(p_oc, (p_co[p_fs + 1] * p_ns + p_co[p_ts + 1]) * 6 + p_dir) = 0;      -- Shapes.mergedFaceOccludes(from, to, dir), precomputed from the jar
end $$;

-- FlowingFluid.canHoldSpecificFluid(level, pos, state, fluid): a LiquidBlockContainer decides (a SimpleWaterloggedBlock takes still water, only when dry; kelp and seagrass take none),
-- anything else holds any fluid.  p_ftype is the TYPE code of the fluid.
create or replace function mc.dyn_hold_specific(p_fl int4[], sid int, p_ftype int) returns boolean language sql immutable parallel safe as $$
  select case when (p_fl[sid + 1] & 256) = 0 then true
              when (p_fl[sid + 1] & 128) <> 0 then p_ftype = 0 and (p_fl[sid + 1] & 8) = 0
              else false end $$;

-- FlowingFluid.isSourceBlockOfThisType(fluidState): a source of the family
create or replace function mc.dyn_is_src_of(f int, p_family int) returns boolean language sql immutable parallel safe as $$
  select f >= 0 and (f >> 4) = p_family and (f & 15) = 0 $$;

-- FlowingFluid.canMaybePassThrough(level, pos, state, dir, nextPos, nextState, nextFluid)
create or replace function mc.dyn_maybe_pass(p_fl int4[], p_fa int2[], p_co int4[], p_sk int2[], p_oc bytea, p_ns int, p_family int, p_fs int, p_dir int, p_ts int) returns boolean language sql immutable parallel safe as $$
  select not mc.dyn_is_src_of(mc.dyn_fstate(p_fl, p_fa, p_ts), p_family) and (p_fl[p_ts + 1] & 512) <> 0 and mc.dyn_pass_wall(p_fs, p_ts, p_dir, p_co, p_sk, p_oc, p_ns) $$;

-- FlowingFluid.getNewLiquid(level, pos, state): the fluid state a flowing block at (x, y, z) should have.  p_conv: canConvertToSource(level) (the gamerule of the family).
create or replace function mc.dyn_new_liquid(p_secs int4[], p_gm int4[], p_fl int4[], p_fa int2[], p_co int4[], p_sk int2[], p_oc bytea, p_ns int, x int, y int, z int, p_family int, p_conv boolean, p_drop int)
returns int language plpgsql immutable parallel safe as $$
declare
    me int := mc.dyn_at(p_secs, p_gm, x, y, z);
    mx int := 0; srcs int := 0; d int; nx int; nz int; ns int; nf int; up int; upf int; dn int;
begin
    for d in 2 .. 5 loop                                                                 -- Direction.Plane.HORIZONTAL: NORTH, EAST, SOUTH, WEST (order does not matter for a count and a maximum)
        nx := x + mc.dyn_dx(d); nz := z + mc.dyn_dz(d);
        ns := mc.dyn_at(p_secs, p_gm, nx, y, nz);
        nf := mc.dyn_fstate(p_fl, p_fa, ns);
        if nf < 0 or (nf >> 4) <> p_family then continue; end if;                       -- Fluid.isSame: still and flowing of one family
        if mc.dyn_pass_wall(me, ns, d, p_co, p_sk, p_oc, p_ns) then
            if (nf & 15) = 0 then srcs := srcs + 1; end if;
            mx := greatest(mx, mc.dyn_famount(nf));
        end if;
    end loop;
    if srcs >= 2 and p_conv then
        dn := mc.dyn_at(p_secs, p_gm, x, y - 1, z);
        if (p_fl[dn + 1] & 2) <> 0 or mc.dyn_is_src_of(mc.dyn_fstate(p_fl, p_fa, dn), p_family) then return p_family * 16; end if;     -- BlockState.isSolid() or a source below
    end if;
    up := mc.dyn_at(p_secs, p_gm, x, y + 1, z);
    upf := mc.dyn_fstate(p_fl, p_fa, up);
    if upf >= 0 and (upf >> 4) = p_family and mc.dyn_pass_wall(me, up, 1, p_co, p_sk, p_oc, p_ns) then return p_family * 16 + 8; end if;   -- fluid of the family above: falling
    mx := mx - p_drop;
    if mx <= 0 then return -1; end if;
    return p_family * 16 + (8 - mx);
end $$;

-- FlowingFluid.isWaterHole(level, pos, state, belowPos, belowState): can the fluid at pos fall into the cell below it
create or replace function mc.dyn_is_hole(p_fl int4[], p_fa int2[], p_co int4[], p_sk int2[], p_oc bytea, p_ns int, p_family int, p_fs int, p_bs int)
returns boolean language plpgsql immutable parallel safe as $$
declare bf int;
begin
    if not mc.dyn_pass_wall(p_fs, p_bs, 0, p_co, p_sk, p_oc, p_ns) then return false; end if;
    bf := mc.dyn_fstate(p_fl, p_fa, p_bs);
    if bf >= 0 and (bf >> 4) = p_family then return true; end if;                                        -- the fluid below is of this family
    return (p_fl[p_bs + 1] & 512) <> 0 and mc.dyn_hold_specific(p_fl, p_bs, p_family * 2 + 1);          -- canHoldFluid(.., getFlowing())
end $$;

-- FlowingFluid.getSlopeDistance(level, pos, distance, fromDir, state, ctx): depth-first search over the four horizontal directions (NORTH, EAST, SOUTH, WEST) for a hole within
-- p_reach steps.  Returns the distance of the FIRST hole met in direction order at this level (vanilla returns at once), else the smallest result of the deeper searches, else 1000.
create or replace function mc.dyn_slope(p_secs int4[], p_gm int4[], p_fl int4[], p_fa int2[], p_co int4[], p_sk int2[], p_oc bytea, p_ns int, p_family int, p_reach int,
                                        x int, y int, z int, p_dist int, p_from int, p_state int)
returns int language plpgsql immutable parallel safe as $$
declare
    best int := 1000; d int; nx int; nz int; ns int; sub int;
    dirs int[] := array[2, 5, 3, 4];                                    -- NORTH, EAST, SOUTH, WEST
begin
    foreach d in array dirs loop
        if d = p_from then continue; end if;
        nx := x + mc.dyn_dx(d); nz := z + mc.dyn_dz(d);
        ns := mc.dyn_at(p_secs, p_gm, nx, y, nz);
        -- canPassThrough(level, flowing, pos, state, d, next, nextState, nextFluid) = canMaybePassThrough(...) && canHoldSpecificFluid(next, flowing)
        if mc.dyn_maybe_pass(p_fl, p_fa, p_co, p_sk, p_oc, p_ns, p_family, p_state, d, ns) and mc.dyn_hold_specific(p_fl, ns, p_family * 2 + 1) then
            if mc.dyn_is_hole(p_fl, p_fa, p_co, p_sk, p_oc, p_ns, p_family, ns, mc.dyn_at(p_secs, p_gm, nx, y - 1, nz)) then return p_dist; end if;
            if p_dist < p_reach then
                sub := mc.dyn_slope(p_secs, p_gm, p_fl, p_fa, p_co, p_sk, p_oc, p_ns, p_family, p_reach, nx, y, nz, p_dist + 1, mc.dyn_opp(d), ns);
                if sub < best then best := sub; end if;
            end if;
        end if;
    end loop;
    return best;
end $$;

-- FlowingFluid.getSpread(level, pos, state): the horizontal neighbours the fluid at (x, y, z) flows to, as pairs (direction, state code) in Direction enum order (NORTH, SOUTH, WEST, EAST),
-- only the directions with the smallest slope distance.
create or replace function mc.dyn_spread(p_secs int4[], p_gm int4[], p_fl int4[], p_fa int2[], p_co int4[], p_sk int2[], p_oc bytea, p_ns int, p_family int, p_reach int, p_conv boolean, p_drop int,
                                         x int, y int, z int)
returns int4[] language plpgsql immutable parallel safe as $$
declare
    me int := mc.dyn_at(p_secs, p_gm, x, y, z);
    best int := 1000; d int; nx int; nz int; ns int; nf int; nl int; dist int; ok boolean;
    sel int[] := '{}'; ncode int[] := array[-1, -1, -1, -1, -1, -1];
    dirs int[] := array[2, 5, 3, 4];                                    -- the EnumMap is filled in this order but read in enum order below
begin
    foreach d in array dirs loop
        nx := x + mc.dyn_dx(d); nz := z + mc.dyn_dz(d);
        ns := mc.dyn_at(p_secs, p_gm, nx, y, nz);
        if not mc.dyn_maybe_pass(p_fl, p_fa, p_co, p_sk, p_oc, p_ns, p_family, me, d, ns) then continue; end if;
        nl := mc.dyn_new_liquid(p_secs, p_gm, p_fl, p_fa, p_co, p_sk, p_oc, p_ns, nx, y, nz, p_family, p_conv, p_drop);
        if not mc.dyn_hold_specific(p_fl, ns, mc.dyn_ftype(nl)) then continue; end if;       -- (an empty type is -1: only plain blocks hold it)
        if mc.dyn_is_hole(p_fl, p_fa, p_co, p_sk, p_oc, p_ns, p_family, ns, mc.dyn_at(p_secs, p_gm, nx, y - 1, nz)) then dist := 0;
        else dist := mc.dyn_slope(p_secs, p_gm, p_fl, p_fa, p_co, p_sk, p_oc, p_ns, p_family, p_reach, nx, y, nz, 1, mc.dyn_opp(d), ns); end if;
        if dist < best then ncode := array[-1, -1, -1, -1, -1, -1]; end if;                    -- map.clear()
        if dist <= best then
            nf := mc.dyn_fstate(p_fl, p_fa, ns);
            if mc.dyn_replaceable_by(p_fl, nf, ns, nl, d, nx, y, nz, p_secs, p_gm) then ncode[d + 1] := nl; end if;
            best := dist;
        end if;
    end loop;
    for d in 2 .. 5 loop                                                 -- enum order: NORTH, SOUTH, WEST, EAST
        if ncode[d + 1] <> -1 then sel := sel || d || ncode[d + 1]; end if;
    end loop;
    return sel;
end $$;

-- FluidState.canBeReplacedWith(level, pos, otherFluid, dir) of the fluid state p_f at (x, y, z) (state sid p_s); p_other is the state code of the incoming fluid (-1: the empty fluid)
--   empty fluid state: true        water (flowing or still): dir = DOWN and the incoming fluid is not water
--   lava: its height (own amount / 9, or 1 with the same fluid above) is at least 0.44444445 and the incoming fluid is water
create or replace function mc.dyn_replaceable_by(p_fl int4[], p_f int, p_s int, p_other int, p_dir int, x int, y int, z int, p_secs int4[], p_gm int4[])
returns boolean language plpgsql immutable parallel safe as $$
begin
    if p_f < 0 then return true; end if;
    if (p_f >> 4) = 0 then return p_dir = 0 and not (p_other >= 0 and (p_other >> 4) = 0); end if;
    if not (p_other >= 0 and (p_other >> 4) = 0) then return false; end if;
    -- lava: FlowingFluid.getHeight = (the same fluid above ? 1 : amount / 9) >= 0.44444445f, a float that 4 / 9 rounds to: so an amount of 4 or more, or lava above
    return (p_fl[mc.dyn_at(p_secs, p_gm, x, y + 1, z) + 1] & 16) <> 0 or mc.dyn_famount(p_f) >= 4;
end $$;
