-- World dynamics, part 4: how blocks react to their neighbours and to being placed.  Pure functions over the section array of sql/881, each returning a list of ACTIONS for
-- the engine (sql/884) to apply, as groups of six integers [op, x, y, z, a, b]:
--     1 WRITE        set (x, y, z) to state a            (the engine then runs the neighbour updates of that change, depth first, as vanilla's CollectingNeighborUpdater does)
--     2 SCHED_FLUID  schedule a fluid tick at (x, y, z): a = fluid type code (0 water, 1 flowing water, 2 lava, 3 flowing lava), b = delay in ticks
--     3 SCHED_BLOCK  schedule a block tick: a = block ordinal (mc.dyn_block), b = delay
--     4 EVENT        a level event (a = type, b = data), e.g. 1501 "fizz"
--     7 SPREAD_TO    FlowingFluid.spreadTo(pos, state, direction a, fluid state code b)
--
-- What vanilla does when a block changes (Level.setBlock with flags 3): the NEW state's onPlace runs (when the block changed), then updateNeighborsAt: neighborChanged on the six
-- neighbours in the order WEST EAST DOWN UP NORTH SOUTH, then updateShape on them in the order WEST EAST NORTH SOUTH DOWN UP, each seeing the new state as its neighbour.

-- LiquidBlock.shouldSpreadLiquid + the tick it schedules, for the liquid block of state p_sid at (x, y, z).  Used by onPlace and neighborChanged alike.
-- p_fast: the dimension has fast lava (the Nether): lava ticks every 10 ticks instead of 30.
create or replace function mc.dyn_liquid_react(p_secs int4[], p_gm int4[], p_fl int4[], p_fa int2[], p_k int4[], x int, y int, z int, p_sid int, p_fast boolean)
returns int4[] language plpgsql immutable parallel safe as $$
declare
    lava boolean := (p_fl[p_sid + 1] & 16) <> 0;
    d int; ns int; soul boolean;
    fcode int := mc.dyn_fstate(p_fl, p_fa, p_sid);
begin
    if lava then
        soul := mc.dyn_at(p_secs, p_gm, x, y - 1, z) = p_k[39];
        foreach d in array array[1, 2, 3, 4, 5] loop                                           -- POSSIBLE_FLOW_DIRECTIONS (DOWN SOUTH NORTH EAST WEST) of the opposite side
            ns := mc.dyn_at(p_secs, p_gm, x + mc.dyn_dx(d), y + mc.dyn_dy(d), z + mc.dyn_dz(d));
            if (p_fl[ns + 1] & 8) <> 0 then                                                    -- water beside or above lava
                return array[1, x, y, z, case when (p_fl[p_sid + 1] & 32) <> 0 then p_k[4] else p_k[3] end, 0,
                             4, x, y, z, 1501, 0];                                             -- obsidian for a lava source, cobblestone for flowing lava; fizz
            elsif soul and ns = p_k[40] then
                return array[1, x, y, z, p_k[6], 0, 4, x, y, z, 1501, 0];                      -- soul soil below, blue ice beside: basalt
            end if;
        end loop;
    end if;
    return array[2, x, y, z, mc.dyn_ftype(fcode), case when lava then (case when p_fast then 10 else 30 end) else 5 end];
end $$;

-- Block.onPlace of the new state p_nsid at (x, y, z).  LevelChunk.setBlockState calls it for every change of a state (not only when the block changes: a flowing fluid that changes
-- its level is placed again, and a LiquidBlock schedules its own tick in onPlace); p_osid is only informational
create or replace function mc.dyn_on_place(p_secs int4[], p_gm int4[], p_fl int4[], p_fa int2[], p_k int4[], p_bid int4[], x int, y int, z int, p_osid int, p_nsid int, p_fast boolean)
returns int4[] language plpgsql immutable parallel safe as $$
begin
    if (p_fl[p_nsid + 1] & 4) <> 0 then return mc.dyn_liquid_react(p_secs, p_gm, p_fl, p_fa, p_k, x, y, z, p_nsid, p_fast); end if;
    if (p_fl[p_nsid + 1] & 4096) <> 0 then return array[3, x, y, z, p_bid[p_nsid + 1], 2]; end if;          -- FallingBlock.onPlace: scheduleTick(pos, this, 2)
    return '{}';
end $$;

-- The reaction of the block at (qx, qy, qz) (state p_qsid) to a change next to it, in direction p_dir FROM the neighbour TO the changed cell; p_csid is the changed cell's new state.
-- p_what 1 = neighborChanged, 2 = updateShape.
create or replace function mc.dyn_notify(p_secs int4[], p_gm int4[], p_fl int4[], p_fa int2[], p_k int4[], p_bid int4[], p_what int, qx int, qy int, qz int, p_qsid int, p_dir int, p_csid int, p_fast boolean,
                                         p_rl int4[] default '{}', p_stv int4[] default '{}', p_tg int8[] default '{}')
returns int4[] language plpgsql immutable parallel safe as $$
declare f int := p_fl[p_qsid + 1]; res int4[] := '{}'; r int; t int; prm int; chk boolean;
begin
    if p_what = 1 then
        if (f & 4) <> 0 then return mc.dyn_liquid_react(p_secs, p_gm, p_fl, p_fa, p_k, qx, qy, qz, p_qsid, p_fast); end if;       -- LiquidBlock.neighborChanged
        return '{}';
    end if;
    -- updateShape
    if (f & 4) <> 0 then                                                                                                   -- LiquidBlock.updateShape: a source here or there keeps the fluid ticking
        if (f & 32) <> 0 or (p_fl[p_csid + 1] & 32) <> 0 then
            res := array[2, qx, qy, qz, mc.dyn_ftype(mc.dyn_fstate(p_fl, p_fa, p_qsid)), case when (f & 16) <> 0 then (case when p_fast then 10 else 30 end) else 5 end];
        end if;
        return res;
    end if;
    if (f & 8) <> 0 then res := res || array[2, qx, qy, qz, 0, 5]; end if;                                                   -- waterlogged blocks, kelp, seagrass: scheduleTick(pos, Fluids.WATER, 5)
    if (f & 4096) <> 0 then res := res || array[3, qx, qy, qz, p_bid[p_qsid + 1], 2]; end if;                                -- FallingBlock.updateShape
    if (f & 262144) <> 0 then
        -- a block with a support rule (sql/886): updateShape returns air when canSurvive says no; Block.updateOrDestroy then destroys it (loud: level event 2001) leaving its fluid
        r := p_rl[p_qsid + 1]; t := r & 255; prm := r >> 8;
        chk := case t when 1 then true when 3 then p_dir = prm when 10 then p_dir = prm else p_dir = 0 end;
        if chk and not mc.dyn_survives(p_secs, p_gm, p_fl, p_stv, p_tg, p_bid, qx, qy, qz, r) then
            return res || array[1, qx, qy, qz, case when (f & 8) <> 0 then p_k[7] else p_k[1] end, 1];
        end if;
        -- the lower half of a door or a tall plant also needs its upper half (DoublePlantBlock / DoorBlock.updateShape, direction UP)
        if p_dir = 1 and (f & 131072) <> 0 and (t = 1 or t = 6) and not (p_bid[p_csid + 1] = p_bid[p_qsid + 1] and (p_fl[p_csid + 1] & 131072) = 0) then
            return res || array[1, qx, qy, qz, case when (f & 8) <> 0 then p_k[7] else p_k[1] end, 1];
        end if;
    end if;
    return res;
end $$;
