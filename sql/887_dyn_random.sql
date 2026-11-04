-- World dynamics, part 8: random ticks (ServerLevel.tickChunk).
--
-- Vanilla, every tick, for every chunk a player simulates: for every section that holds a randomly ticking block, randomTickSpeed (gamerule, default 3) times a uniformly random
-- position of the section; when the block there is randomly ticking its randomTick runs (and a fluid's, for lava).  This does the same with the same distribution, as set-based SQL:
-- the sections that can have a hit come from a per-chunk cache (mc.dyn_rt_chunk, valid while mc.chunk.version is the same), the draws are one query, and the hits go to the engine
-- (sql/884, work item 3).  It is STATISTICAL: vanilla's random numbers are not reproduced, only the rules (docs/WORLD-DYNAMICS.md checks them with distributions).
--
-- Bounded cost: random ticks run every dbcraft.random-tick-interval ticks (default 4) with that many ticks of draws at once, the hits of a run are capped (dbcraft.random-tick-max-hits per tick),
-- and the number of draws per tick is proportional to the sections with randomly ticking blocks near players.  Only the areas of dbcraft.random-tick-players players
-- (default 4, chosen at random every tick) are served each tick, so with more players online every area is ticked proportionally less often than vanilla would (each player's area at full rate
-- on the ticks it is picked: its long-run rate is picked / online of vanilla's).  With fewer online than that, vanilla's rate.
--
-- Implemented behaviours (the classes read in the 26.3 bytecode): grass block and mycelium (spread to dirt, die to dirt), crops (CropBlock growth formula), farmland (moisture, back to
-- dirt), saplings (stage 0 -> 1).  Everything else that ticks randomly in vanilla (leaf decay, sugar cane, cactus, vines, kelp, ice and snow melting, fire, lava fire, copper
-- oxidation, budding amethyst, ...) does nothing here.  Light: a cell has sky light 15 (less the sky darkness) when no block that stops motion or holds fluid, leaves excepted, is above it (the MOTION_BLOCKING_NO_LEAVES heightmap); nothing else gives light
-- (no torches, no attenuation by water or leaves).

insert into mc.server_property (key, value, default_value, note) values
    ('dbcraft.random-tick-players', '4', '4', 'dbcraft: random ticks are served in the areas of this many randomly chosen online players per tick (all of them when fewer are online)'),
    ('dbcraft.random-tick-max-hits', '6', '6', 'dbcraft: at most this many random-tick hits are processed per tick (a random subset when there are more: the rate of every block drops proportionally)'),
    ('dbcraft.random-tick-interval', '4', '4', 'dbcraft: random ticks run every this many ticks, with that many ticks of draws at once (1 = every tick, vanilla timing; the cost of a run is mostly fixed)')
on conflict (key) do nothing;

create table if not exists mc.dyn_rt_chunk (dimension text not null, cx int not null, cz int not null, version bigint not null, secs int[] not null, primary key (dimension, cx, cz));
-- the palette indexes of the randomly ticking states of each section that has any, and the positions (0..4095, y*256+z*16+x as in the wire format's order) holding one: valid while the chunk's version is the cached one
create table if not exists mc.dyn_rt_sec (dimension text not null, cx int not null, sy int not null, cz int not null, version bigint not null, rtidx int[] not null, cnt int not null default 0, cells smallint[], primary key (dimension, cx, cz, sy));
alter table mc.dyn_rt_sec add column if not exists cnt int not null default 0;
alter table mc.dyn_rt_sec add column if not exists cells smallint[];
-- rows written by an older version of this file have no cells: forget them (derived data, rebuilt on demand)
delete from mc.dyn_rt_chunk k where exists (select 1 from mc.dyn_rt_sec t where t.dimension = k.dimension and t.cx = k.cx and t.cz = k.cz and t.cells is null);
delete from mc.dyn_rt_sec where cells is null;

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

create or replace function mc.dyn_random_ticks(p_cur bigint) returns void language plpgsql volatile as $$
declare
    speed  int := mc.rule_int('random_tick_speed', 3);
    r      int := mc.prop_int('simulation-distance');
    kmax   int := coalesce(mc.prop_int('dbcraft.random-tick-players'), 4);
    cap    int := coalesce(mc.prop_int('dbcraft.random-tick-max-hits'), 6);
    iv     int := greatest(coalesce(mc.prop_int('dbcraft.random-tick-interval'), 4), 1);
    budget int := greatest(coalesce(mc.prop_int('dbcraft.random-tick-chunk-budget'), 300), 1);
    dim    text;
    pcx int[]; pcz int[]; acx int[]; acz int[]; scx int[]; scz int[]; sver bigint[];
    hcx int[]; hsy int[]; hcz int[]; hidx int[]; hsid int[];
    kinds int[]; xs int[]; ys int[]; zs int[]; aux int[]; hs int[];
    wtot bigint; ew float8; lim int; h int; l float8; pr float8;
begin
    if speed <= 0 or p_cur % iv <> 0 then return; end if;                               -- every iv-th tick, with iv ticks' worth of draws (the per-call cost is mostly fixed)
    dim := coalesce((select default_dimension from mc.world limit 1), 'minecraft:overworld');
    select array_agg(p.chunk_x), array_agg(p.chunk_z) into pcx, pcz from (select chunk_x, chunk_z from mc.player where conn_id is not null order by random() limit kmax) p;
    if pcx is null then return; end if;
    select array_agg(q.cx), array_agg(q.cz) into acx, acz from (select distinct a + dx as cx, b + dz as cz from unnest(pcx, pcz) pp(a, b), generate_series(-r, r) dx, generate_series(-r, r) dz) q;
    -- refresh the sections of the chunks whose cache is missing or stale, at most `budget` chunks per run (the rest on later runs: a crowd that just arrived does not make one tick pay for all
    -- of it).  Separate statements: a delete and an insert of one key must not share one.
    select array_agg(c.cx), array_agg(c.cz), array_agg(c.version) into scx, scz, sver
      from (select c.cx, c.cz, c.version from unnest(acx, acz) col(cx, cz)
              join mc.chunk c on c.dimension = dim and c.cx = col.cx and c.cz = col.cz
              left join mc.dyn_rt_chunk k on k.dimension = c.dimension and k.cx = c.cx and k.cz = c.cz
             where k.version is distinct from c.version limit budget) c;
    if scx is not null then
        delete from mc.dyn_rt_sec t using unnest(scx, scz) s(cx, cz) where t.dimension = dim and t.cx = s.cx and t.cz = s.cz;
        insert into mc.dyn_rt_sec (dimension, cx, sy, cz, version, rtidx, cnt, cells)
        select dim, s.cx, cs.sy, s.cz, s.version, i.idx, cardinality(pc.cells), pc.cells
          from unnest(scx, scz, sver) s(cx, cz, version) join mc.chunk_section cs on cs.dimension = dim and cs.cx = s.cx and cs.cz = s.cz
          cross join lateral (select array_agg((p.o - 1)::int order by p.o) as idx from unnest(cs.palette) with ordinality p(n, o) join mc.dyn_state d on d.name = p.n and d.rtick) i
          cross join lateral (select array_agg((u.k - 1)::smallint order by u.k) as cells from unnest(mc.dyn_decode(cs.bits, cs.data, '{}'::int4[])) with ordinality u(e, k) where u.e = any (i.idx)) pc
         where i.idx is not null and pc.cells is not null;
        insert into mc.dyn_rt_chunk (dimension, cx, cz, version, secs) select dim, s.cx, s.cz, s.version, '{}' from unnest(scx, scz, sver) s(cx, cz, version)
        on conflict (dimension, cx, cz) do update set version = excluded.version;
    end if;
    -- The draws.  Vanilla draws speed * 3 (here: times the interval) uniformly random positions in every section and a draw is a hit when the block there ticks randomly.  The number of hits
    -- of the area is therefore Poisson distributed with mean n * (randomly ticking cells) / 4096, each hit is in a section with probability proportional to its cells and at a uniformly
    -- random one of them: drawing exactly that costs O(hits) where drawing the positions costs O(sections * n).  The hits of a run are capped (a random subset, the rate drops proportionally).
    select coalesce(sum(t.cnt), 0) into wtot from mc.dyn_rt_sec t join unnest(acx, acz) c(cx, cz) on c.cx = t.cx and c.cz = t.cz where t.dimension = dim;
    if wtot = 0 then return; end if;
    lim := cap * iv;
    ew := speed * 3.0 * iv * wtot / 4096.0;
    if ew > 2 * lim then h := lim;
    else                                                                                  -- Poisson(ew) by multiplication, at most lim
        l := exp(-ew); pr := 1; h := 0;
        loop pr := pr * random(); exit when pr <= l or h >= lim; h := h + 1; end loop;
    end if;
    if h = 0 then return; end if;
    with cand as (select t.cx, t.sy, t.cz, t.cnt, t.cells, sum(t.cnt) over (order by t.cx, t.sy, t.cz) as cum
                    from mc.dyn_rt_sec t join unnest(acx, acz) c(cx, cz) on c.cx = t.cx and c.cz = t.cz where t.dimension = dim),
         pick as materialized (select random() * wtot as u from generate_series(1, h) g),
         hit as (select c.cx, c.sy, c.cz, c.cells[1 + floor(random() * c.cnt)::int]::int as idx from pick p join cand c on p.u >= c.cum - c.cnt and p.u < c.cum),
         named as (select hh.cx, hh.sy, hh.cz, hh.idx, case when cs.bits = 0 then cs.palette[1] else cs.palette[mc.entry_at(cs.bits, cs.data, hh.idx) + 1] end as nm
                     from hit hh join mc.chunk_section cs on cs.dimension = dim and cs.cx = hh.cx and cs.cz = hh.cz and cs.sy = hh.sy)
    select array_agg(n.cx), array_agg(n.sy), array_agg(n.cz), array_agg(n.idx), array_agg(ds.sid)
      into hcx, hsy, hcz, hidx, hsid from named n join mc.dyn_state ds on ds.name = n.nm;
    if hcx is null then return; end if;
    -- the heightmaps that tell where the sky is open must be current (a fill leaves them to be recomputed when something needs them: here), for the chunks of the hits only
    perform mc.ensure_chunk_current(dim, q.a, q.b) from (select distinct a, b from unnest(hcx, hcz) u(a, b)) q;
    select array_agg(3), array_agg(u.cx * 16 + (u.idx & 15)), array_agg(u.sy * 16 + (u.idx >> 8)), array_agg(u.cz * 16 + ((u.idx >> 4) & 15)), array_agg(u.sid),
           array_agg(coalesce(ch.hm_motion_blocking_no_leaves[(u.idx & 15) + 16 * ((u.idx >> 4) & 15) + 1], 0) + (select min_y from mc.dimension where name = dim))
      into kinds, xs, ys, zs, aux, hs
      from unnest(hcx, hsy, hcz, hidx, hsid) u(cx, sy, cz, idx, sid) left join mc.chunk ch on ch.dimension = dim and ch.cx = u.cx and ch.cz = u.cz;
    perform mc.dyn_run(dim, p_cur, kinds, xs, ys, zs, aux, false, hs, mc.dyn_sky_darken());
end $$;
