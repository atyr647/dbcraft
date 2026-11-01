-- The chunk path of a join / chunk streaming in isolation: read the cached packets of a 21 x 21 area (441 chunks, what a view distance 9 join needs),
-- frame them, put them in the outbound queue, drain the queue.  Compares TOAST storage modes of the cache column and of the queue column.
-- Run by tests/bench/tuning/chunkpath.sh on a throwaway copy of the golden database.  Times are best-of-reps milliseconds for the whole 441 chunks.
create schema if not exists tune;

create or replace function tune.time_chunk_path(p_reps int default 9) returns table (step text, best_ms float8, median_ms float8, bytes bigint) language plpgsql as $$
declare
    r int; t0 timestamptz; ms_fetch float8[] := '{}'; ms_ins float8[] := '{}'; ms_drain float8[] := '{}'; b bigint; n int; fid int := net.pkt('play', 'clientbound', 'minecraft:level_chunk_with_light');
begin
    for r in 1 .. p_reps loop
        t0 := clock_timestamp();
        select sum(length(mc.chunk_body_cached('minecraft:overworld', x, z))), count(*) into b, n from generate_series(40, 60) x, generate_series(40, 60) z;
        ms_fetch := ms_fetch || extract(epoch from clock_timestamp() - t0)::float8 * 1000;
        t0 := clock_timestamp();
        insert into net.outbox (conn_id, data)
        select 1, net.frame(-1, fid, mc.chunk_body_cached('minecraft:overworld', x, z)) from generate_series(40, 60) x, generate_series(40, 60) z;
        ms_ins := ms_ins || extract(epoch from clock_timestamp() - t0)::float8 * 1000;
        t0 := clock_timestamp();
        perform count(*), sum(length(data)) from net.drain_outbox();
        ms_drain := ms_drain || extract(epoch from clock_timestamp() - t0)::float8 * 1000;
    end loop;
    return query select 'fetch 441 cached bodies', (select min(x) from unnest(ms_fetch) x), (select percentile_cont(.5) within group (order by x) from unnest(ms_fetch) x), b;
    return query select 'frame + insert into net.outbox', (select min(x) from unnest(ms_ins) x), (select percentile_cont(.5) within group (order by x) from unnest(ms_ins) x), b;
    return query select 'net.drain_outbox (delete returning)', (select min(x) from unnest(ms_drain) x), (select percentile_cont(.5) within group (order by x) from unnest(ms_drain) x), b;
end $$;
