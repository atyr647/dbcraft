-- World dynamics, part 5: the engine.  mc.dyn_run runs a LIST OF WORK ITEMS in the given order against a private copy of the world (the section array of sql/881), the way
-- vanilla's tick loop runs its scheduled ticks one after another, each seeing the changes of the ones before it; at the end it writes all changes back with ONE mc.set_blocks
-- and inserts the ticks that were scheduled.  Everything the world does between two items is the cascade vanilla runs inside Level.setBlock: onPlace, then neighborChanged and
-- updateShape on the six neighbours, depth first (the reactions of sql/883 come back as action lists and are pushed on a stack).
--
-- Work items (p_kind): 1 fluid tick (aux = fluid type code), 2 block tick (aux = block ordinal), 3 random tick (aux = the state it hit, aux2 = the y of the first cell with open sky
-- in its column by the MOTION_BLOCKING_NO_LEAVES heightmap, which counts a plant's own cell too, p_darken = Level.getSkyDarken()), 4 a block changed from outside (aux = its old state id; the new
-- state is what the world holds now), 5 the landing of a falling block (aux = its state id; x y z is the landing cell).
-- Reading is an array subscript (0.1 us), writing an array assignment; a cell the engine changed is visible to every later item of the same run.
-- Returns the number of cells changed.  p_late: the block changes are announced by the NEXT tick's broadcast (what vanilla's entity phase does: it runs after the chunk broadcast).

create or replace function mc.dyn_run(p_dim text, p_cur bigint, p_kind int[], p_x int[], p_y int[], p_z int[], p_aux int[], p_late boolean default false, p_aux2 int[] default '{}', p_darken int default 0) returns int
language plpgsql volatile as $$
declare
    v     mc.dyn_vec%rowtype;
    fl    int4[]; fa int2[]; co int4[]; sk int2[]; oc bytea; ns int; kk int4[]; bidv int4[]; wltv int4[]; rl int4[]; stv int4[]; tg int8[]; npv int4[];
    dim   mc.dimension%rowtype;
    min_y int; max_y int;
    fast  boolean := p_dim = 'minecraft:the_nether';
    conv_w boolean := coalesce((select value::boolean from mc.game_rule where name = 'minecraft:water_source_conversion'), true);
    conv_l boolean := coalesce((select value::boolean from mc.game_rule where name = 'minecraft:lava_source_conversion'), false);
    n     int := cardinality(p_kind);
    -- the section block
    cx0 int; cx1 int; cz0 int; cz1 int; sy0 int; sy1 int;
    secs  int4[]; gm int4[];
    -- the change log (positions with the new state, in order)
    ch_n  int := 0; ch_x int4[] := '{}'; ch_y int4[] := '{}'; ch_z int4[] := '{}'; ch_new int4[] := '{}'; ch_loud boolean[] := '{}';
    -- pending ticks (existing ones from the queue, then the new ones of this run): position key, type and kind
    pk    int8[] := '{}'; pt int4[] := '{}'; pkind "char"[] := '{}';
    nt_n  int := 0; nt_x int4[] := '{}'; nt_y int4[] := '{}'; nt_z int4[] := '{}'; nt_kind "char"[] := '{}'; nt_type int4[] := '{}'; nt_due int8[] := '{}';
    -- pending landings (cells that falling blocks are on their way to): from the queue and from this run
    ln_n int := 0; ln_x int4[] := '{}'; ln_y int4[] := '{}'; ln_z int4[] := '{}';
    -- level events of this run
    ev_n  int := 0; ev_t int4[] := '{}'; ev_x int4[] := '{}'; ev_y int4[] := '{}'; ev_z int4[] := '{}'; ev_d int4[] := '{}';
    -- the action stack: groups of six
    st    int4[] := array_fill(0, array[600]); sp int := 0;
    ra    int4[]; ra_n int; ii int; jj int;
    u int; ph int; kind int; x int; y int; z int; aux int;
    op int; ax int; ay int; az int; pa int; pb int;
    cell int; fs int; fam int; nl int; below int; bf int; nb int; sel int4[]; ci int; old int; d int; q int; qx int; qy int; qz int; key int8; ix int; found boolean;
    dly int; drp int; reach int; conv boolean; sc int; tmp int4[]; act int4[];
    wrote int := 0; land_y int; wet boolean; found_rows int[]; hs int; lt int; tx int; ty2 int; tz int; gsum numeric; gs float8; g1 float8; ab int; m1 int; m2 int; nid int; tkc "char"; ev_max bigint;
begin
    if n = 0 then return 0; end if;
    select * into v from mc.dyn_vec;
    fl := v.flags; fa := v.famt; co := v.coll; sk := v.skind; oc := v.occ; ns := v.nshape; kk := v.k; bidv := v.bid; wltv := v.wlt; rl := v.rule; stv := v.sturdy; tg := v.tagbits; npv := v.nextp;
    select * into dim from mc.dimension where name = p_dim;
    min_y := dim.min_y; max_y := dim.min_y + dim.height;

    -- the section block: every item's neighbourhood (6 cells horizontally, 3 vertically)
    select min((t.px - 6) >> 4), max((t.px + 6) >> 4), min((t.pz - 6) >> 4), max((t.pz + 6) >> 4), min((t.py - 3) >> 4), max((t.py + 3) >> 4)
      into cx0, cx1, cz0, cz1, sy0, sy1 from unnest(p_x, p_y, p_z) t(px, py, pz);
    -- only the sections some item can look at are decoded: the eight corners of each item's neighbourhood name them (the neighbourhood is narrower than two sections in every axis)
    select array_agg(distinct (((c.sy - sy0) * (cz1 - cz0 + 1) + (c.cz - cz0)) * (cx1 - cx0 + 1) + (c.cx - cx0) + 1)) into found_rows
      from unnest(p_x, p_y, p_z, p_kind) t(px, py, pz, pk),
           lateral (select (t.px + a) >> 4 as cx, (t.py + b) >> 4 as sy, (t.pz + e) >> 4 as cz
                      from (values (case when t.pk = 1 then -6 else -5 end), (case when t.pk = 1 then 6 else 5 end)) ax(a),
                           (values (-3), (3)) ay(b), (values (case when t.pk = 1 then -6 else -5 end), (case when t.pk = 1 then 6 else 5 end)) az(e)) c;
    secs := mc.dyn_secs(p_dim, cx0, cx1, sy0, sy1, cz0, cz1, found_rows);
    gm := array[sy0, cz0, cx0, cz1 - cz0 + 1, cx1 - cx0 + 1] || array_fill(1, array[(cx1 - cx0 + 1) * (cz1 - cz0 + 1) * (sy1 - sy0 + 1)]);          -- the map of the grid: slot -> row of secs (1 = barrier)
    for ii in 1 .. coalesce(cardinality(found_rows), 0) loop gm[5 + found_rows[ii]] := ii + 1; end loop;

    -- the ticks already queued inside the block (scheduling the same tick again is ignored, as in LevelChunkTicks)
    select coalesce(array_agg(((t.x::int8 & 33554431) << 35) | ((t.z::int8 & 33554431) << 10) | (t.y + 128) order by t.seq), '{}'),
           coalesce(array_agg(case t.kind when 'f' then (case t.type when 'minecraft:water' then 0 when 'minecraft:flowing_water' then 1 when 'minecraft:lava' then 2 else 3 end)
                                          else (select b.bid from mc.dyn_block b where b.name = t.type) end order by t.seq), '{}'),
           coalesce(array_agg(t.kind order by t.seq), '{}')
      into pk, pt, pkind
      from mc.block_tick t
     where t.dimension = p_dim and t.kind in ('f', 'b') and (t.x >> 4) between cx0 and cx1 and (t.z >> 4) between cz0 and cz1;

    select coalesce(array_agg(t.x order by t.seq), '{}'), coalesce(array_agg(t.y order by t.seq), '{}'), coalesce(array_agg(t.z order by t.seq), '{}'), count(*)::int
      into ln_x, ln_y, ln_z, ln_n
      from mc.block_tick t where t.dimension = p_dim and t.kind = 'l' and (t.x >> 4) between cx0 and cx1 and (t.z >> 4) between cz0 and cz1;

    for u in 1 .. n loop
        kind := p_kind[u]; x := p_x[u]; y := p_y[u]; z := p_z[u]; aux := p_aux[u];
        ph := 1;
        <<unit>>
        loop
            act := '{}';
            ci := gm[5 + (((y >> 4) - sy0) * gm[4] + ((z >> 4) - cz0)) * gm[5] + ((x >> 4) - cx0) + 1];
            ix := (((y & 15) << 8) | ((z & 15) << 4) | (x & 15)) + 1;
            cell := secs[ci][ix];

            if kind = 1 then
                --------------------------------------------------------------------------------------------------------------------------------------- a fluid tick
                fs := mc.dyn_fstate(fl, fa, cell);
                if fs < 0 then exit unit; end if;                                                       -- nothing fluid left here (also: FlowingFluid.spread of an emptied block)
                if ph = 1 and mc.dyn_ftype(fs) <> aux then exit unit; end if;                           -- ServerLevel.tickFluid: not that fluid type any more
                fam := fs >> 4;
                conv := case when fam = 0 then conv_w else conv_l end;
                drp := case when fam = 0 then 1 when fast then 1 else 2 end;
                reach := case when fam = 0 then 4 when fast then 4 else 2 end;
                dly := case when fam = 0 then 5 when fast then 10 else 30 end;
                if ph = 1 then
                    ph := 2;
                    if (fs & 15) <> 0 then                                                              -- FlowingFluid.tick: a flowing block takes the fluid state it should have
                        nl := mc.dyn_new_liquid(secs, gm, fl, fa, co, sk, oc, ns, x, y, z, fam, conv, drp);
                        if nl < 0 then act := array[1, x, y, z, kk[1], 0];
                        elsif nl <> fs then
                            -- LavaFluid.getSpreadDelay: four times as long (3 times in 4) when the new lava is higher than the old and neither is falling
                            if fam = 1 and (fs & 15) <> 8 and (nl & 15) <> 8 and mc.dyn_famount(nl) > mc.dyn_famount(fs) and floor(random() * 4)::int <> 0 then dly := dly * 4; end if;
                            act := array[1, x, y, z, kk[7 + nl], 0, 2, x, y, z, mc.dyn_ftype(nl), dly];
                        end if;
                    end if;
                    if cardinality(act) = 0 then continue unit; end if;                                 -- nothing changed: straight to the spread
                else
                    -- FlowingFluid.spread(level, pos, state, fluidState): down first (and the sides too when three sources feed this block), else the sides
                    ph := 3;
                    below := mc.dyn_at(secs, gm, x, y - 1, z);
                    bf := mc.dyn_fstate(fl, fa, below);
                    found := false;
                    if mc.dyn_maybe_pass(fl, fa, co, sk, oc, ns, fam, cell, 0, below) then
                        nb := mc.dyn_new_liquid(secs, gm, fl, fa, co, sk, oc, ns, x, y - 1, z, fam, conv, drp);
                        if mc.dyn_replaceable_by(fl, bf, below, nb, 0, x, y - 1, z, secs, gm) and mc.dyn_hold_specific(fl, below, mc.dyn_ftype(nb)) then
                            act := array[7, x, y - 1, z, 0, nb];
                            found := true;
                            sc := 0;
                            foreach d in array array[2, 3, 4, 5] loop
                                if mc.dyn_is_src_of(mc.dyn_fstate(fl, fa, mc.dyn_at(secs, gm, x + mc.dyn_dx(d), y, z + mc.dyn_dz(d))), fam) then sc := sc + 1; end if;
                            end loop;
                            if sc >= 3 and ((fs & 15) = 8 or mc.dyn_famount(fs) - drp > 0) then
                                sel := mc.dyn_spread(secs, gm, fl, fa, co, sk, oc, ns, fam, reach, conv, drp, x, y, z);
                                for jj in 1 .. coalesce(cardinality(sel), 0) / 2 loop
                                    act := act || array[7, x + mc.dyn_dx(sel[jj * 2 - 1]), y, z + mc.dyn_dz(sel[jj * 2 - 1]), sel[jj * 2 - 1], sel[jj * 2]];
                                end loop;
                            end if;
                        end if;
                    end if;
                    if not found and ((fs & 15) = 0 or not mc.dyn_is_hole(fl, fa, co, sk, oc, ns, fam, cell, below)) then
                        -- FlowingFluid.spreadToSides: a falling fluid spreads with 7, otherwise amount - dropOff must be positive
                        if (fs & 15) = 8 or mc.dyn_famount(fs) - drp > 0 then
                            sel := mc.dyn_spread(secs, gm, fl, fa, co, sk, oc, ns, fam, reach, conv, drp, x, y, z);
                            for jj in 1 .. coalesce(cardinality(sel), 0) / 2 loop
                                act := act || array[7, x + mc.dyn_dx(sel[jj * 2 - 1]), y, z + mc.dyn_dz(sel[jj * 2 - 1]), sel[jj * 2 - 1], sel[jj * 2]];
                            end loop;
                        end if;
                    end if;
                end if;

            elsif kind = 2 then
                --------------------------------------------------------------------------------------------------------------------------------------- a block tick
                ph := 3;
                if bidv[cell + 1] <> aux then exit unit; end if;                                        -- ServerLevel.tickBlock: the block is no longer there
                if (fl[cell + 1] & 4096) <> 0 then
                    -- FallingBlock.tick: when the cell below is free the block turns into a falling block (here: it leaves its cell now and lands after the fall time)
                    below := mc.dyn_at(secs, gm, x, y - 1, z);
                    if (fl[below + 1] & (1 | 32768 | 4 | 2048)) <> 0 and y >= min_y then
                        act := array[1, x, y, z, kk[1], 0, 6, x, y, z, cell, 0];
                    end if;
                end if;

            elsif kind = 3 then
                --------------------------------------------------------------------------------------------------------------------------------------- a random tick
                ph := 3;
                if cell <> aux then exit unit; end if;
                hs := p_aux2[u];
                if (fl[cell + 1] & 524288) <> 0 then
                    -- SpreadingSnowyBlock.randomTick (grass block, mycelium): a block that cannot stay alive (water or an opaque block above) turns into dirt; with light it
                    -- spreads to dirt around: 4 tries at (-1 .. 1, -3 .. 1, -1 .. 1)
                    ab := mc.dyn_at(secs, gm, x, y + 1, z);
                    if ab <> kk[50] and ((fl[ab + 1] & 8) <> 0 and mc.dyn_famount(mc.dyn_fstate(fl, fa, ab)) = 8 or v.lightd[ab + 1] >= 15) then      -- canStayAlive: snow layer 1 stays, full water or an opaque block kills
                        act := array[1, x, y, z, kk[41], 0];
                    elsif greatest(case when y + 1 >= hs or (y + 2 >= hs and coalesce(sk[co[ab + 1] + 1], 1) = 0 and (fl[ab + 1] & 4) = 0) then 15 - p_darken else 0 end, 0) >= 9 then
                        for jj in 1 .. 4 loop
                            tx := x + floor(random() * 3)::int - 1; ty2 := y + floor(random() * 5)::int - 3; tz := z + floor(random() * 3)::int - 1;
                            q := mc.dyn_at(secs, gm, tx, ty2, tz);
                            if q = kk[41] then
                                m1 := mc.dyn_at(secs, gm, tx, ty2 + 1, tz);
                                if (m1 = kk[50] or not ((fl[m1 + 1] & 8) <> 0 and mc.dyn_famount(mc.dyn_fstate(fl, fa, m1)) = 8 or v.lightd[m1 + 1] >= 15)) and (fl[m1 + 1] & 8) = 0 then      -- canPropagate
                                    act := act || array[1, tx, ty2, tz, mc.dyn_sid_snowy(cell, ((tg[m1 + 1] >> 9) & 1) = 1), 0];
                                end if;
                            end if;
                        end loop;
                    end if;
                elsif (fl[cell + 1] & 1048576) <> 0 then
                    -- CropBlock.randomTick: with raw light 9 or more (open sky: no block light exists) the crop ages with probability 1 / ((int)(25 / growthSpeed) + 1), flags 2
                    if y + 1 >= hs and npv[cell + 1] >= 0 then                                       -- (the plant's own cell is the top of the heightmap: it does not block light)
                        gs := 1.0;
                        for m1 in -1 .. 1 loop
                            for m2 in -1 .. 1 loop
                                g1 := 0.0;
                                nid := mc.dyn_at(secs, gm, x + m1, y - 1, z + m2);
                                if ((tg[nid + 1] >> 7) & 1) = 1 then g1 := 1.0; if (fl[nid + 1] & 2097152) <> 0 and nid > kk[42] and nid <= kk[49] then g1 := 3.0; end if; end if;
                                if m1 <> 0 or m2 <> 0 then g1 := g1 / 4.0; end if;
                                gs := gs + g1;
                            end loop;
                        end loop;
                        found := bidv[mc.dyn_at(secs, gm, x - 1, y, z) + 1] = bidv[cell + 1] or bidv[mc.dyn_at(secs, gm, x + 1, y, z) + 1] = bidv[cell + 1];
                        wet := bidv[mc.dyn_at(secs, gm, x, y, z - 1) + 1] = bidv[cell + 1] or bidv[mc.dyn_at(secs, gm, x, y, z + 1) + 1] = bidv[cell + 1];
                        if found and wet then gs := gs / 2.0;
                        elsif bidv[mc.dyn_at(secs, gm, x - 1, y, z - 1) + 1] = bidv[cell + 1] or bidv[mc.dyn_at(secs, gm, x + 1, y, z - 1) + 1] = bidv[cell + 1]
                              or bidv[mc.dyn_at(secs, gm, x + 1, y, z + 1) + 1] = bidv[cell + 1] or bidv[mc.dyn_at(secs, gm, x - 1, y, z + 1) + 1] = bidv[cell + 1] then gs := gs / 2.0; end if;
                        if floor(random() * (floor(25.0::float4 / gs::float4)::int + 1))::int = 0 then act := array[1, x, y, z, npv[cell + 1], 2]; end if;
                    end if;
                elsif (fl[cell + 1] & 2097152) <> 0 then
                    -- FarmlandBlock.randomTick: water within 4 (and 1 up) or rain keeps it wet (moisture 7), else it dries one step per tick and, dry, turns to dirt unless a crop is above
                    m1 := cell - kk[42];                                                                -- the moisture of this state (farmland[moisture = 0 .. 7] are consecutive)
                    found := false;
                    for tx in x - 4 .. x + 4 loop
                        for tz in z - 4 .. z + 4 loop
                            for ty2 in y .. y + 1 loop
                                if (fl[mc.dyn_at(secs, gm, tx, ty2, tz) + 1] & 8) <> 0 then found := true; exit; end if;
                            end loop;
                            exit when found;
                        end loop;
                        exit when found;
                    end loop;
                    if found then
                        if m1 < 7 then act := array[1, x, y, z, kk[49], 2]; end if;
                    elsif m1 > 0 then act := array[1, x, y, z, kk[42] + m1 - 1, 2];
                    elsif ((tg[mc.dyn_at(secs, gm, x, y + 1, z) + 1] >> 8) & 1) = 0 then act := array[1, x, y, z, kk[41], 0];
                    end if;
                elsif (fl[cell + 1] & 4194304) <> 0 then
                    -- SaplingBlock.randomTick: light 9 or more at the cell above and 1 in 7: stage 0 -> 1 (flags 260).  A sapling already at stage 1 would grow a tree: not modelled.
                    if greatest(case when y + 1 >= hs then 15 - p_darken else 0 end, 0) >= 9 and floor(random() * 7)::int = 0 and npv[cell + 1] >= 0 then act := array[1, x, y, z, npv[cell + 1], 2]; end if;
                end if;

            elsif kind = 4 then
                --------------------------------------------------------------------------------------------------------------------------------------- a change from outside
                ph := 3;
                if aux <> cell then
                    act := mc.dyn_on_place(secs, gm, fl, fa, kk, bidv, x, y, z, aux, cell, fast);
                    foreach d in array array[4, 5, 0, 1, 2, 3] loop
                        q := mc.dyn_at(secs, gm, x + mc.dyn_dx(d), y + mc.dyn_dy(d), z + mc.dyn_dz(d));
                        if (fl[q + 1] & 4) <> 0 then act := act || mc.dyn_liquid_react(secs, gm, fl, fa, kk, x + mc.dyn_dx(d), y + mc.dyn_dy(d), z + mc.dyn_dz(d), q, fast); end if;
                    end loop;
                    foreach d in array array[4, 5, 2, 3, 0, 1] loop
                        q := mc.dyn_at(secs, gm, x + mc.dyn_dx(d), y + mc.dyn_dy(d), z + mc.dyn_dz(d));
                        if (fl[q + 1] & (4 | 8 | 4096 | 262144)) <> 0 then
                            act := act || mc.dyn_notify(secs, gm, fl, fa, kk, bidv, 2, x + mc.dyn_dx(d), y + mc.dyn_dy(d), z + mc.dyn_dz(d), q, mc.dyn_opp(d), cell, fast, rl, stv, tg);
                        end if;
                    end loop;
                end if;

            elsif kind = 5 then
                --------------------------------------------------------------------------------------------------------------------------------------- the landing of a falling block
                ph := 3;
                act := array[8, x, y, z, aux, coalesce(mc.dyn_concrete_of(aux), aux)];
            else
                ph := 3;
            end if;

            -- push the actions (the first one must come out first)
            ra_n := cardinality(act) / 6;
            for ii in reverse ra_n .. 1 loop
                for jj in 1 .. 6 loop st[sp + jj] := act[(ii - 1) * 6 + jj]; end loop;
                sp := sp + 6;
                if sp + 6 > cardinality(st) then st := st || array_fill(0, array[cardinality(st)]); end if;
            end loop;

            ---------------------------------------------------------------------------------------------------------------------------------------------- drain the stack
            while sp > 0 loop
                op := st[sp - 5]; ax := st[sp - 4]; ay := st[sp - 3]; az := st[sp - 2]; pa := st[sp - 1]; pb := st[sp]; sp := sp - 6;
                tmp := '{}';
                if op = 1 then                                                                          -- WRITE
                    if ay < min_y or ay >= max_y then continue; end if;
                    ci := gm[5 + (((ay >> 4) - sy0) * gm[4] + ((az >> 4) - cz0)) * gm[5] + ((ax >> 4) - cx0) + 1];
                    ix := (((ay & 15) << 8) | ((az & 15) << 4) | (ax & 15)) + 1;
                    old := secs[ci][ix];
                    if old = pa then continue; end if;
                    secs[ci][ix] := pa;
                    ch_n := ch_n + 1; ch_x[ch_n] := ax; ch_y[ch_n] := ay; ch_z[ch_n] := az; ch_new[ch_n] := pa; ch_loud[ch_n] := pb = 1;
                    wrote := wrote + 1;
                    tmp := mc.dyn_on_place(secs, gm, fl, fa, kk, bidv, ax, ay, az, old, pa, fast);
                    if pb = 2 then continue; end if;                                                    -- setBlock with flags 2 (random ticks): the clients are told, nothing is notified
                    foreach d in array array[4, 5, 0, 1, 2, 3] loop                                     -- neighborChanged: WEST EAST DOWN UP NORTH SOUTH
                        qx := ax + mc.dyn_dx(d); qy := ay + mc.dyn_dy(d); qz := az + mc.dyn_dz(d);
                        q := secs[gm[5 + (((qy >> 4) - sy0) * gm[4] + ((qz >> 4) - cz0)) * gm[5] + ((qx >> 4) - cx0) + 1]][(((qy & 15) << 8) | ((qz & 15) << 4) | (qx & 15)) + 1];
                        if (fl[q + 1] & 4) <> 0 then tmp := tmp || mc.dyn_liquid_react(secs, gm, fl, fa, kk, qx, qy, qz, q, fast); end if;
                    end loop;
                    foreach d in array array[4, 5, 2, 3, 0, 1] loop                                     -- updateShape: WEST EAST NORTH SOUTH DOWN UP
                        qx := ax + mc.dyn_dx(d); qy := ay + mc.dyn_dy(d); qz := az + mc.dyn_dz(d);
                        q := secs[gm[5 + (((qy >> 4) - sy0) * gm[4] + ((qz >> 4) - cz0)) * gm[5] + ((qx >> 4) - cx0) + 1]][(((qy & 15) << 8) | ((qz & 15) << 4) | (qx & 15)) + 1];
                        if (fl[q + 1] & (4 | 8 | 4096 | 262144)) <> 0 then tmp := tmp || mc.dyn_notify(secs, gm, fl, fa, kk, bidv, 2, qx, qy, qz, q, mc.dyn_opp(d), pa, fast, rl, stv, tg); end if;
                    end loop;

                elsif op = 2 or op = 3 then                                                             -- SCHED_FLUID / SCHED_BLOCK: ignored when the same tick is pending
                    key := ((ax::int8 & 33554431) << 35) | ((az::int8 & 33554431) << 10) | (ay + 128);
                    found := false;
                    tkc := case when op = 2 then 'f'::"char" else 'b'::"char" end;
                    ii := array_position(pk, key);
                    while ii is not null loop
                        if pt[ii] = pa and pkind[ii] = tkc then found := true; exit; end if;
                        ii := array_position(pk, key, ii + 1);
                    end loop;
                    if not found then
                        pk := pk || key; pt := pt || pa; pkind := pkind || tkc;
                        nt_n := nt_n + 1; nt_x[nt_n] := ax; nt_y[nt_n] := ay; nt_z[nt_n] := az; nt_kind[nt_n] := tkc; nt_type[nt_n] := pa;
                        nt_due[nt_n] := p_cur + pb;
                    end if;

                elsif op = 4 then                                                                       -- EVENT
                    ev_n := ev_n + 1; ev_t[ev_n] := pa; ev_x[ev_n] := ax; ev_y[ev_n] := ay; ev_z[ev_n] := az; ev_d[ev_n] := pb;

                elsif op = 7 then                                                                       -- SPREAD_TO(pos, direction pa, fluid state code pb)
                    q := secs[gm[5 + (((ay >> 4) - sy0) * gm[4] + ((az >> 4) - cz0)) * gm[5] + ((ax >> 4) - cx0) + 1]][(((ay & 15) << 8) | ((az & 15) << 4) | (ax & 15)) + 1];
                    if (pb >> 4) = 1 and pa = 0 and (fl[q + 1] & 8) <> 0 then
                        -- LavaFluid.spreadTo: lava falling onto water turns a liquid block into stone and fizzes
                        if (fl[q + 1] & 4) <> 0 then tmp := array[1, ax, ay, az, kk[5], 0]; end if;
                        tmp := tmp || array[4, ax, ay, az, 1501, 0];
                    elsif (fl[q + 1] & 256) <> 0 then
                        -- LiquidBlockContainer.placeLiquid: a dry waterloggable block takes STILL water
                        if (fl[q + 1] & 128) <> 0 and (fl[q + 1] & 8) = 0 and mc.dyn_ftype(pb) = 0 and wltv[q + 1] >= 0 then
                            tmp := array[1, ax, ay, az, wltv[q + 1], 0, 2, ax, ay, az, 0, 5];
                        end if;
                    else
                        if (fl[q + 1] & 1) = 0 and (pb >> 4) = 1 then tmp := array[4, ax, ay, az, 1501, 0]; end if;     -- LavaFluid.beforeDestroyingBlock: fizz (water drops the block's items: not modelled)
                        tmp := tmp || array[1, ax, ay, az, kk[7 + pb], 0];
                    end if;

                elsif op = 6 then                                                                       -- a falling block (state pa) starts to fall from (ax, ay, az)
                    land_y := null; wet := false;
                    for jj in reverse ay - 1 .. min_y loop                                              -- the first cell below with a collision shape holds the block up
                        if jj < sy0 * 16 then exit; end if;
                        q := secs[gm[5 + (((jj >> 4) - sy0) * gm[4] + ((az >> 4) - cz0)) * gm[5] + ((ax >> 4) - cx0) + 1]][(((jj & 15) << 8) | ((az & 15) << 4) | (ax & 15)) + 1];
                        if (fl[pa + 1] & 65536) <> 0 and (fl[q + 1] & 8) <> 0 then land_y := jj; wet := true; exit; end if;      -- concrete powder stops in the first cell with water in it
                        if coalesce(sk[co[q + 1] + 1], 1) <> 0 then land_y := jj + 1; exit; end if;
                    end loop;
                    if land_y is null and ay - 1 >= sy0 * 16 and sy0 * 16 > min_y then land_y := mc.dyn_floor_db(p_dim, ax, az, sy0 * 16 - 1, min_y); end if;
                    if land_y is not null then
                        loop                                                                            -- a block already on its way to that cell: this one lands on top of it
                            found := false;
                            for jj in 1 .. ln_n loop
                                if ln_x[jj] = ax and ln_z[jj] = az and ln_y[jj] = land_y then found := true; exit; end if;
                            end loop;
                            exit when not found;
                            land_y := land_y + 1;
                        end loop;
                        ln_n := ln_n + 1; ln_x[ln_n] := ax; ln_y[ln_n] := land_y; ln_z[ln_n] := az;
                        nt_n := nt_n + 1; nt_x[nt_n] := ax; nt_y[nt_n] := land_y; nt_z[nt_n] := az; nt_kind[nt_n] := 'l'; nt_type[nt_n] := pa;
                        nt_due[nt_n] := p_cur + (case when wet then mc.dyn_fall_ticks((ay + 0.01) - (land_y + 1), true) else mc.dyn_fall_ticks((ay - land_y) + 0.01, false) end) - 1;
                    end if;                                                                             -- (no floor above the bottom of the world: the block is lost, as the entity would be)

                elsif op = 8 then                                                                       -- a falling block (state pa) lands in (ax, ay, az): FallingBlockEntity.tick
                    q := secs[gm[5 + (((ay >> 4) - sy0) * gm[4] + ((az >> 4) - cz0)) * gm[5] + ((ax >> 4) - cx0) + 1]][(((ay & 15) << 8) | ((az & 15) << 4) | (ax & 15)) + 1];
                    below := secs[gm[5 + ((((ay - 1) >> 4) - sy0) * gm[4] + ((az >> 4) - cz0)) * gm[5] + ((ax >> 4) - cx0) + 1]][((((ay - 1) & 15) << 8) | ((az & 15) << 4) | (ax & 15)) + 1];
                    if (fl[q + 1] & (1 | 2048)) <> 0 and ((fl[below + 1] & (1 | 32768 | 4 | 2048)) = 0 or ((fl[pa + 1] & 65536) <> 0 and (fl[q + 1] & 8) <> 0)) then
                        -- it comes to rest: FallingBlockEntity places the block, sends block_update and add_transient_block to the players tracking it, and ConcretePowderBlock.onLand
                        -- turns powder that lies in or touches water into concrete (pb is the concrete state)
                        tmp := array[1, ax, ay, az, case when wltv[pa + 1] >= 0 and (fl[q + 1] & 8) <> 0 then wltv[pa + 1] else pa end, 0, 4, ax, ay, az, -1, pa];
                        if (fl[pa + 1] & 65536) <> 0 then
                            sc := 0;
                            foreach d in array array[0, 1, 2, 3, 4, 5] loop
                                -- ConcretePowderBlock.touchesLiquid: water on a side or above, and below only when the cell itself holds water
                                if (fl[mc.dyn_at(secs, gm, ax + mc.dyn_dx(d), ay + mc.dyn_dy(d), az + mc.dyn_dz(d)) + 1] & 8) <> 0 and (d <> 0 or (fl[q + 1] & 8) <> 0) then sc := 1; end if;
                            end loop;
                            if sc = 1 or (fl[q + 1] & 8) <> 0 then tmp := tmp || array[1, ax, ay, az, pb, 0]; end if;
                        end if;
                    end if;                                                                             -- (otherwise the entity would drop an item: not modelled)
                end if;
                if cardinality(tmp) > 0 then
                    ra_n := cardinality(tmp) / 6;
                    for ii in reverse ra_n .. 1 loop
                        for jj in 1 .. 6 loop st[sp + jj] := tmp[(ii - 1) * 6 + jj]; end loop;
                        sp := sp + 6;
                        if sp + 6 > cardinality(st) then st := st || array_fill(0, array[cardinality(st)]); end if;
                    end loop;
                end if;
            end loop;
            exit unit when ph >= 3;
        end loop;
    end loop;

    ---------------------------------------------------------------------------------------------------------------------------------------------------- write back
    if ch_n > 0 then
        select coalesce(max(id), 0) into ev_max from mc.block_event;
        perform set_config('mc.dyn_busy', 'on', false);
        perform mc.set_blocks(p_dim, ch_x, ch_y, ch_z, array(select s.name from unnest(ch_new) with ordinality t(sid, o) join mc.dyn_state s on s.sid = t.sid order by t.o));
        perform set_config('mc.dyn_busy', 'off', false);
        -- vanilla's setBlock sends no break effect (level_event 2001); only destroyBlock does.  dbcraft's broadcast sends it for every 'block' event that turns a block into air,
        -- so the changes that are not destructions are re-recorded as one-position 'cells' events, which never get it (same set order, same packets otherwise)
        update mc.block_event e set kind = 'cells', x = (e.x >> 4) * 16, y = (e.y >> 4) * 16, z = (e.z >> 4) * 16,
               cells = mc.box_bitmap(e.x & 15, e.x & 15, e.y & 15, e.y & 15, e.z & 15, e.z & 15)
         where e.id > ev_max and e.kind = 'block' and e.dimension = p_dim
           and not exists (select 1 from unnest(ch_x, ch_y, ch_z, ch_loud) l(x, y, z, loud) where l.x = e.x and l.y = e.y and l.z = e.z and l.loud);
    end if;
    if p_late and ch_n > 0 then
        with moved as (delete from mc.block_event e where e.id > ev_max returning e.id, e.kind, e.dimension, e.x, e.y, e.z, e.old_state, e.new_state, e.cells)
        insert into mc.dyn_late_event (kind, dimension, x, y, z, old_state, new_state, cells) select m.kind, m.dimension, m.x, m.y, m.z, m.old_state, m.new_state, m.cells from moved m order by m.id;
    end if;
    if nt_n > 0 then
        insert into mc.block_tick (dimension, x, y, z, kind, type, due, state)
        select p_dim, t.x, t.y, t.z, t.k, case when t.k = 'f' then (array['minecraft:water', 'minecraft:flowing_water', 'minecraft:lava', 'minecraft:flowing_lava'])[t.ty + 1]
                                               when t.k = 'l' then (select s.name from mc.dyn_state s where s.sid = t.ty)
                                               else (select b.name from mc.dyn_block b where b.bid = t.ty) end, t.due,
               case when t.k = 'l' then (select s.name from mc.dyn_state s where s.sid = t.ty) end
          from unnest(nt_x, nt_y, nt_z, nt_kind, nt_type, nt_due) with ordinality t(x, y, z, k, ty, due, o) order by t.o
        on conflict do nothing;
    end if;
    if ev_n > 0 then perform mc.dyn_level_events(p_dim, ev_t, ev_x, ev_y, ev_z, ev_d); end if;
    return wrote;
end $$;

-- level events (fizz 1501 ...) to the connections that have the chunk in view
create or replace function mc.dyn_level_events(p_dim text, p_t int[], p_x int[], p_y int[], p_z int[], p_d int[]) returns void language plpgsql volatile as $$
declare r int := 4; i_le int := mc.pid('level_event');
begin
    insert into mc.play_out (conn_id, data)
    select c.conn_id, case when e.t = -1 then proto.frame(mc.pid('block_update'), proto.position(e.x, e.y, e.z) || proto.varint(e.d))
                                              || proto.frame(mc.pid('add_transient_block'), proto.position(e.x, e.y, e.z) || proto.varint(e.d))
                           else proto.frame(i_le, proto.i32(e.t) || proto.position(e.x, e.y, e.z) || proto.i32(e.d) || '\x00'::bytea) end
      from unnest(p_t, p_x, p_y, p_z, p_d) with ordinality e(t, x, y, z, d, o)
      join net.conn c on c.state = 'play' and not c.closing and c.view_cx is not null
                      and abs(c.view_cx - (e.x >> 4)) <= (case when e.t = -1 then least(10, mc.prop_int('view-distance')) else r end)
                      and abs(c.view_cz - (e.z >> 4)) <= (case when e.t = -1 then least(10, mc.prop_int('view-distance')) else r end)
     order by e.o, c.conn_id;
end $$;

-- the time a block takes to fall p_need blocks (to the floor: the drop in cells + 0.01 because FallingBlockEntity starts at y + 0.01; to the water a concrete powder block stops in: the
-- distance to the top of that cell, strictly), in entity ticks, the first of which is the tick it was spawned in: each tick adds -0.04 to the vertical velocity, moves, then scales the velocity
-- by 0.98 (doubles, as the game); it lands in the tick whose move reaches the floor
create or replace function mc.dyn_fall_ticks(p_need float8, p_strict boolean default false) returns int language plpgsql immutable parallel safe as $$
declare v float8 := 0; acc float8 := 0; k int := 0;
begin
    loop
        k := k + 1;
        v := v - 0.04;
        acc := acc - v;
        if acc > p_need or (acc = p_need and not p_strict) then return k; end if;
        v := v * 0.98;
        if k > 10000 then return k; end if;
    end loop;
end $$;

-- the cell above the first block with a collision shape, looking down from y = p_from in the column (x, z) of the stored world; null when there is none above the world's bottom
create or replace function mc.dyn_floor_db(p_dim text, x int, z int, p_from int, p_min_y int) returns int language plpgsql stable as $$
declare s record; i int; e int; nm text; yy int; v mc.dyn_vec%rowtype; vsid int;
begin
    select * into v from mc.dyn_vec;
    yy := p_from;
    while yy >= p_min_y loop
        select cs.bits, cs.data, cs.palette into s from mc.chunk_section cs where cs.dimension = p_dim and cs.cx = x >> 4 and cs.cz = z >> 4 and cs.sy = yy >> 4;
        if found then
            i := (((yy & 15) << 8) | ((z & 15) << 4) | (x & 15));
            e := mc.entry_at(s.bits, s.data, i);
            nm := case when s.bits = 0 then s.palette[1] when cardinality(s.palette) = 0 then mc.state_name(e) else s.palette[e + 1] end;
            select d.sid into vsid from mc.dyn_state d where d.name = nm;
            if coalesce(v.skind[v.coll[vsid + 1] + 1], 1) <> 0 then return yy + 1; end if;
        end if;
        yy := yy - 1;
    end loop;
    return null;
end $$;

-- ConcretePowderBlock -> its concrete (the state id of the concrete block), null for any other block
create or replace function mc.dyn_concrete_of(p_sid int) returns int language sql stable as $$
  select (select b.default_state from ref.block b where b.name = replace(s.block, '_concrete_powder', '_concrete'))
    from mc.dyn_state s where s.sid = p_sid and s.chain like 'ConcretePowderBlock%' $$;
