-- A seeded, deterministic terrain generator for the overworld: layered value noise, believable but NOT vanilla's terrain (docs/WORLD.md "Terrain generator").
--
--   dbcraft.generator           server setting (mc.server_property): minecraft:flat (default, byte-identical to before) or dbcraft:noise.  A trigger applies it to the
--                               overworld's mc.dimension.generator and moves the spawn onto the surface; chunks that already exist are not touched.
--   mc.world.seed               the seed (update mc.world set seed = N before generating); the same seed always makes the same chunks
--   mc.generate_noise_batch     the generator function registered as 'dbcraft:noise' (mc.generator): (dimension, cxs[], czs[], replace) -> chunks created
--
-- What a chunk is made of:
--   * Height: value noise at four scales (continents 512 blocks, hill amplitude 256, hills 96, detail 32), sampled every 4 blocks (a 5 x 5 grid of samples per chunk on the
--     global 4-block lattice, so neighbouring chunks agree on their border) and interpolated to the 256 columns with a smoothstep, as vanilla interpolates its noise cells.
--   * Climate: temperature and humidity noise (420 and 300 blocks) pick one of 16 real biomes per 4 x 4 cell (oceans by depth and temperature, beach, desert, savanna, snowy
--     plains, taiga, forest, plains, windswept hills, snowy slopes, jagged peaks); the biome is constant over the height of the cell.
--   * Blocks by column: grass over 3 dirt (plains, forest, taiga, snowy plains, savanna), sand over sandstone (desert, beach), bare stone (windswept hills), snow block over stone
--     (peaks), sand or gravel with 2 below under water; stone below; sea level 63 (water up to y 62); deepslate below y 0; bedrock on y -64 and up to y -60 (the number of layers
--     per column from a hash, probabilities 1, .8, .6, .4, .2 as vanilla's).  No caves, ores, trees, structures, decoration or fluids flow.
--   * Heightmaps are written with the chunk (WORLD_SURFACE = MOTION_BLOCKING = NO_LEAVES = the higher of the surface and the water); light stays the straight-down model.
-- Section rows are built as text: every column is a character, a plane (the 256 entries of one y) is a TRANSLATE of that string, and the hex of the 16 planes IS the packed data
-- (4 bits per entry, the nibble order of the wire format is the reverse of the x order inside a row).  Sections that are all stone or all deepslate are single-value rows.

insert into mc.server_property (key, value, default_value, note) values
    ('dbcraft.generator', 'minecraft:flat', 'minecraft:flat', 'dbcraft: the overworld''s terrain generator for chunks generated from now on: minecraft:flat or dbcraft:noise (seeded value noise, not vanilla terrain; seed in mc.world.seed)')
on conflict (key) do nothing;

------------------------------------------------------------------------------------------------ noise
-- Value noise in [0, 1): a 31-bit integer hash (xorshift and multiply rounds of x, z, a salt and the seed; every product stays below 2^62) at the lattice points of the
-- given period, smoothstep-interpolated.  PL/pgSQL on purpose: written as nested SQL functions the planner inlines every use of every intermediate value (a hash
-- became 8 copies of itself, 0.5 ms per noise value instead of 8 us).
create or replace function mc.t_vnoise(seed bigint, salt int, x float8, z float8, period float8) returns float8 language plpgsql immutable parallel safe as $$
declare
    u  float8 := x / period;
    v  float8 := z / period;
    i  int := floor(u)::int;
    j  int := floor(v)::int;
    fu float8 := u - i;
    fv float8 := v - j;
    su float8 := fu * fu * (3 - 2 * fu);
    sv float8 := fv * fv * (3 - 2 * fv);
    s31 bigint := (seed # (seed >> 32)) & 2147483647;
    h  bigint;
    n00 float8; n10 float8; n01 float8; n11 float8;
begin
    h := ((i::bigint * 374761393 + j::bigint * 668265263 + salt::bigint * 1274126177 + s31) & 2147483647);
    h := ((h # (h >> 15)) * 1274126177) & 2147483647; h := ((h # (h >> 13)) * 668265263) & 2147483647; n00 := (h # (h >> 16))::float8 / 2147483648.0;
    h := (((i + 1)::bigint * 374761393 + j::bigint * 668265263 + salt::bigint * 1274126177 + s31) & 2147483647);
    h := ((h # (h >> 15)) * 1274126177) & 2147483647; h := ((h # (h >> 13)) * 668265263) & 2147483647; n10 := (h # (h >> 16))::float8 / 2147483648.0;
    h := ((i::bigint * 374761393 + (j + 1)::bigint * 668265263 + salt::bigint * 1274126177 + s31) & 2147483647);
    h := ((h # (h >> 15)) * 1274126177) & 2147483647; h := ((h # (h >> 13)) * 668265263) & 2147483647; n01 := (h # (h >> 16))::float8 / 2147483648.0;
    h := (((i + 1)::bigint * 374761393 + (j + 1)::bigint * 668265263 + salt::bigint * 1274126177 + s31) & 2147483647);
    h := ((h # (h >> 15)) * 1274126177) & 2147483647; h := ((h # (h >> 13)) * 668265263) & 2147483647; n11 := (h # (h >> 16))::float8 / 2147483648.0;
    return n00 + (n10 - n00) * su + (n01 - n00) * sv + (n00 - n10 - n01 + n11) * su * sv;
end $$;

-- A hash in [0, 1) of two integers and a salt (bedrock layers), the same rounds.
create or replace function mc.t_hash(seed bigint, a int, b int, salt int) returns float8 language plpgsql immutable parallel safe as $$
declare h bigint := ((a::bigint * 374761393 + b::bigint * 668265263 + salt::bigint * 1274126177 + ((seed # (seed >> 32)) & 2147483647)) & 2147483647);
begin
    h := ((h # (h >> 15)) * 1274126177) & 2147483647; h := ((h # (h >> 13)) * 668265263) & 2147483647;
    return (h # (h >> 16))::float8 / 2147483648.0;
end $$;

-- The terrain at one point of the 4-block lattice: the height (continuous), temperature and humidity.
create or replace function mc.t_sample(seed bigint, wx int, wz int, out h float8, out temp float8, out hum float8) language plpgsql immutable parallel safe as $$
declare c float8 := mc.t_vnoise(seed, 1, wx, wz, 512); m float8 := mc.t_vnoise(seed, 2, wx, wz, 256); hl float8 := mc.t_vnoise(seed, 3, wx, wz, 96); dt float8 := mc.t_vnoise(seed, 4, wx, wz, 32);
begin
    h := 67 + 56 * (c - 0.5) + (8 + 70 * m * m) * 2 * (hl - 0.5) + 8 * (dt - 0.5);
    temp := mc.t_vnoise(seed, 5, wx, wz, 420);
    hum := mc.t_vnoise(seed, 6, wx, wz, 300);
end $$;

-- The biome of a lattice cell, as its position in mc.terrain_biomes(): 1 deep ocean, 2 ocean, 3 cold ocean, 4 frozen ocean, 5 lukewarm ocean, 6 warm ocean, 7 beach, 8 desert,
-- 9 savanna, 10 snowy plains, 11 taiga, 12 forest, 13 plains, 14 windswept hills, 15 snowy slopes, 16 jagged peaks.
create or replace function mc.t_biome(h int, temp float8, hum float8) returns int language plpgsql immutable parallel safe as $$
declare t float8 := temp - greatest(0, h - 90) / 150.0;          -- colder with altitude
begin
    return case
        when h < 45 then 1
        when h < 59 then case when t < 0.15 then 4 when t < 0.35 then 3 when t < 0.75 then 2 when t < 0.9 then 5 else 6 end
        when h < 65 then 7
        when h >= 125 then 16
        when h >= 100 then case when t < 0.3 then 15 else 14 end
        when t > 0.72 then case when hum < 0.45 then 8 else 9 end
        when t < 0.22 then 10
        when t < 0.38 and hum > 0.45 then 11
        when hum > 0.58 then 12
        else 13 end;
end $$;

create or replace function mc.terrain_biomes() returns text[] language sql immutable parallel safe as $$
  select array['minecraft:deep_ocean', 'minecraft:ocean', 'minecraft:cold_ocean', 'minecraft:frozen_ocean', 'minecraft:lukewarm_ocean', 'minecraft:warm_ocean', 'minecraft:beach',
               'minecraft:desert', 'minecraft:savanna', 'minecraft:snowy_plains', 'minecraft:taiga', 'minecraft:forest', 'minecraft:plains', 'minecraft:windswept_hills',
               'minecraft:snowy_slopes', 'minecraft:jagged_peaks'] $$;

-- The surface profile of a column: 0 grass over dirt, 1 sand over sandstone, 2 bare stone, 3 sand floor, 4 snow over stone, 5 gravel floor (the character of depth d below the
-- top block is substr(profile, d + 1, 1); the palette indices are '0' air, '1' stone, '2' dirt, '3' grass block, '4' sand, '5' gravel, '6' water, '7' sandstone, '8' snow block).
create or replace function mc.t_profile(t int) returns text language sql immutable parallel safe as $$
  select (array['32221111', '44447777', '11111111', '44411111', '81111111', '55511111'])[t + 1] $$;

-- (The column type -- which of the profiles above a column gets -- is decided inline by the generator from the class of its cell's biome and its height: grass-like biomes 0,
-- desert and beach 1, windswept hills 2, snowy slopes and peaks 4, oceans and everything that ends below y 62 a sand floor from height 46 up and a gravel floor below it.)

-- The generated surface height of one column (the same arithmetic the generator uses for its 256 columns), for spawn searches and tests.
create or replace function mc.terrain_height(seed bigint, wx int, wz int) returns int language plpgsql immutable parallel safe as $$
declare
    gx int := floor(wx / 4.0)::int * 4;
    gz int := floor(wz / 4.0)::int * 4;
    fu float8 := (wx - gx) / 4.0;
    fv float8 := (wz - gz) / 4.0;
    su float8 := fu * fu * (3 - 2 * fu);
    sv float8 := fv * fv * (3 - 2 * fv);
    h00 float8; h10 float8; h01 float8; h11 float8;
begin
    h00 := (mc.t_sample(seed, gx, gz)).h; h10 := (mc.t_sample(seed, gx + 4, gz)).h; h01 := (mc.t_sample(seed, gx, gz + 4)).h; h11 := (mc.t_sample(seed, gx + 4, gz + 4)).h;
    return least(250, greatest(8, floor(h00 + (h10 - h00) * su + (h01 - h00) * sv + (h00 - h10 - h01 + h11) * su * sv)::int));
end $$;

------------------------------------------------------------------------------------------------ the generator
create or replace function mc.generate_noise_batch(p_dim text, p_cxs int[], p_czs int[], p_replace boolean default false) returns int language plpgsql volatile as $$
declare
    seed     bigint := coalesce((select w.seed from mc.world w where w.name = 'world'), 0);
    d        mc.dimension;
    bnames   text[] := mc.terrain_biomes();
    bids     int[];
    qx int; qz int;
    sh float8[] := array_fill(0::float8, array[25]); st float8[] := array_fill(0::float8, array[25]); su_ float8[] := array_fill(0::float8, array[25]);                                -- the 25 samples: height, temperature, humidity (index j * 5 + i + 1)
    hs       int[] := array_fill(0, array[256]);                           -- 256 column heights, index z * 16 + x + 1
    tys      int[] := array_fill(0, array[256]);                                                        -- 256 column types
    cell     int[] := array_fill(0, array[16]);                            -- 16 cell biomes (positions in bnames), index cj * 4 + ci + 1
    ccl      int[] := array_fill(0, array[16]);
    smp      record; bz int; ii int; jj int; ci int; hh int; ty int; su float8; sv float8; h00 float8; h10 float8; h01 float8; h11 float8;
    wt       float8[] := array[0, 0.15625, 0.5, 0.84375];                  -- smoothstep at 0, 1/4, 2/4, 3/4
    chunks   mc.chunk[] := '{}';
    secs     mc.chunk_section[] := '{}';
    minh int; maxh int; top int; first_b int; last_b int; sy int; yy int;
    bpal     text[]; bbits int; bdata bytea; distinct_b int[];
    s_cols   text; from_c text; to_c text; planes text; cls int[]; nonair int; fluid int;
    -- palette entries are canonical state names (grass_block[snowy=false], water[level=0], deepslate[axis=y])
    pal9     text[] := array['minecraft:air', 'minecraft:stone', 'minecraft:dirt', 'minecraft:grass_block[snowy=false]', 'minecraft:sand', 'minecraft:gravel', 'minecraft:water[level=0]', 'minecraft:sandstone', 'minecraft:snow_block'];
    pdeep    text := 'minecraft:deepslate[axis=y]';
    ws       smallint[];
    bdraw    text;
    n        int := 0;                                                    -- chunks created
    k        int;
    made_x   int[] := '{}'; made_z int[] := '{}';                          -- ... and which
    y        int;
begin
    if p_cxs is null or cardinality(p_cxs) = 0 then return 0; end if;
    select * into d from mc.dimension where name = p_dim;
    if not found then raise exception 'unknown dimension %', p_dim; end if;
    if d.min_y <> -64 or d.height <> 384 then raise exception 'dbcraft:noise generates the overworld shape (min_y -64, height 384), not dimension % (min_y %, height %)', p_dim, d.min_y, d.height; end if;
    bids := array(select (select b.id from mc.biome b where b.name = u.n) from unnest(bnames) with ordinality u(n, o) order by o);
    if array_position(bids, null) is not null then raise exception 'the biome registry lacks one of the terrain biomes: %', bnames; end if;
    if p_replace then
        delete from mc.chunk c using unnest(p_cxs, p_czs) u(cx, cz) where c.dimension = p_dim and c.cx = u.cx and c.cz = u.cz;
    end if;
    -- the chunks that do not exist yet, each once
    for qx, qz in select distinct u.cx, u.cz from unnest(p_cxs, p_czs) u(cx, cz) where not exists (select 1 from mc.chunk c where c.dimension = p_dim and c.cx = u.cx and c.cz = u.cz) order by 1, 2 loop
        ------------------------------------------------------------ the 5 x 5 lattice samples
        for jj in 0 .. 4 loop
            for ii in 0 .. 4 loop
                smp := mc.t_sample(seed, qx * 16 + 4 * ii, qz * 16 + 4 * jj);
                sh[jj * 5 + ii + 1] := smp.h; st[jj * 5 + ii + 1] := smp.temp; su_[jj * 5 + ii + 1] := smp.hum;
            end loop;
        end loop;
        ------------------------------------------------------------ cells: biome of the lower-left lattice point of each 4 x 4 cell, and what it makes of a column
        for jj in 0 .. 3 loop
            for ii in 0 .. 3 loop
                bz := mc.t_biome(floor(sh[jj * 5 + ii + 1])::int, st[jj * 5 + ii + 1], su_[jj * 5 + ii + 1]);
                cell[jj * 4 + ii + 1] := bz;
                ccl[jj * 4 + ii + 1] := case when bz in (7, 8) then 1 when bz = 14 then 2 when bz in (15, 16) then 4 when bz <= 6 then 9 else 0 end;
            end loop;
        end loop;
        ------------------------------------------------------------ the 256 columns: smoothstep-bilinear from the four corners of their cell
        minh := 999; maxh := 0;
        for jj in 0 .. 15 loop
            sv := wt[jj % 4 + 1];
            for ii in 0 .. 15 loop
                su := wt[ii % 4 + 1];
                ci := (jj / 4) * 5 + ii / 4 + 1;
                h00 := sh[ci]; h10 := sh[ci + 1]; h01 := sh[ci + 5]; h11 := sh[ci + 6];
                hh := least(250, greatest(8, floor(h00 + (h10 - h00) * su + (h01 - h00) * sv + (h00 - h10 - h01 + h11) * su * sv)::int));
                hs[jj * 16 + ii + 1] := hh;
                ty := ccl[(jj / 4) * 4 + ii / 4 + 1];
                tys[jj * 16 + ii + 1] := case when hh < 62 or ty = 9 then (case when hh >= 46 then 3 else 5 end) else ty end;
                if hh < minh then minh := hh; end if;
                if hh > maxh then maxh := hh; end if;
            end loop;
        end loop;
        top := greatest(maxh, 62);
        first_b := greatest(0, floor((minh - 7) / 16.0)::int);
        last_b := top >> 4;
        ------------------------------------------------------------ biome container (the same for every section of the chunk)
        distinct_b := array(select distinct bids[c] from unnest(cell) c order by 1);
        -- more than 8 biomes in one chunk cannot be a palette container: the rare cells fall back to the most common biome
        if cardinality(distinct_b) > 8 then
            distinct_b := array(select bid from (select bids[c] as bid, count(*) n from unnest(cell) c group by 1 order by 2 desc, 1 limit 8) q order by 1);
        end if;
        bpal := array(select b.name from unnest(distinct_b) u(id) join mc.biome b on b.id = u.id order by u.id);
        bbits := case cardinality(bpal) when 1 then 0 when 2 then 1 when 3 then 2 when 4 then 2 else 3 end;
        if bbits = 0 then bdata := '\x';
        else
            -- 64 entries, index (y << 4 | z << 2 | x) of the 4 x 4 x 4 cells, floor(64 / bits) per long, least significant first
            declare per int := 64 / bbits; nwd int := (64 + per - 1) / per; words bigint[] := array_fill(0::bigint, array[nwd]); e int; bid2 int; pidx int;
            begin
                for e in 0 .. 63 loop
                    bid2 := bids[cell[(((e >> 2) & 3) * 4) + (e & 3) + 1]];
                    pidx := array_position(distinct_b, bid2);
                    if pidx is null then pidx := array_position(distinct_b, (select bid from (select bids[c] as bid, count(*) n from unnest(cell) c group by 1 order by 2 desc, 1 limit 1) q)); end if;
                    words[e / per + 1] := words[e / per + 1] | ((pidx - 1)::bigint << ((e % per) * bbits));
                end loop;
                bdata := (select string_agg(int8send(wv), ''::bytea order by o) from unnest(words) with ordinality t(wv, o));
            end;
        end if;
        ------------------------------------------------------------ the class string of the columns in plane order (z ascending, x descending) and the classes present
        s_cols := (select string_agg(chr(256 + hs[z * 16 + x + 1] * 8 + tys[z * 16 + x + 1]), '' order by z, x desc) from generate_series(0, 15) z, generate_series(0, 15) x);
        cls := array(select distinct hs[c] * 8 + tys[c] from generate_series(1, 256) c);          -- sorted class codes: h * 8 + type
        from_c := (select string_agg(chr(256 + c), '' order by c) from unnest(cls) c);
        ------------------------------------------------------------ section rows
        -- below y 0: deepslate sections and the bedrock section (-4): bedrock layers per column from a hash
        secs := secs || row(p_dim, qx, qz, -3, 4096, 0, array[pdeep], 0, '\x', bpal, bbits, bdata)::mc.chunk_section
                     || row(p_dim, qx, qz, -2, 4096, 0, array[pdeep], 0, '\x', bpal, bbits, bdata)::mc.chunk_section
                     || row(p_dim, qx, qz, -1, 4096, 0, array[pdeep], 0, '\x', bpal, bbits, bdata)::mc.chunk_section;
        bdraw := (select string_agg((1 + floor(5 * mc.t_hash(seed, qx * 16 + x, qz * 16 + z, 77))::int)::text, '' order by z, x desc) from generate_series(0, 15) z, generate_series(0, 15) x);
        planes := translate(bdraw, '12345', '11111') || translate(bdraw, '12345', '01111') || translate(bdraw, '12345', '00111') || translate(bdraw, '12345', '00011') || translate(bdraw, '12345', '00001')
                  || repeat(repeat('0', 256), 11);                                                  -- y -64 .. -60 by layer count, then deepslate (palette index 0)
        secs := secs || row(p_dim, qx, qz, -4, 4096, 0, array[pdeep, 'minecraft:bedrock'], 4, decode(planes, 'hex'), bpal, bbits, bdata)::mc.chunk_section;
        -- stone sections that nothing reaches
        for sy in 0 .. first_b - 1 loop
            secs := secs || row(p_dim, qx, qz, sy, 4096, 0, array['minecraft:stone'], 0, '\x', bpal, bbits, bdata)::mc.chunk_section;
        end loop;
        -- sections the surface (or the sea) passes through
        for sy in first_b .. last_b loop
            planes := '';
            for yy in 0 .. 15 loop
                y := sy * 16 + yy;
                to_c := (select string_agg(case when c / 8 < y then (case when y <= 62 then '6' else '0' end)
                                                when c / 8 - y < 8 then substr(mc.t_profile(c % 8), c / 8 - y + 1, 1)
                                                else '1' end, '' order by c) from unnest(cls) c);
                planes := planes || translate(s_cols, from_c, to_c);
            end loop;
            nonair := 4096 - (length(planes) - length(replace(planes, '0', '')));
            fluid := length(planes) - length(replace(planes, '6', ''));
            secs := secs || row(p_dim, qx, qz, sy, nonair, fluid, pal9, 4, decode(planes, 'hex'), bpal, bbits, bdata)::mc.chunk_section;
        end loop;
        ------------------------------------------------------------ the chunk row: heightmaps = the higher of surface and sea (water counts for MOTION_BLOCKING)
        ws := array(select (greatest(h, 62) + 65)::smallint from unnest(hs) h);
        chunks := chunks || row(p_dim, qx, qz, 'minecraft:full', 0, true, false, ws, ws, ws, null, null)::mc.chunk;
        -- written in groups of 32 chunks (appending to an ever longer array of 4 KB rows would be quadratic); a chunk another generator created meanwhile is skipped whole
        if cardinality(chunks) >= 32 then
            with ins as (insert into mc.chunk select * from unnest(chunks) on conflict do nothing returning cx, cz),
                 sec as (insert into mc.chunk_section select s.* from unnest(secs) s join ins on ins.cx = s.cx and ins.cz = s.cz returning 1)
            select count(*), array_cat(made_x, array_agg(cx)), array_cat(made_z, array_agg(cz)) into k, made_x, made_z from ins;
            n := n + k; chunks := '{}'; secs := '{}';
        end if;
    end loop;
    if cardinality(chunks) > 0 then
        with ins as (insert into mc.chunk select * from unnest(chunks) on conflict do nothing returning cx, cz),
             sec as (insert into mc.chunk_section select s.* from unnest(secs) s join ins on ins.cx = s.cx and ins.cz = s.cz returning 1)
        select count(*), array_cat(made_x, array_agg(cx)), array_cat(made_z, array_agg(cz)) into k, made_x, made_z from ins;
        n := n + k;
    end if;
    -- The chunks this call created get their light (straight-down model) and their packet now, in the generator's own transaction, so that the tick only reads the cache:
    -- 0.9 ms and 1.4 ms of the 4.7 ms a chunk costs here (docs/WORLD.md).  The flat generator copies both from its template.
    for k in 1 .. coalesce(cardinality(made_x), 0) loop
        perform mc.chunk_packet(p_dim, made_x[k], made_z[k]);
    end loop;
    return n;
end $$;

------------------------------------------------------------------------------------------------ registry, setting, spawn
insert into mc.generator (name, batch_fn, note)
values ('dbcraft:noise', 'mc.generate_noise_batch(text, int[], int[], boolean)'::regprocedure,
        'seeded value-noise terrain (mc.world.seed), 16 real biomes, bedrock and deepslate, sea level 63; not vanilla terrain (sql/855)')
on conflict (name) do update set batch_fn = excluded.batch_fn, note = excluded.note;

-- Put the world spawn where a player can stand: the flat world's spawn for the flat generator, for the noise generator the first dry column (height 66 or more, so not a
-- beach) on a spiral around the origin.  Updates the overworld's mc.dimension row and mc.game_state (what the join sends).
create or replace function mc.place_spawn() returns void language plpgsql volatile as $$
declare
    g    text := (select d.generator from mc.dimension d where d.name = 'minecraft:overworld');
    seed bigint := coalesce((select w.seed from mc.world w where w.name = 'world'), 0);
    sx int := 0; sy int := -60; sz int := 0; i int; x int; z int; h int;
begin
    if g = 'dbcraft:noise' then
        for i in 0 .. 4000 loop
            x := round(sqrt(i) * 16 * cos(i * 2.399963))::int; z := round(sqrt(i) * 16 * sin(i * 2.399963))::int;
            h := mc.terrain_height(seed, x, z);
            if h >= 66 then sx := x; sz := z; sy := h + 1; exit; end if;
            sx := x; sz := z; sy := greatest(h, 62) + 1;           -- nothing dry within 1,000 blocks: the last point, standing on the water's surface
        end loop;
    elsif g <> 'minecraft:flat' then
        return;
    end if;
    update mc.dimension set spawn_x = sx, spawn_y = sy, spawn_z = sz where name = 'minecraft:overworld';
    update mc.game_state set spawn_x = sx + 0.5, spawn_y = sy, spawn_z = sz + 0.5;
end $$;

create or replace function mc.apply_generator_setting() returns trigger language plpgsql as $$
begin
    if not exists (select 1 from mc.generator where name = new.value) then
        raise exception 'dbcraft.generator: unknown generator % (known: %)', new.value, (select string_agg(name, ', ' order by name) from mc.generator);
    end if;
    update mc.dimension set generator = new.value where name = 'minecraft:overworld';
    perform mc.place_spawn();
    return null;
end $$;
drop trigger if exists apply_generator on mc.server_property;
create trigger apply_generator after insert or update of value on mc.server_property for each row when (new.key = 'dbcraft.generator') execute function mc.apply_generator_setting();
