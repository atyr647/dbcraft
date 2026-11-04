-- A fill (or a single edit) with a player in range: the cost of the statement that changes the blocks and of the tick's broadcast of the change (docs/PERF-WORLD2.md).
--   psql -X -d DB -v rounds=7 -f tests/bench/world2/bench_broadcast.sql          (superuser: the CPU timer reads /proc/self/schedstat)
-- One fake connection in 'play' state looks at chunk (0, 0) (view distance 10 + 1), so every section of the scenarios is visible; the second pass has nobody in range.
-- Per scenario and round: CPU ms of the backend for (a) the editing statement, (b) mc.broadcast_block_events() (what the tick's step 5 spends), (c) bytes queued for the
-- connection (mc.play_out).  Stone and air alternate so that every call changes every block.  Prints median (min - max) over the rounds.
\set ON_ERROR_STOP on
\ir ../edit/cpu_timer.sql
set jit = off;
\if :{?rounds}
\else
\set rounds 7
\endif
select set_config('perf.rounds', :'rounds', false);
select mc.generate_flat_area('minecraft:overworld', -4, -4, 4, 4);
create or replace function pg_temp.fmt(a numeric[]) returns text language sql as $$
  select round((percentile_cont(0.5) within group (order by x))::numeric, 2) || ' (' || round(min(x)::numeric, 2) || ' - ' || round(max(x)::numeric, 2) || ')' from unnest(a) x $$;

do $$
declare
    rounds int := current_setting('perf.rounds')::int;
    sc record; r int; t0 numeric; viewer boolean; nbytes bigint;
    ea numeric[]; eb numeric[]; ec numeric[]; blk text;
begin
    raise notice '% rounds; CPU ms: median (min - max)', rounds;
    for viewer in select * from (values (true), (false)) v loop
      truncate net.conn, mc.play_out, mc.block_event, mc.pending_ack, mc.block_actor;
      if viewer then insert into net.conn (conn_id, state, compression, closing, view_cx, view_cz) values (1, 'play', -1, false, 0, 0); end if;
      for sc in select * from (values
        ('1 block (setblock)',                      'set',   5, -60,   5,  5, -60,  5),
        ('10 blocks (10x1x1)',                      'fill',  0, -60,   0,  9, -60,  0),
        ('48 blocks (4x4x3, the per-block path)',   'fill',  0, -60,   0,  3, -58,  3),
        ('1,000 blocks (10x10x10)',                 'fill',  0, -60,   0,  9, -51,  9),
        ('one whole section (16x16x16)',            'fill',  0, -48,   0, 15, -33, 15),
        ('64 whole sections',                       'fill',  0, -64,   0, 63,  -1, 63),
        ('100,000 blocks (50x40x50, scoreboard)',   'fill',-25, -60, -25, 24, -21, 24)) v(name, kind, x1, y1, z1, x2, y2, z2)
      loop
        ea := '{}'; eb := '{}'; ec := '{}';
        perform mc.fill('minecraft:overworld', sc.x1, sc.y1, sc.z1, sc.x2, sc.y2, sc.z2, 'minecraft:air'); truncate mc.block_event;
        -- round 0 is a warm-up (plans, caches), not measured
        for r in 0 .. rounds loop
            blk := case when r % 2 = 0 then 'minecraft:stone' else 'minecraft:air' end;
            t0 := bench.cpu_ms();
            if sc.kind = 'set' then perform mc.set_block('minecraft:overworld', sc.x1, sc.y1, sc.z1, blk);
            else perform mc.fill('minecraft:overworld', sc.x1, sc.y1, sc.z1, sc.x2, sc.y2, sc.z2, blk); end if;
            ea := ea || (bench.cpu_ms() - t0);
            t0 := bench.cpu_ms();
            perform mc.broadcast_block_events();
            eb := eb || (bench.cpu_ms() - t0);
            select coalesce(sum(octet_length(data)), 0) into nbytes from mc.play_out;
            ec := ec || nbytes::numeric;
            truncate mc.play_out;
            if r = 0 then ea := '{}'; eb := '{}'; ec := '{}'; end if;
        end loop;
        raise notice '% | % | statement % | broadcast % | % kB queued', case when viewer then 'viewer' else 'nobody' end, rpad(sc.name, 40), pg_temp.fmt(ea), pg_temp.fmt(eb), (ec[1] / 1000)::int;
      end loop;
    end loop;
end $$;
