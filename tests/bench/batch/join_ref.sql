-- Variant 8 micro-benchmark: the chunk burst of a join, by bytes (net.send_chunks + net.drain_outbox) against by reference (net.send_chunks_ref + net.drain_outbox_ref),
-- alternating, with identical-bytes proof (md5 of everything drained).  Needs the warm benchmark database (every chunk generated and cached).
-- usage: psql -v vd=10 -v reps=12 -f tests/bench/batch/join_ref.sql
-- the middle arm: the same frames as net.send_chunks, as BYTES, but chunk packets looked up by ONE set-based join instead of one function call per chunk (no references)
create or replace function bbench.send_chunks_setbytes(p_conn bigint, p_cx int, p_cz int, p_radius int) returns int language plpgsql as $$
declare r int := p_radius + 1; dim text := 'minecraft:overworld'; n int;
        i_bs int := net.pkt('play', 'clientbound', 'minecraft:chunk_batch_start'); i_bf int := net.pkt('play', 'clientbound', 'minecraft:chunk_batch_finished');
begin
    update net.conn set view_cx = p_cx, view_cz = p_cz where conn_id = p_conn;
    with sq as materialized (select s.x, s.z, s.o from net.chunk_square(p_cx, p_cz, r) with ordinality s(x, z, o))
    insert into net.outbox (conn_id, data)
    select p_conn, data from (
        select 1 as ph, 0 as o, proto.frame(i_bs, '\x') as data
        union all
        select 2, sq.o, coalesce((select k.packet from mc.chunk ch join mc.chunk_cache k on k.dimension = ch.dimension and k.cx = ch.cx and k.cz = ch.cz and k.version = ch.version
                                   where ch.dimension = dim and ch.cx = sq.x and ch.cz = sq.z and ch.hm_world_surface is not null and not ch.dirty and not ch.hm_dirty),
                                 mc.chunk_packet_generate(dim, sq.x, sq.z)) from sq
        union all
        select 3, 0, proto.frame(i_bf, proto.varint((select count(*)::int from sq)))
    ) u order by ph, o;
    select count(*)::int into n from net.chunk_square(p_cx, p_cz, r);
    return n;
end $$;

create or replace function bbench.join_bench(p_vd int, p_reps int) returns table(impl text, rep int, cpu_ms float8, wall_ms float8, frames int, bytes bigint, md5 text) language plpgsql as $$
declare i int; k int; s0 bigint[]; s1 bigint[]; t0 timestamptz; r record; cx int := 50; cz int := 50; b bytea;
begin
    perform ibench.setup(2, 100);
    update net.conn set view_cx = null, view_cz = null where conn_id = 1;          -- a freshly joined connection
    delete from net.outbox; delete from net.outbox_x;
    for i in 1..p_reps loop
        for k in 1..3 loop
            impl := (array['bytes','setbytes','ref'])[1 + (i + k) % 3];
            rep := i;
            s0 := bbench.sched(); t0 := clock_timestamp();
            if impl = 'bytes' then
                perform net.send_chunks(1, cx, cz, p_vd);
                select string_agg(d.data, ''::bytea), count(*)::int into b, frames from net.drain_outbox() d where d.conn_id = 1;
            elsif impl = 'setbytes' then
                perform bbench.send_chunks_setbytes(1, cx, cz, p_vd);
                select string_agg(d.data, ''::bytea), count(*)::int into b, frames from net.drain_outbox() d where d.conn_id = 1;
            else
                perform net.send_chunks_ref(1, cx, cz, p_vd);
                select string_agg(d.data, ''::bytea), count(*)::int into b, frames from net.drain_outbox_ref() d where d.conn_id = 1;
            end if;
            s1 := bbench.sched(); wall_ms := extract(epoch from clock_timestamp() - t0) * 1000; cpu_ms := (s1[1] - s0[1]) / 1e6;
            bytes := length(b); md5 := md5(b);
            return next;
        end loop;
    end loop;
end $$;

\echo -- chunk burst of a join at view distance :vd (the square is (2*(vd+1)+1)^2 chunks)
select impl, count(*) n, round((percentile_cont(.5) within group (order by cpu_ms))::numeric, 2) as cpu_ms_median, round((percentile_cont(.5) within group (order by wall_ms))::numeric, 2) as wall_ms_median,
       max(bytes) as bytes, count(distinct md5) as distinct_md5
  from bbench.join_bench(:vd, :reps) group by impl order by impl;
select 'identical bytes between bytes, setbytes and ref: ' || (count(distinct md5) = 1)::text as proof from bbench.join_bench(:vd, 3);
