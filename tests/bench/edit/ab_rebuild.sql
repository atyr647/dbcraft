-- A/B: packet rebuild after edits, ORIGINAL (schema mc_old, tests/bench/edit/old_impl.sql) against the NEW implementation, interleaved in one session.
--   psql -X -d DB -v rounds=7 -f tests/bench/edit/ab_rebuild.sql      (needs old_impl.sql loaded in DB)
-- Per round, both implementations rebuild the packets of identical chunk sets (separate chunks, same state); the order alternates each round.
-- Times are the CPU time of the backend (bench.cpu_ms), not wall-clock.  Prints per scenario: median, min and max over the rounds of the per-rebuild time, and the median of the per-round ratio old / new.
\set ON_ERROR_STOP on
\ir cpu_timer.sql
set jit = off;
\if :{?rounds}
\else
\set rounds 7
\endif
create sequence if not exists public.dbcraft_bench_edit_run;
select set_config('perf.base', (300000 + (nextval('public.dbcraft_bench_edit_run') % 200) * 10000)::text, false);
select set_config('perf.rounds', :'rounds', false);

create or replace function pg_temp.med(a numeric[]) returns numeric language sql as $$ select round((percentile_cont(0.5) within group (order by x))::numeric, 3) from unnest(a) x $$;

do $$
declare
    dim     text := 'minecraft:overworld';
    base    int := current_setting('perf.base')::int;
    rounds  int := current_setting('perf.rounds')::int;
    n       int := 40;
    r int; i int; t0 numeric; ms numeric;
    o numeric[]; nw numeric[]; ratio numeric[];
    scen    record;
    off_new int; off_old int;
    xs int[]; ys int[]; zs int[]; bl text[]; k int;
begin
    for scen in select * from (values
        ('S1 one edit below the surface (light inputs unchanged)', -62, 'minecraft:gold_block', 'minecraft:stone', 1),
        ('S2 one edit above the surface (heightmap and light change)', -55, 'minecraft:stone', 'minecraft:air', 1),
        ('S3 chunk after 1,000 edits spread over y -64..-2', 0, '', '', 1000)) v(name, y, b1, b2, edits)
    loop
        o := '{}'; nw := '{}'; ratio := '{}';
        off_new := base; off_old := base + 5000; base := base + 10000;           -- fresh chunks per scenario
        perform mc.generate_flat_area(dim, off_new, 0, off_new + n - 1, 0);
        perform mc.generate_flat_area(dim, off_old, 0, off_old + n - 1, 0);
        for i in 0 .. n - 1 loop perform mc.chunk_packet(dim, off_new + i, 0); perform mc_old.chunk_packet(dim, off_old + i, 0); end loop;
        for r in 1 .. rounds loop
            -- the same edits on both sets
            if scen.edits = 1 then
                for i in 0 .. n - 1 loop
                    perform mc.set_block(dim, (off_new + i) * 16 + 3, scen.y, 3, case when r % 2 = 1 then scen.b1 else scen.b2 end);
                    perform mc.set_block(dim, (off_old + i) * 16 + 3, scen.y, 3, case when r % 2 = 1 then scen.b1 else scen.b2 end);
                end loop;
            else
                for i in 0 .. n - 1 loop
                    select array_agg((off_new + i) * 16 + (random() * 15)::int), array_agg(-64 + (random() * 62)::int), array_agg((random() * 15)::int),
                           array_agg((array['minecraft:stone','minecraft:glass','minecraft:oak_planks','minecraft:sand','minecraft:air'])[1 + (random() * 4)::int])
                      into xs, ys, zs, bl from generate_series(1, scen.edits);
                    perform mc.set_blocks(dim, xs, ys, zs, bl);
                    perform mc.set_blocks(dim, array(select x + (off_old - off_new) * 16 from unnest(xs) x), ys, zs, bl);
                end loop;
            end if;
            if r % 2 = 0 then
                t0 := bench.cpu_ms(); for i in 0 .. n - 1 loop perform mc_old.chunk_packet(dim, off_old + i, 0); end loop;
                ms := (bench.cpu_ms() - t0) / n; o := o || ms;
                t0 := bench.cpu_ms(); for i in 0 .. n - 1 loop perform mc.chunk_packet(dim, off_new + i, 0); end loop;
                nw := nw || ((bench.cpu_ms() - t0) / n)::numeric;
            else
                t0 := bench.cpu_ms(); for i in 0 .. n - 1 loop perform mc.chunk_packet(dim, off_new + i, 0); end loop;
                nw := nw || ((bench.cpu_ms() - t0) / n)::numeric;
                t0 := bench.cpu_ms(); for i in 0 .. n - 1 loop perform mc_old.chunk_packet(dim, off_old + i, 0); end loop;
                o := o || ((bench.cpu_ms() - t0) / n)::numeric;
            end if;
            ratio := ratio || (o[r] / nw[r]);
        end loop;
        raise notice '% | old median % ms (min %, max %) | new median % ms (min %, max %) | ratio old/new, median % (loadavg at start: see uptime)',
            scen.name, pg_temp.med(o), (select round(min(x)::numeric, 3) from unnest(o) x), (select round(max(x)::numeric, 3) from unnest(o) x),
            pg_temp.med(nw), (select round(min(x)::numeric, 3) from unnest(nw) x), (select round(max(x)::numeric, 3) from unnest(nw) x), pg_temp.med(ratio);
        -- the two implementations must produce the same bytes for the same chunks
        -- (the bodies differ in their first 8 bytes: the chunk coordinates)
        if scen.edits = 1 then
            if (select count(*) from generate_series(0, n - 1) gi
                 where substring(mc.chunk_packet_body(dim, off_new + gi, 0) from 9) is distinct from substring(mc_old.chunk_packet_body(dim, off_old + gi, 0) from 9)) > 0 then
                raise exception 'packets differ between the old and the new implementation (%)', scen.name;
            end if;
        else
            -- random edits differ between chunks only by the (chunk-local) random choice made per pair; the pair got the same edits, so they must match too
            if (select count(*) from generate_series(0, n - 1) gi
                 where substring(mc.chunk_packet_body(dim, off_new + gi, 0) from 9) is distinct from substring(mc_old.chunk_packet_body(dim, off_old + gi, 0) from 9)) > 0 then
                raise exception 'packets differ between the old and the new implementation (%)', scen.name;
            end if;
        end if;
    end loop;
end $$;
