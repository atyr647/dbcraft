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
-- oxidation, budding amethyst, ...) does nothing here.  Light is the straight-down sky model (mc.compute_light): open sky is 15 less the sky darkness, nothing else gives light.

insert into mc.server_property (key, value, default_value, note) values
    ('dbcraft.random-tick-players', '4', '4', 'dbcraft: random ticks are served in the areas of this many randomly chosen online players per tick (all of them when fewer are online)'),
    ('dbcraft.random-tick-max-hits', '6', '6', 'dbcraft: at most this many random-tick hits are processed per tick (a random subset when there are more: the rate of every block drops proportionally)'),
    ('dbcraft.random-tick-interval', '4', '4', 'dbcraft: random ticks run every this many ticks, with that many ticks of draws at once (1 = every tick, vanilla timing; the cost of a run is mostly fixed)')
on conflict (key) do nothing;

create table if not exists mc.dyn_rt_chunk (dimension text not null, cx int not null, cz int not null, version bigint not null, secs int[] not null, primary key (dimension, cx, cz));
-- the palette indexes of the randomly ticking states of each section that has any, valid while the chunk's version is the cached one
create table if not exists mc.dyn_rt_sec (dimension text not null, cx int not null, sy int not null, cz int not null, version bigint not null, rtidx int[] not null, primary key (dimension, cx, cz, sy));

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
    dim    text;
    pcx int[]; pcz int[];
    kinds int[]; xs int[]; ys int[]; zs int[]; aux int[]; hs int[];
begin
    if speed <= 0 or p_cur % iv <> 0 then return; end if;                               -- every iv-th tick, with iv ticks' worth of draws (the per-call cost is mostly fixed)
    dim := coalesce((select default_dimension from mc.world limit 1), 'minecraft:overworld');
    select array_agg(p.chunk_x), array_agg(p.chunk_z) into pcx, pcz from (select chunk_x, chunk_z from mc.player where conn_id is not null order by random() limit kmax) p;
    if pcx is null then return; end if;
    -- refresh the sections of the chunks whose cache is missing or stale (three statements: a delete and an insert of one key must not share a statement)
    create temp table if not exists _rt_stale (cx int, cz int, version bigint) on commit drop;
    truncate _rt_stale;
    insert into _rt_stale
    select c.cx, c.cz, c.version
      from (select distinct a + dx as cx, b + dz as cz from unnest(pcx, pcz) pp(a, b), generate_series(-r, r) dx, generate_series(-r, r) dz) col
      join mc.chunk c on c.dimension = dim and c.cx = col.cx and c.cz = col.cz
      left join mc.dyn_rt_chunk k on k.dimension = c.dimension and k.cx = c.cx and k.cz = c.cz
     where k.version is distinct from c.version;
    if exists (select 1 from _rt_stale) then
        delete from mc.dyn_rt_sec t using _rt_stale s where t.dimension = dim and t.cx = s.cx and t.cz = s.cz;
        insert into mc.dyn_rt_sec (dimension, cx, sy, cz, version, rtidx)
        select dim, s.cx, cs.sy, s.cz, s.version, i.idx
          from _rt_stale s join mc.chunk_section cs on cs.dimension = dim and cs.cx = s.cx and cs.cz = s.cz
          cross join lateral (select array_agg((p.o - 1)::int order by p.o) as idx from unnest(cs.palette) with ordinality p(n, o) join mc.dyn_state d on d.name = p.n and d.rtick) i
         where i.idx is not null;
        insert into mc.dyn_rt_chunk (dimension, cx, cz, version, secs) select dim, s.cx, s.cz, s.version, '{}' from _rt_stale s
        on conflict (dimension, cx, cz) do update set version = excluded.version;
    end if;
    -- the draws: speed * 3 uniformly random positions of every section that can have a hit; a hit is a draw whose palette index is one of the section's randomly ticking ones
    with col as (select distinct a + dx as cx, b + dz as cz from unnest(pcx, pcz) pp(a, b), generate_series(-r, r) dx, generate_series(-r, r) dz),
         draws as (select t.cx, t.sy, t.cz, t.rtidx, floor(random() * 4096)::int as idx
                     from mc.dyn_rt_sec t join col c on c.cx = t.cx and c.cz = t.cz, generate_series(1, speed * 3 * iv) g where t.dimension = dim),
         hit as (select d.cx, d.sy, d.cz, d.idx, case when cs.bits = 0 then cs.palette[1] else cs.palette[mc.entry_at(cs.bits, cs.data, d.idx) + 1] end as nm
                   from draws d join mc.chunk_section cs on cs.dimension = dim and cs.cx = d.cx and cs.cz = d.cz and cs.sy = d.sy
                  where (cs.bits = 0 and 0 = any (d.rtidx)) or (cs.bits > 0 and cardinality(cs.palette) > 0 and mc.entry_at(cs.bits, cs.data, d.idx) = any (d.rtidx))),
         top as (select * from hit order by random() limit cap * iv)
    select array_agg(3), array_agg(h.cx * 16 + (h.idx & 15)), array_agg(h.sy * 16 + (h.idx >> 8)), array_agg(h.cz * 16 + ((h.idx >> 4) & 15)), array_agg(ds.sid),
           array_agg(coalesce(ch.hm_world_surface[(h.idx & 15) + 16 * ((h.idx >> 4) & 15) + 1], 0) + (select min_y from mc.dimension where name = dim))
      into kinds, xs, ys, zs, aux, hs
      from top h join mc.dyn_state ds on ds.name = h.nm left join mc.chunk ch on ch.dimension = dim and ch.cx = h.cx and ch.cz = h.cz;
    if kinds is null then return; end if;
    perform mc.dyn_run(dim, p_cur, kinds, xs, ys, zs, aux, false, hs, mc.dyn_sky_darken());
end $$;
