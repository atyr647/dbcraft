-- Sanity timings (run: psql ... -f pg/bench.sql).  Takes about 10 s.  Uses the world and players currently loaded: it resets both.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
set client_min_messages = notice;
select mc.reset_world() \g /dev/null
do $$
declare t0 timestamptz; best numeric := 1e9; d numeric; i int; n int := 100000; bx int;
begin
    for i in 1 .. 5 loop
        delete from mc.chunk_section where cx = 77 and cz = 77; delete from mc.chunk where cx = 77 and cz = 77;
        t0 := clock_timestamp(); perform mc.gen_chunk(77, 77); d := extract(epoch from clock_timestamp() - t0) * 1000; best := least(best, d);
    end loop;
    raise notice 'gen_chunk: % ms (best of 5)', round(best, 1);
    t0 := clock_timestamp(); perform mc.gen_area(0, 0, 5, 5); raise notice 'gen_area 36 chunks: % ms per chunk', round(extract(epoch from clock_timestamp() - t0) * 1000 / 36, 1);
    t0 := clock_timestamp(); for i in 1 .. n loop bx := mc.get_block(i % 96, 40 + i % 50, (i / 7) % 96); end loop;
    raise notice 'get_block: % calls/s', round(n / extract(epoch from clock_timestamp() - t0));
    t0 := clock_timestamp(); for i in 1 .. n loop perform mc.set_block(i % 96, 40 + i % 50, (i / 7) % 96, 1 + (i / 3) % 12); end loop;
    raise notice 'set_block (plpgsql loop, one transaction): % calls/s', round(n / extract(epoch from clock_timestamp() - t0));
    perform mc.drain_block_events();
    t0 := clock_timestamp(); perform mc.fill(1, 20, 1, 64, 83, 64, 20); raise notice 'fill 64x64x64 (aligned-ish, 5x5x5 sections): % ms', round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
    t0 := clock_timestamp(); perform mc.fill(0, 20, 0, 63, 83, 63, 3); raise notice 'fill 64x64x64 (section aligned): % ms', round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
    t0 := clock_timestamp(); perform mc.fill(5, 22, 5, 68, 85, 68, 1); raise notice 'fill 64x64x64 (unaligned, mixed palettes): % ms', round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
    perform mc.drain_block_events();
    t0 := clock_timestamp(); perform mc.chunk_packet(2, 2); raise notice 'chunk_packet cold (build + cache): % ms', round(extract(epoch from clock_timestamp() - t0) * 1000, 2);
    t0 := clock_timestamp(); for i in 1 .. 200 loop perform mc.chunk_packet(2, 2); end loop; raise notice 'chunk_packet cached: % ms', round(extract(epoch from clock_timestamp() - t0) * 1000 / 200, 3);
end $$;
do $$
declare np int; t int; i int; t0 timestamptz; tot numeric := 0; mx numeric := 0; d numeric; conns int[]; cx float8[]; cz float8[]; payloads bytea[]; rows int := 0; r int;
begin
    foreach np in array array[500, 2000] loop
        perform mc.reset_players();
        perform mc.join_bulk((select array_agg(g) from generate_series(1, np) g), (select array_agg(random() * 300) from generate_series(1, np) g),
                             (select array_agg(64.0) from generate_series(1, np) g), (select array_agg(random() * 300) from generate_series(1, np) g));
        perform mc.vis_init();
        tot := 0; mx := 0; rows := 0;
        for t in 1 .. 30 loop
            select array_agg(eid), array_agg(x + (random() - 0.5) * 6), array_agg(z + (random() - 0.5) * 6) into conns, cx, cz from mc.player where (eid * 7 + t) % 5 = 0;
            perform mc.inbox_push(conns, (select array_agg(mc.move_payload(cx[j], 64, cz[j], (t * 3)::float4, 0, true) order by j) from generate_series(1, cardinality(conns)) j));
            t0 := clock_timestamp(); perform mc.server_tick(); d := extract(epoch from clock_timestamp() - t0) * 1000;
            tot := tot + d; mx := greatest(mx, d);
            select count(*) into r from mc.outbox_drain(); rows := rows + r;
        end loop;
        raise notice 'server_tick % players, 20%% moving: avg % ms, max % ms, % packets/tick', np, round(tot / 30, 2), round(mx, 2), rows / 30;
    end loop;
end $$;
