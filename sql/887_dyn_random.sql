-- World dynamics, part 8: random ticks (ServerLevel.tickChunk).
--
-- Vanilla, every tick, for every chunk a player simulates: for every section that holds a randomly ticking block, randomTickSpeed (gamerule, default 3) times a uniformly random
-- position of the section; when the block there is randomly ticking its randomTick runs.  This does the same with the same distribution, but only for the cells whose random tick
-- can CHANGE something (the "active" cells), because the tick of any other cell is a no-op and skipping a no-op changes nothing:
--   * grass block / mycelium: active when it dies (water or an opaque block above it) or when some dirt in its 3 x 5 x 3 spreading volume can turn into grass (the dirt has no opaque
--     block and no water above it); a plain grass field with nothing exposed has no active cell,
--   * crops and saplings: active until they have no next age / stage,
--   * farmland: active unless it is fully wet (moisture 7) with water within reach.
-- The list of active cells of a section is built (mc.dyn_rt_build) when its chunk is new or a block changed in it or within 4 cells of it (mc.dyn_rt_dirty is filled by the statement
-- trigger of sql/885 and by a trigger on new chunks) and kept in mc.dyn_rt_sec (only sections with at least one active cell have a row).  A run then is: the number of hits is Poisson
-- distributed with mean n * (active cells in range) / 4096 (n = random_tick_speed * 3 draws per section and tick, times the interval), each hit lands in a section with probability
-- proportional to its active cells, at a uniformly random one of them: O(hits) work, and next to nothing when no active cell is near a player.  All online players' areas are served.
-- The hits of one run are capped (a random subset, so a very large farm ticks slower than vanilla's rate): dbcraft.random-tick-max-hits per tick.
--
-- Implemented behaviours (the classes read in the 26.3 bytecode): grass block and mycelium (spread to dirt, die to dirt), crops (CropBlock growth formula), farmland (moisture, back to
-- dirt), saplings (stage 0 -> 1).  Everything else that ticks randomly in vanilla (leaf decay, sugar cane, cactus, vines, kelp, ice and snow melting, fire, lava fire, copper
-- oxidation, budding amethyst, ...) does nothing here.  Light: a cell has sky light 15 (less the sky darkness) when no block that stops motion or holds fluid, leaves excepted, is above it
-- (the MOTION_BLOCKING_NO_LEAVES heightmap); nothing else gives light (no torches, no attenuation by water or leaves).
-- It is STATISTICAL: vanilla's random numbers are not reproduced, only the rules (docs/WORLD-DYNAMICS.md checks them with distributions).

insert into mc.server_property (key, value, default_value, note) values
    ('dbcraft.random-tick-max-hits', '6', '6', 'dbcraft: at most this many random-tick hits are processed per tick (a random subset when there are more: the rate of every block drops proportionally)'),
    ('dbcraft.random-tick-interval', '4', '4', 'dbcraft: random ticks run every this many ticks, with that many ticks of draws at once (1 = every tick, vanilla timing)')
on conflict (key) do nothing;

-- derived data, rebuilt from the dirty queue: forget what an older version of this file stored
drop table if exists mc.dyn_rt_sec;
create table mc.dyn_rt_sec (dimension text not null, cx int not null, sy int not null, cz int not null, version bigint not null, cnt int not null, cells smallint[] not null, primary key (dimension, cx, cz, sy));
drop table if exists mc.dyn_rt_chunk;
create table mc.dyn_rt_chunk (dimension text not null, cx int not null, cz int not null, version bigint not null, primary key (dimension, cx, cz));
insert into mc.dyn_rt_dirty (dimension, cx, cz) select c.dimension, c.cx, c.cz from mc.chunk c on conflict (dimension, cx, cz) do update set seq = excluded.seq;
create index if not exists player_online_chunk_idx on mc.player (chunk_x, chunk_z) where conn_id is not null;

-- every new chunk, and its eight neighbours (their border cells see new neighbours), are queued for a rebuild of their lists
create or replace function mc.dyn_rt_chunk_new() returns trigger language plpgsql volatile as $$
begin
    insert into mc.dyn_rt_dirty (dimension, cx, cz)
    select distinct n.dimension, n.cx + dx.v, n.cz + dz.v from new_c n, (values (-1), (0), (1)) dx(v), (values (-1), (0), (1)) dz(v)
    on conflict (dimension, cx, cz) do update set seq = excluded.seq;
    return null;
end $$;
drop trigger if exists dyn_rt_chunk_new on mc.chunk;
create trigger dyn_rt_chunk_new after insert on mc.chunk referencing new table as new_c for each statement execute function mc.dyn_rt_chunk_new();

-- the sid of the state of the same block as p_sid with snowy = p_snowy (grass block, mycelium)
create or replace function mc.dyn_sid_snowy(p_sid int, p_snowy boolean) returns int language sql stable as $$
  select n.sid from mc.dyn_state s join mc.dyn_state n on n.name = replace(replace(s.name, 'snowy=true', 'snowy=' || p_snowy::text), 'snowy=false', 'snowy=' || p_snowy::text) where s.sid = p_sid $$;

-- Level.getSkyDarken as updateSkyBrightness computes it: 1 - (0.5 + 2 * clamp(cos(timeOfDay * 2 pi), -0.25, 0.25)) * rain * thunder, scaled to 0 .. 11 (rain and thunder levels: 0 or 1 here)
create or replace function mc.dyn_sky_darken() returns int language plpgsql stable as $$
declare g mc.game_state%rowtype; d float8; tod float8; f float8;
begin
    select * into g from mc.game_state;
    d := (g.day_time % 24000) / 24000.0 - 0.25;
    d := d - floor(d);                                                                  -- Mth.frac
    tod := (d * 2.0 + (0.5 - cos(d * pi()) / 2.0)) / 3.0;                                -- Dimension.timeOfDay
    f := 0.5 + 2.0 * greatest(-0.25, least(0.25, cos(tod * 2 * pi())));
    return ((1.0 - f * (1.0 - case when g.raining then 5.0 / 16 else 0 end) * (1.0 - case when g.thundering then 5.0 / 16 else 0 end)) * 11)::int;
end $$;

-- The list of active cells (see above) of every section of the chunk (p_cx, p_cz) that holds a state of a class this file implements: reads the chunk and its eight neighbours.
create or replace function mc.dyn_rt_build(p_dim text, p_cx int, p_cz int) returns void language plpgsql volatile as $$
declare
    v     mc.dyn_vec%rowtype;
    fl    int4[]; fa int2[]; kk int4[]; tg int8[]; npv int4[]; ld int2[];
    ver   bigint; sys int[]; sy0 int; sy1 int; nsy int; secs int4[]; gm int4[];
    ii int; s int; rw int; cand int[]; act smallint[]; k int; i int; x int; y int; z int; lx int; ly int; lz int; cell int; ab int; a2 int; q int;
    ex_x int[]; ex_y int[]; ex_z int[]; ex_n int; dpos int[]; hit boolean; dx int; dy int; dz int; m1 int; need_ex boolean; found boolean;
begin
    select version into ver from mc.chunk where dimension = p_dim and cx = p_cx and cz = p_cz;
    delete from mc.dyn_rt_sec where dimension = p_dim and cx = p_cx and cz = p_cz;
    if ver is null then
        delete from mc.dyn_rt_chunk where dimension = p_dim and cx = p_cx and cz = p_cz;
        return;
    end if;
    select * into v from mc.dyn_vec;
    fl := v.flags; fa := v.famt; kk := v.k; tg := v.tagbits; npv := v.nextp; ld := v.lightd;
    select array_agg(cs.sy order by cs.sy) into sys from mc.chunk_section cs
     where cs.dimension = p_dim and cs.cx = p_cx and cs.cz = p_cz and cardinality(cs.palette) > 0
       and exists (select 1 from unnest(cs.palette) pn join mc.dyn_state d on d.name = pn where (fl[d.sid + 1] & 7864320) <> 0);     -- 524288 | 1048576 | 2097152 | 4194304
    if sys is not null then
        sy0 := sys[1] - 1; sy1 := sys[cardinality(sys)] + 1; nsy := sy1 - sy0 + 1;
        secs := mc.dyn_secs(p_dim, p_cx - 1, p_cx + 1, sy0, sy1, p_cz - 1, p_cz + 1, array(select generate_series(1, 9 * nsy)));
        gm := array[sy0, p_cz - 1, p_cx - 1, 3, 3] || array(select generate_series(2, 9 * nsy + 1));
        for ii in 1 .. cardinality(sys) loop
            s := sys[ii];
            rw := gm[5 + ((s - sy0) * 3 + 1) * 3 + 2];
            select array_agg(u.o - 1) into cand from unnest(secs[rw:rw][1:4096]) with ordinality u(c, o) where (fl[u.c + 1] & 7864320) <> 0;
            if cand is null then continue; end if;
            act := '{}';
            -- exposed dirt of this section (grass spreads to dirt that has no opaque block and no water above it)
            ex_x := '{}'; ex_y := '{}'; ex_z := '{}'; ex_n := 0;
            select exists (select 1 from unnest(cand) c where (fl[secs[rw][c + 1] + 1] & 524288) <> 0) into need_ex;
            if need_ex then
                select array_agg(u.o - 1) into dpos from unnest(secs[rw:rw][1:4096]) with ordinality u(c, o) where u.c = kk[41];
                for k in 1 .. coalesce(cardinality(dpos), 0) loop
                    i := dpos[k]; lx := i & 15; lz := (i >> 4) & 15; ly := i >> 8;
                    x := p_cx * 16 + lx; y := s * 16 + ly; z := p_cz * 16 + lz;
                    a2 := case when ly < 15 then secs[rw][i + 256 + 1] else mc.dyn_at(secs, gm, x, y + 1, z) end;
                    if (a2 = kk[50] or not ((fl[a2 + 1] & 8) <> 0 and mc.dyn_famount(mc.dyn_fstate(fl, fa, a2)) = 8 or ld[a2 + 1] >= 15)) and (fl[a2 + 1] & 8) = 0 then
                        ex_n := ex_n + 1; ex_x[ex_n] := x; ex_y[ex_n] := y; ex_z[ex_n] := z;
                    end if;
                end loop;
            end if;
            for k in 1 .. cardinality(cand) loop
                i := cand[k]; lx := i & 15; lz := (i >> 4) & 15; ly := i >> 8;
                x := p_cx * 16 + lx; y := s * 16 + ly; z := p_cz * 16 + lz;
                cell := secs[rw][i + 1];
                hit := false;
                if (fl[cell + 1] & 524288) <> 0 then
                    ab := mc.dyn_at(secs, gm, x, y + 1, z);
                    if ab <> kk[50] and ((fl[ab + 1] & 8) <> 0 and mc.dyn_famount(mc.dyn_fstate(fl, fa, ab)) = 8 or ld[ab + 1] >= 15) then hit := true;                  -- it dies
                    elsif lx = 0 or lx = 15 or lz = 0 or lz = 15 or ly < 3 or ly > 13 then
                        -- the spreading volume reaches into a neighbour section: look at every cell
                        <<vol>>
                        for dy in -3 .. 1 loop
                            for dz in -1 .. 1 loop
                                for dx in -1 .. 1 loop
                                    if mc.dyn_at(secs, gm, x + dx, y + dy, z + dz) = kk[41] then
                                        m1 := mc.dyn_at(secs, gm, x + dx, y + dy + 1, z + dz);
                                        if (m1 = kk[50] or not ((fl[m1 + 1] & 8) <> 0 and mc.dyn_famount(mc.dyn_fstate(fl, fa, m1)) = 8 or ld[m1 + 1] >= 15)) and (fl[m1 + 1] & 8) = 0 then hit := true; exit vol; end if;
                                    end if;
                                end loop;
                            end loop;
                        end loop;
                    else
                        for q in 1 .. ex_n loop
                            if abs(ex_x[q] - x) <= 1 and abs(ex_z[q] - z) <= 1 and ex_y[q] - y between -3 and 1 then hit := true; exit; end if;
                        end loop;
                    end if;
                elsif (fl[cell + 1] & 1048576) <> 0 or (fl[cell + 1] & 4194304) <> 0 then
                    hit := npv[cell + 1] >= 0;                                                       -- a crop that can age, a sapling at stage 0
                elsif (fl[cell + 1] & 2097152) <> 0 then
                    m1 := cell - kk[42];                                                             -- the moisture of this state
                    found := false;
                    <<wat>>
                    for dx in -4 .. 4 loop
                        for dz in -4 .. 4 loop
                            for dy in 0 .. 1 loop
                                if (fl[mc.dyn_at(secs, gm, x + dx, y + dy, z + dz) + 1] & 8) <> 0 then found := true; exit wat; end if;
                            end loop;
                        end loop;
                    end loop;
                    if found then hit := m1 < 7;
                    else hit := m1 > 0 or ((tg[mc.dyn_at(secs, gm, x, y + 1, z) + 1] >> 8) & 1) = 0; end if;
                end if;
                if hit then act := act || i::smallint; end if;
            end loop;
            if cardinality(act) > 0 then
                insert into mc.dyn_rt_sec (dimension, cx, sy, cz, version, cnt, cells) values (p_dim, p_cx, s, p_cz, ver, cardinality(act), act);
            end if;
        end loop;
    end if;
    insert into mc.dyn_rt_chunk (dimension, cx, cz, version) values (p_dim, p_cx, p_cz, ver)
    on conflict (dimension, cx, cz) do update set version = excluded.version;
end $$;

create or replace function mc.dyn_random_ticks(p_cur bigint) returns void language plpgsql volatile as $$
declare
    speed  int := mc.rule_int('random_tick_speed', 3);
    r      int := mc.prop_int('simulation-distance');
    cap    int := coalesce(mc.prop_int('dbcraft.random-tick-max-hits'), 6);
    iv     int := greatest(coalesce(mc.prop_int('dbcraft.random-tick-interval'), 4), 1);
    budget int := greatest(coalesce(mc.prop_int('dbcraft.random-tick-chunk-budget'), 4), 1);
    dim    text;
    dcx int[]; dcz int[]; acx int[]; asy int[]; acz int[]; acnt int[];
    hcx int[]; hsy int[]; hcz int[]; hidx int[]; hsid int[];
    kinds int[]; xs int[]; ys int[]; zs int[]; aux int[]; hs int[];
    wtot bigint; ew float8; lim int; h int; l float8; pr float8; i int;
begin
    if speed <= 0 or p_cur % iv <> 0 then return; end if;                               -- every iv-th tick, with iv ticks' worth of draws
    if not exists (select 1 from mc.player where conn_id is not null) then return; end if;
    dim := coalesce((select default_dimension from mc.world limit 1), 'minecraft:overworld');
    -- once in a while: chunks whose cached version is not the chunk's (an edit that did not go through mc.block_event) are queued again
    if p_cur % 1200 < iv then
        insert into mc.dyn_rt_dirty (dimension, cx, cz)
        select c.dimension, c.cx, c.cz from mc.chunk c left join mc.dyn_rt_chunk k on k.dimension = c.dimension and k.cx = c.cx and k.cz = c.cz
         where c.dimension = dim and k.version is distinct from c.version on conflict (dimension, cx, cz) do update set seq = excluded.seq;
    end if;
    -- rebuild the lists of the queued chunks, at most `budget` per run (fresh terrain, or the first run after an upgrade, does not make one tick pay for all of it).  Every queued chunk is
    -- built, near a player or not (a queue that is mostly empty costs one probe, a queue with chunks nobody is near would cost a scan per run), the newest change first: an edit near a player
    -- does not wait behind the backlog of an upgrade or of terrain nobody is near.
    if exists (select 1 from mc.dyn_rt_dirty) then
        select array_agg(q.cx), array_agg(q.cz) into dcx, dcz from (select d.cx, d.cz from mc.dyn_rt_dirty d where d.dimension = dim order by d.seq desc limit budget) q;
        if dcx is not null then
            for i in 1 .. cardinality(dcx) loop perform mc.dyn_rt_build(dim, dcx[i], dcz[i]); end loop;
            delete from mc.dyn_rt_dirty d using unnest(dcx, dcz) u(cx, cz) where d.dimension = dim and d.cx = u.cx and d.cz = u.cz;
        end if;
    end if;
    -- the active sections in range of any online player
    select array_agg(t.cx order by t.cx, t.sy, t.cz), array_agg(t.sy order by t.cx, t.sy, t.cz), array_agg(t.cz order by t.cx, t.sy, t.cz), array_agg(t.cnt order by t.cx, t.sy, t.cz), coalesce(sum(t.cnt), 0)
      into acx, asy, acz, acnt, wtot
      from (select a.cx, a.sy, a.cz, a.cnt from mc.dyn_rt_sec a
             where a.dimension = dim and exists (select 1 from mc.player p where p.conn_id is not null and p.chunk_x between a.cx - r and a.cx + r and p.chunk_z between a.cz - r and a.cz + r)) t;
    if wtot = 0 then return; end if;
    -- vanilla draws speed * 3 positions per section and tick; a draw hits an active cell with probability cnt / 4096: the number of hits of the area is Poisson (mean ew), capped at lim
    lim := cap * iv;
    ew := speed * 3.0 * iv * wtot / 4096.0;
    if ew > 2 * lim then h := lim;
    else
        l := exp(-ew); pr := 1; h := 0;
        loop pr := pr * random(); exit when pr <= l or h >= lim; h := h + 1; end loop;
    end if;
    if h = 0 then return; end if;
    with cand as (select t.cx, t.sy, t.cz, t.cnt, sum(t.cnt) over (order by t.cx, t.sy, t.cz) as cum from unnest(acx, asy, acz, acnt) t(cx, sy, cz, cnt)),
         pick as materialized (select random() * wtot as u from generate_series(1, h) g),
         hit as (select c.cx, c.sy, c.cz, a.cells[1 + floor(random() * c.cnt)::int]::int as idx
                   from pick p join cand c on p.u >= c.cum - c.cnt and p.u < c.cum
                   join mc.dyn_rt_sec a on a.dimension = dim and a.cx = c.cx and a.cz = c.cz and a.sy = c.sy),
         named as (select hh.cx, hh.sy, hh.cz, hh.idx, case when cs.bits = 0 then cs.palette[1] else cs.palette[mc.entry_at(cs.bits, cs.data, hh.idx) + 1] end as nm
                     from hit hh join mc.chunk_section cs on cs.dimension = dim and cs.cx = hh.cx and cs.cz = hh.cz and cs.sy = hh.sy)
    select array_agg(n.cx), array_agg(n.sy), array_agg(n.cz), array_agg(n.idx), array_agg(ds.sid)
      into hcx, hsy, hcz, hidx, hsid from named n join mc.dyn_state ds on ds.name = n.nm;
    if hcx is null then return; end if;
    -- the heightmaps that tell where the sky is open must be current, for the chunks of the hits only
    perform mc.ensure_chunk_current(dim, q.a, q.b) from (select distinct a, b from unnest(hcx, hcz) u(a, b)) q;
    select array_agg(3), array_agg(u.cx * 16 + (u.idx & 15)), array_agg(u.sy * 16 + (u.idx >> 8)), array_agg(u.cz * 16 + ((u.idx >> 4) & 15)), array_agg(u.sid),
           array_agg(coalesce(ch.hm_motion_blocking_no_leaves[(u.idx & 15) + 16 * ((u.idx >> 4) & 15) + 1], 0) + (select min_y from mc.dimension where name = dim))
      into kinds, xs, ys, zs, aux, hs
      from unnest(hcx, hsy, hcz, hidx, hsid) u(cx, sy, cz, idx, sid) left join mc.chunk ch on ch.dimension = dim and ch.cx = u.cx and ch.cz = u.cz;
    perform mc.dyn_run(dim, p_cur, kinds, xs, ys, zs, aux, false, hs, mc.dyn_sky_darken());
end $$;
