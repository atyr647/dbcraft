-- A/B(/C): mc.set_blocks, the ORIGINAL per-section loop (mc_old.set_blocks, tests/bench/edit/old_impl.sql) against the NEW implementation (mc.set_blocks) and, if
-- loaded, the archived set-based EXPERIMENT (mc_exp.set_blocks, tests/bench/edit/exp_setbased.sql), interleaved in one session.
--   psql -X -d DB -v rounds=7 -f tests/bench/edit/ab_batch.sql      (needs old_impl.sql loaded in DB)
-- All implementations get the SAME random edits (each round fresh ones; generated before timing) on identical, separate chunk sets; the order rotates every round.
-- Times are the CPU time of the backend (bench.cpu_ms: unaffected by other jobs waiting for the CPU) per call.  Prints median, min and max per scenario and the median of
-- the per-round ratio old / new.
\set ON_ERROR_STOP on
\ir cpu_timer.sql
set jit = off;
\if :{?rounds}
\else
\set rounds 7
\endif
create sequence if not exists public.dbcraft_bench_edit_run;
select set_config('perf.base', (400000 + (nextval('public.dbcraft_bench_edit_run') % 100) * 30000)::text, false);
select set_config('perf.rounds', :'rounds', false);

create or replace function pg_temp.med(a numeric[]) returns numeric language sql as $$ select round((percentile_cont(0.5) within group (order by x))::numeric, 3) from unnest(a) x $$;
create or replace function pg_temp.mn(a numeric[]) returns numeric language sql as $$ select round(min(x)::numeric, 3) from unnest(a) x $$;
create or replace function pg_temp.mx(a numeric[]) returns numeric language sql as $$ select round(max(x)::numeric, 3) from unnest(a) x $$;
create temp table pre (rep int, xs int[], ys int[], zs int[], bl text[], xs_old int[], xs_exp int[]);

do $$
declare
    dim    text := 'minecraft:overworld';
    base   int := current_setting('perf.base')::int;
    rounds int := current_setting('perf.rounds')::int;
    has_exp boolean := to_regprocedure('mc_exp.set_blocks(text,int[],int[],int[],text[])') is not null;
    sc     record;
    rec    record;
    r int; t0 numeric; off_new int; off_old int; off_exp int; c int; s1 int; s2 int; q int; ord int[];
    o numeric[]; nw numeric[]; ex numeric[]; ratio numeric[]; tm numeric;
    pool text[] := array['minecraft:stone','minecraft:glass','minecraft:oak_planks','minecraft:sand','minecraft:gravel','minecraft:air'];
begin
    for sc in select * from (values
        ('B1 10,000 edits in 1 section',        10000,   1, 16, 15,   1),
        ('B2 10,000 edits over 100 sections',   10000,  25, 64, 15,   1),
        ('B3 10,000 edits over 1,000 sections', 10000, 250, 64, 15,   1),
        ('B4 1,000 edits over 10 sections',      1000,   5, 32, 15,   1),
        ('B5 12 edits over 3 sections (mean of 100 calls)', 12, 1, 48, 15, 100),
        ('B6 100 edits over 4 sections (mean of 20 calls)', 100, 1, 64, 15, 20)) v(name, n, nchunks, ysz, zmax, reps)
    loop
        o := '{}'; nw := '{}'; ex := '{}'; ratio := '{}';
        off_new := base; off_old := base + 10000; off_exp := base + 20000; base := base + 30000;
        perform mc.generate_flat_area(dim, off_new, 0, off_new + sc.nchunks - 1, 0);
        perform mc.generate_flat_area(dim, off_old, 0, off_old + sc.nchunks - 1, 0);
        if has_exp then perform mc.generate_flat_area(dim, off_exp, 0, off_exp + sc.nchunks - 1, 0); end if;
        for r in 1 .. rounds loop
            truncate pre;
            insert into pre
            select k, a.xs, a.ys, a.zs, a.bl, array(select x + (off_old - off_new) * 16 from unnest(a.xs) x), array(select x + (off_exp - off_new) * 16 from unnest(a.xs) x)
              from generate_series(1, sc.reps) k
              cross join lateral (select array_agg(off_new * 16 + (random() * (sc.nchunks * 16 - 1))::int) as xs, array_agg(-64 + (random() * (sc.ysz - 1))::int) as ys,
                                         array_agg((random() * sc.zmax)::int) as zs, array_agg(pool[1 + (random() * 5)::int]) as bl
                                    from generate_series(1, sc.n) where k > 0) a;
            -- rotate the order: 0 old,new,exp   1 new,exp,old   2 exp,old,new
            for q in 0 .. 2 loop
                case (r + q) % 3
                    when 0 then
                        t0 := bench.cpu_ms(); for rec in select * from pre order by rep loop c := mc_old.set_blocks(dim, rec.xs_old, rec.ys, rec.zs, rec.bl); end loop; tm := (bench.cpu_ms() - t0) / sc.reps; o := o || tm;
                    when 1 then
                        t0 := bench.cpu_ms(); for rec in select * from pre order by rep loop c := mc.set_blocks(dim, rec.xs, rec.ys, rec.zs, rec.bl);     end loop; tm := (bench.cpu_ms() - t0) / sc.reps; nw := nw || tm;
                    else
                        if has_exp then
                            t0 := bench.cpu_ms(); for rec in select * from pre order by rep loop c := mc_exp.set_blocks(dim, rec.xs_exp, rec.ys, rec.zs, rec.bl); end loop; tm := (bench.cpu_ms() - t0) / sc.reps; ex := ex || tm;
                        end if;
                end case;
            end loop;
            ratio := ratio || (o[r] / nw[r]);
        end loop;
        raise notice '% | old median % ms (min %, max %) | NEW median % ms (min %, max %) | ratio old/new, median % | set-based experiment median % ms',
            sc.name, pg_temp.med(o), pg_temp.mn(o), pg_temp.mx(o), pg_temp.med(nw), pg_temp.mn(nw), pg_temp.mx(nw), pg_temp.med(ratio),
            case when has_exp then pg_temp.med(ex)::text else 'n/a' end;
    end loop;
end $$;
