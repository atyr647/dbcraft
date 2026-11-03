-- Terrain generation cost: the flat generator (template copy) against dbcraft:noise (sql/855), per chunk, with the noise generator's part split into
-- rows / light / packet.   psql -X -d DB -v rounds=5 -f tests/bench/world/bench_terrain.sql      (superuser: the CPU timer reads /proc/self/schedstat)
-- Every round generates a fresh 40 x 40 chunk area (1,600 chunks) in a scratch dimension per variant; the CPU time of the backend (bench.cpu_ms: unaffected by other jobs waiting
-- for a core) is divided by 1,600.  The noise rows are timed by taking the call's time and subtracting the light and packet work, which is measured separately on the same
-- chunks (the cache and the light rows are dropped and rebuilt).  Prints median (min - max) in microseconds per chunk.
\set ON_ERROR_STOP on
\ir ../edit/cpu_timer.sql
set jit = off;
\if :{?rounds}
\else
\set rounds 5
\endif
select set_config('perf.rounds', :'rounds', false);
do $$
declare
    rounds int := current_setting('perf.rounds')::int;
    r int; t0 numeric; base int;
    flat numeric[] := '{}'; noise numeric[] := '{}'; prep numeric[] := '{}'; light numeric[] := '{}'; pkt numeric[] := '{}'; rows_ numeric[] := '{}'; flat_pk numeric[] := '{}';
    tl numeric; tp numeric; tn numeric; tf numeric; k record;
    function_med text;
begin
    insert into mc.dimension (name, generator) values ('dbcraft:bf', 'minecraft:flat'), ('dbcraft:bn', 'dbcraft:noise') on conflict do nothing;
    insert into mc.flat_layer (dimension, y, block) select 'dbcraft:bf', y, block from mc.flat_layer where dimension = 'minecraft:overworld' on conflict do nothing;
    for r in 1 .. rounds loop
        base := r * 100;
        t0 := bench.cpu_ms(); perform mc.generate_flat_area('dbcraft:bf', base, 0, base + 39, 39); tf := (bench.cpu_ms() - t0) / 1600 * 1000;
        flat := flat || tf;
        t0 := bench.cpu_ms(); perform mc.generate_noise_batch('dbcraft:bn', array_agg(x), array_agg(z)) from generate_series(base, base + 39) x, generate_series(0, 39) z; tn := (bench.cpu_ms() - t0) / 1600 * 1000;
        noise := noise || tn;
        -- the light and the packet of the same chunks, rebuilt from the rows
        delete from mc.chunk_cache where dimension = 'dbcraft:bn' and cx between base and base + 39;
        delete from mc.chunk_light where dimension = 'dbcraft:bn' and cx between base and base + 39;
        update mc.chunk set dirty = true, light_ws = null, light_top = null where dimension = 'dbcraft:bn' and cx between base and base + 39;
        t0 := bench.cpu_ms(); perform mc.ensure_chunk_current('dbcraft:bn', x, z) from generate_series(base, base + 39) x, generate_series(0, 39) z; tl := (bench.cpu_ms() - t0) / 1600 * 1000;
        t0 := bench.cpu_ms(); perform mc.chunk_packet('dbcraft:bn', x, z) from generate_series(base, base + 39) x, generate_series(0, 39) z; tp := (bench.cpu_ms() - t0) / 1600 * 1000;
        light := light || tl; pkt := pkt || tp; rows_ := rows_ || (tn - tl - tp);
    end loop;
    for k in select * from (values ('flat generator, 1 chunk (rows, light, packet: copied from the template)', flat), ('dbcraft:noise, 1 chunk (rows + light + packet, what the generator call costs)', noise),
                                   ('  of which the rows (heights, biomes, sections, inserts)', rows_), ('  of which light (mc.ensure_chunk_current)', light), ('  of which the packet (mc.chunk_packet)', pkt)) v(name, a) loop
        raise notice '%: % us (% - %)', rpad(k.name, 80), (select round(percentile_cont(0.5) within group (order by x)::numeric, 0) from unnest(k.a) x),
                     (select round(min(x)::numeric, 0) from unnest(k.a) x), (select round(max(x)::numeric, 0) from unnest(k.a) x);
    end loop;
    delete from mc.chunk where dimension in ('dbcraft:bf', 'dbcraft:bn');
    delete from mc.flat_layer where dimension = 'dbcraft:bf';
    delete from mc.dimension where name in ('dbcraft:bf', 'dbcraft:bn');
end $$;
