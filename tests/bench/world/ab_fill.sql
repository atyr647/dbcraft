-- A/B: mc.fill, the ORIGINAL (bench_old.fill, tests/bench/world/old_fill.sql) against the box fill of sql/210 (mc.fill_section), interleaved in one session.
--   psql -X -d DB -v rounds=9 -f tests/bench/world/ab_fill.sql          (superuser: the CPU timer reads /proc/self/schedstat)
-- Each scenario alternates stone and air over the same box (so every call changes every block), once on a chunk area for the old function and once on another area
-- 16,000 blocks away for the new one; the order rotates every round; the events the call queued are discarded outside the timing.  Prints the median, min and max of
-- the CPU time and of the wall-clock time per call (ms) and the median of the per-round ratio old / new.  CPU time is the backend's own (bench.cpu_ms): on the shared
-- development machine wall-clock times double from one minute to the next, the ratio of interleaved runs is the evidence.
\set ON_ERROR_STOP on
\ir ../edit/cpu_timer.sql
\ir old_fill.sql
set jit = off;
\if :{?rounds}
\else
\set rounds 9
\endif
select set_config('perf.rounds', :'rounds', false);
create or replace function pg_temp.med(a numeric[]) returns numeric language sql as $$ select round((percentile_cont(0.5) within group (order by x))::numeric, 2) from unnest(a) x $$;
create or replace function pg_temp.mn(a numeric[]) returns numeric language sql as $$ select round(min(x)::numeric, 2) from unnest(a) x $$;
create or replace function pg_temp.mx(a numeric[]) returns numeric language sql as $$ select round(max(x)::numeric, 2) from unnest(a) x $$;
select mc.generate_flat_area('minecraft:overworld', -3, -3, 6, 6);                      -- the old function's area
select mc.generate_flat_area('minecraft:overworld', 1000 - 3, -3, 1000 + 6, 6);         -- the new one's (16,000 blocks east)

do $$
declare
    rounds int := current_setting('perf.rounds')::int;
    dx int := 16000;
    sc record; r int; q int; k int; co int; cn int; t0 numeric; w0 timestamptz; c int;
    oc numeric[]; nc numeric[]; ow numeric[]; nw numeric[]; ratio numeric[];
    tco numeric; tcn numeric; two numeric; twn numeric;
begin
    raise notice '% rounds; CPU ms per call: median (min - max); wall-clock in brackets', rounds;
    for sc in select * from (values
        ('fill 1,000 blocks (10x10x10, scoreboard)',                 0, -60,  0,  9, -51,  9, 20),
        ('fill 100,000 blocks (50x40x50, scoreboard)',             -25, -60, -25, 24, -21, 24, 1),
        ('one whole section (16x16x16)',                             0, -48,  0, 15, -33, 15, 50),
        ('64 whole sections (4 x 4 chunks x 4 sections)',            0, -64,  0, 63,  -1, 63, 3),
        ('16x1x16 floor',                                            0, -60,  0, 15, -60, 15, 50),
        ('unaligned 40x40x40',                                       5, -55,  5, 44, -16, 44, 1),
        ('100 blocks (5x5x4: box path)',                             2, -60,  2,  6, -57,  6, 20),
        ('40 blocks (5x2x4: the per-block path)',                    2, -60,  2,  6, -59,  5, 20)) v(name, x1, y1, z1, x2, y2, z2, reps)
    loop
        oc := '{}'; nc := '{}'; ow := '{}'; nw := '{}'; ratio := '{}'; co := 0; cn := 0;
        perform bench_old.fill('minecraft:overworld', sc.x1, sc.y1, sc.z1, sc.x2, sc.y2, sc.z2, 'minecraft:air');
        perform mc.fill('minecraft:overworld', sc.x1 + dx, sc.y1, sc.z1, sc.x2 + dx, sc.y2, sc.z2, 'minecraft:air');
        truncate mc.block_event;
        for r in 1 .. rounds loop
            for q in 0 .. 1 loop
                if (r + q) % 2 = 0 then
                    t0 := bench.cpu_ms(); w0 := clock_timestamp();
                    for k in 1 .. sc.reps loop
                        c := bench_old.fill('minecraft:overworld', sc.x1, sc.y1, sc.z1, sc.x2, sc.y2, sc.z2, case when co % 2 = 0 then 'minecraft:stone' else 'minecraft:air' end); co := co + 1;
                    end loop;
                    tco := (bench.cpu_ms() - t0) / sc.reps; two := extract(epoch from clock_timestamp() - w0) * 1000 / sc.reps;
                else
                    t0 := bench.cpu_ms(); w0 := clock_timestamp();
                    for k in 1 .. sc.reps loop
                        c := mc.fill('minecraft:overworld', sc.x1 + dx, sc.y1, sc.z1, sc.x2 + dx, sc.y2, sc.z2, case when cn % 2 = 0 then 'minecraft:stone' else 'minecraft:air' end); cn := cn + 1;
                    end loop;
                    tcn := (bench.cpu_ms() - t0) / sc.reps; twn := extract(epoch from clock_timestamp() - w0) * 1000 / sc.reps;
                end if;
                truncate mc.block_event;
            end loop;
            oc := oc || tco; nc := nc || tcn; ow := ow || two; nw := nw || twn; ratio := ratio || (tco / nullif(tcn, 0));
        end loop;
        raise notice '%: old % (% - %) [% wall]   new % (% - %) [% wall]   ratio %x', rpad(sc.name, 48), pg_temp.med(oc), pg_temp.mn(oc), pg_temp.mx(oc), pg_temp.med(ow),
                     pg_temp.med(nc), pg_temp.mn(nc), pg_temp.mx(nc), pg_temp.med(nw), pg_temp.med(ratio);
    end loop;
end $$;
