-- A/B: the fill and the tick's broadcast of the commit this work started from (schema bench_head, tests/bench/world2/head_impl.sql) against the current functions, with ONE
-- connection looking at the area (a fake 'play' connection at chunk 0, 0), interleaved in one session (docs/PERF-WORLD2.md).
--   psql -X -d DB -f tests/bench/world2/head_impl.sql ; psql -X -d DB -v rounds=9 -f tests/bench/world2/ab_world2.sql        (superuser: the CPU timer reads /proc/self/schedstat)
-- Both implementations edit the SAME area, one after the other, a group = `reps` calls (even) that alternate between stone and air so that every call changes every block
-- (the mean is over both directions: the packet of state 0 is shorter than the others).  The backend's CPU time (bench.cpu_ms, resolution 4 ms: hence groups of many calls for
-- the small scenarios) of two kinds of group per implementation, run one after the other:
--   A = reps x (the editing statement, then mc.broadcast_block_events() as the tick's step 5 does)      B = reps x (the editing statement, then the queued events are discarded)
-- fill = B / reps, bcast = (A - B) / reps.  The order of the two implementations flips every round.  Median (min - max) over the rounds, ms per call.
\set ON_ERROR_STOP on
\ir ../edit/cpu_timer.sql
set jit = off;
\if :{?rounds}
\else
\set rounds 9
\endif
select set_config('perf.rounds', :'rounds', false);
select mc.generate_flat_area('minecraft:overworld', -4, -4, 4, 4);
create temp table ab_res (scenario text, ord int, impl text, fill numeric, bcast numeric);
create or replace function pg_temp.edit(impl text, kind text, x1 int, y1 int, z1 int, x2 int, y2 int, z2 int, blk text) returns void language plpgsql as $$
begin
    if kind = 'set' then perform mc.set_block('minecraft:overworld', x1, y1, z1, blk);
    elsif impl = 'head' then perform bench_head.fill('minecraft:overworld', x1, y1, z1, x2, y2, z2, blk);
    else perform mc.fill('minecraft:overworld', x1, y1, z1, x2, y2, z2, blk); end if;
end $$;
create or replace function pg_temp.grp(impl text, kind text, x1 int, y1 int, z1 int, x2 int, y2 int, z2 int, reps int, with_bcast boolean) returns numeric language plpgsql as $$
declare g int; t0 numeric; blk text; tot numeric := 0;
begin
    truncate mc.block_event, mc.play_out;
    t0 := bench.cpu_ms();
    for g in 1 .. reps loop
        blk := case when g % 2 = 1 then 'minecraft:stone' else 'minecraft:air' end;
        perform pg_temp.edit(impl, kind, x1, y1, z1, x2, y2, z2, blk);
        if with_bcast then
            perform case when impl = 'head' then bench_head.broadcast_block_events() else mc.broadcast_block_events() end;
        else delete from mc.block_event; end if;
    end loop;
    tot := bench.cpu_ms() - t0;
    truncate mc.block_event, mc.play_out;
    return tot;
end $$;

do $$
declare
    rounds int := current_setting('perf.rounds')::int;
    sc record; r int; q int; impl text; a numeric; b numeric; ix int := 0; first text;
begin
    truncate net.conn, mc.play_out, mc.block_event, mc.pending_ack, mc.block_actor;
    insert into net.conn (conn_id, state, compression, closing, view_cx, view_cz) values (1, 'play', -1, false, 0, 0);
    for sc in select * from (values
        ('1 block (setblock)',                      'set',   5, -60,   5,  5, -60,  5, 100),
        ('10 blocks (10x1x1)',                      'fill',  0, -60,   0,  9, -60,  0, 100),
        ('48 blocks (4x4x3, the per-block path)',   'fill',  0, -60,   0,  3, -58,  3, 50),
        ('1,000 blocks (10x10x10)',                 'fill',  0, -60,   0,  9, -51,  9, 40),
        ('one whole section (16x16x16)',            'fill',  0, -48,   0, 15, -33, 15, 40),
        ('64 whole sections',                       'fill',  0, -64,   0, 63,  -1, 63, 2),
        ('100,000 blocks (50x40x50, scoreboard)',   'fill',-25, -60, -25, 24, -21, 24, 2)) v(name, kind, x1, y1, z1, x2, y2, z2, reps)
    loop
        ix := ix + 1;
        perform mc.fill('minecraft:overworld', sc.x1, sc.y1, sc.z1, sc.x2, sc.y2, sc.z2, 'minecraft:air'); truncate mc.block_event;
        raise notice 'scenario % (% calls per group)', sc.name, sc.reps;
        for r in 0 .. rounds loop                                   -- round 0 = warm-up (plans, caches)
            first := case when r % 2 = 0 then 'head' else 'new' end;
            for q in 0 .. 1 loop
                impl := case when q = 0 then first when first = 'head' then 'new' else 'head' end;
                b := pg_temp.grp(impl, sc.kind, sc.x1, sc.y1, sc.z1, sc.x2, sc.y2, sc.z2, sc.reps, false);
                a := pg_temp.grp(impl, sc.kind, sc.x1, sc.y1, sc.z1, sc.x2, sc.y2, sc.z2, sc.reps, true);
                if r > 0 then insert into ab_res values (sc.name, ix, impl, b / sc.reps, (a - b) / sc.reps); end if;
            end loop;
        end loop;
    end loop;
end $$;

\pset format aligned
select scenario, impl,
       lpad(round((percentile_cont(0.5) within group (order by fill))::numeric, 3) || ' (' || round(min(fill), 3) || ' - ' || round(max(fill), 3) || ')', 28) as "fill ms",
       lpad(round((percentile_cont(0.5) within group (order by bcast))::numeric, 3) || ' (' || round(min(bcast), 3) || ' - ' || round(max(bcast), 3) || ')', 28) as "bcast ms",
       lpad(round((percentile_cont(0.5) within group (order by fill + bcast))::numeric, 3)::text, 8) as "sum"
  from ab_res group by scenario, ord, impl order by ord, impl desc;
