-- Batched pipeline, part 5: reference-based outbox (flag `ref`, OPT-IN experiment; the default `all` does not include it).
--
-- A chunk packet (~3-7 KB) that is already in mc.chunk_cache is not copied into every recipient's queue row.  The queue row holds a REFERENCE (dimension, cx, cz and the
-- cache version at enqueue time); only net.drain_outbox_ref(), the function the gateway calls instead of net.drain_outbox(), expands it with a join to mc.chunk_cache, so
-- a cached packet is copied once, into the drain result, instead of into play_out, into the per-connection blob, into net.outbox and into the drain.
--
-- Queues: mc.play_out_x (the game's side; shares the sequence of mc.play_out so the order across both is the generation order) and net.outbox_x (the connection
-- layer's side; shares net.outbox_seq with net.outbox).  A row either holds bytes (data) or a reference (data is NULL, dim/cx/cz/version are set).
--
-- SEMANTICS of a reference whose cache entry was replaced between enqueue and drain (the chunk changed and its packet was rebuilt): the row means "this chunk's packet
-- as of enqueue time"; if the cached version is no longer that version, drain sends the chunk's CURRENT packet (mc.chunk_packet, which rebuilds when needed).
-- That is newer data, never older and never a mix; the block changes that caused the replacement are broadcast anyway, so a client that gets the newer packet
-- and then a block update for the same change ends in the same state.  Within one tick (enqueue and drain in the same tick, which is how the gateway works) this
-- case cannot occur and the bytes equal the baseline's.  A connection with compression enabled never gets references (they are expanded before re-framing).
do $$
begin
    execute format('create unlogged table if not exists mc.play_out_x (seq bigint not null default nextval(%L), conn_id int not null, data bytea, dim text, cx int, cz int, version bigint)',
                   pg_get_serial_sequence('mc.play_out', 'seq'));
end $$;
create unlogged table if not exists net.outbox_x (conn_id bigint not null, seq bigint not null default nextval('net.outbox_seq'), data bytea, dim text, cx int, cz int, version bigint);

-- the cached packet of a chunk if its cache entry is still `p_version`, else the current packet; written out where it is used (a function call per row costs more than the copy it saves)
create or replace function mc.resolve_chunk_ref(p_dim text, p_cx int, p_cz int, p_version bigint) returns bytea language sql volatile as $$
    select coalesce((select k.packet from mc.chunk_cache k where k.dimension = p_dim and k.cx = p_cx and k.cz = p_cz and k.version = p_version), mc.chunk_packet(p_dim, p_cx, p_cz)) $$;

------------------------------------------------------------------------------------------------ enqueue: chunk streaming for players that crossed a border
create or replace function net.stream_chunks_ref() returns int language plpgsql as $$
declare r int := mc.prop_int('view-distance') + 1; dim text := 'minecraft:overworld';
        i_ctr int := mc.pid('set_chunk_cache_center'); i_fg int := mc.pid('forget_level_chunk'); i_bs int := mc.pid('chunk_batch_start'); i_bf int := mc.pid('chunk_batch_finished');
begin
    if not exists (select 1 from net.conn c join mc.player p on p.conn_id = c.conn_id
                    where c.state = 'play' and not c.closing and c.view_cx is not null and (p.chunk_x, p.chunk_z) <> (c.view_cx, c.view_cz)) then
        return 0;
    end if;
    if not mc.world_ready() then return 0; end if;
    with st as materialized (
        select c.conn_id, p.chunk_x as ncx, p.chunk_z as ncz, c.view_cx as ocx, c.view_cz as ocz
          from net.conn c join mc.player p on p.conn_id = c.conn_id
         where c.state = 'play' and not c.closing and c.view_cx is not null and (p.chunk_x, p.chunk_z) <> (c.view_cx, c.view_cz)),
    stn as materialized (
        select s.conn_id, s.ncx + dx as x, s.ncz + dz as z, dx * dx + dz * dz as d
          from st s, generate_series(-r, r) dx, generate_series(-r, r) dz
         where abs(s.ncx + dx - s.ocx) > r or abs(s.ncz + dz - s.ocz) > r),
    upd as (update net.conn c set view_cx = s.ncx, view_cz = s.ncz from st s where c.conn_id = s.conn_id returning 1)
    insert into mc.play_out_x (conn_id, data, dim, cx, cz, version)
    select conn_id, data, d_, cx_, cz_, ver from (
        select conn_id, 1 as ph, 0 as k1, 0 as k2, 0 as k3, proto.frame(i_ctr, proto.varint(ncx) || proto.varint(ncz)) as data, null::text as d_, null::int as cx_, null::int as cz_, null::bigint as ver from st
        union all
        select s.conn_id, 2, s.ocx + dx, s.ocz + dz, 0, proto.frame(i_fg, proto.i32(s.ocz + dz) || proto.i32(s.ocx + dx)), null, null, null, null
          from st s, generate_series(-r, r) dx, generate_series(-r, r) dz
         where abs(s.ocx + dx - s.ncx) > r or abs(s.ocz + dz - s.ncz) > r
        union all
        select distinct conn_id, 3, 0, 0, 0, proto.frame(i_bs, '\x'), null::text, null::int, null::int, null::bigint from stn
        union all
        -- a chunk whose cache is current is sent by reference; a missing or stale one is generated/rebuilt now and its bytes sent inline
        select q.conn_id, 4, q.d, q.x, q.z, g.data, case when g.data is null then dim end, case when g.data is null then q.x end, case when g.data is null then q.z end, v.ver
          from stn q
          cross join lateral (select (select ch.version from mc.chunk ch join mc.chunk_cache k on k.dimension = ch.dimension and k.cx = ch.cx and k.cz = ch.cz and k.version = ch.version
                                       where ch.dimension = dim and ch.cx = q.x and ch.cz = q.z and ch.hm_world_surface is not null and not ch.dirty and not ch.hm_dirty) as ver) v
          cross join lateral (select case when v.ver is not null then null::bytea else mc.chunk_packet_generate(dim, q.x, q.z) end as data) g
        union all
        select conn_id, 5, 0, 0, 0, proto.frame(i_bf, proto.varint(count(*)::int)), null, null, null, null from stn group by conn_id
    ) u order by conn_id, ph, k1, k2, k3;
    return 1;
end $$;

------------------------------------------------------------------------------------------------ enqueue: the chunks of a join (what net.send_chunks does, by reference)
-- Same frames as net.send_chunks for a connection without compression: batch start, one chunk packet per chunk of the square (nearest first), batch finished with the count.
-- Chunks that do not exist yet are generated first; a chunk with a stale cache is rebuilt first, then referenced.  Returns the number of chunks.
create or replace function net.send_chunks_ref(p_conn bigint, p_cx int, p_cz int, p_radius int) returns int language plpgsql as $$
declare r int := p_radius + 1; dim text := 'minecraft:overworld'; n int;
        i_bs int := net.pkt('play', 'clientbound', 'minecraft:chunk_batch_start'); i_bf int := net.pkt('play', 'clientbound', 'minecraft:chunk_batch_finished');
begin
    if not mc.world_ready() then return 0; end if;
    update net.conn set view_cx = p_cx, view_cz = p_cz where conn_id = p_conn;
    with sq as materialized (select s.x, s.z, s.o from net.chunk_square(p_cx, p_cz, r) with ordinality s(x, z, o)),
    pre as materialized (   -- make every cache entry current (generate / rebuild what is missing or stale); per-row lookups, see the planner note in sql/380
        select sq.x, sq.z, sq.o,
               coalesce((select ch.version from mc.chunk ch join mc.chunk_cache k on k.dimension = ch.dimension and k.cx = ch.cx and k.cz = ch.cz and k.version = ch.version
                          where ch.dimension = dim and ch.cx = sq.x and ch.cz = sq.z and ch.hm_world_surface is not null and not ch.dirty and not ch.hm_dirty),
                        (select ch.version from mc.chunk ch where ch.dimension = dim and ch.cx = sq.x and ch.cz = sq.z and mc.chunk_packet_generate(dim, sq.x, sq.z) is not null),
                        (select ch.version from mc.chunk ch where ch.dimension = dim and ch.cx = sq.x and ch.cz = sq.z)) as ver
          from sq)
    insert into net.outbox_x (conn_id, data, dim, cx, cz, version)
    select p_conn, data, d_, cx_, cz_, ver from (
        select 1 as ph, 0 as o, proto.frame(i_bs, '\x') as data, null::text as d_, null::int as cx_, null::int as cz_, null::bigint as ver
        union all select 2, o, null::bytea, dim, x, z, ver from pre
        union all select 3, 0, proto.frame(i_bf, proto.varint((select count(*)::int from pre))), null, null, null, null
    ) u order by ph, o;
    select count(*)::int into n from generate_series(-r, r) dx, generate_series(-r, r) dz;
    return n;
end $$;

------------------------------------------------------------------------------------------------ tick side: move both game queues to net.outbox_x, keeping references as references
-- Like mc.drain_batched (sql/380) but references stay rows of their own: consecutive byte rows of a connection are concatenated into one row, a reference is one row.
-- Rows keep their relative order (the new rows take net.outbox_seq values in that order).  A connection with compression enabled gets references expanded to bytes first.
create or replace function mc.drain_batched_ref(cur bigint) returns int language plpgsql as $$
declare r record; n int := 0;
begin
    for r in
        with a as (delete from mc.play_out returning seq, conn_id, data),
             b as (delete from mc.play_out_x returning seq, conn_id, data, dim, cx, cz, version),
             u as (select seq, conn_id, data, null::text as dim, null::int as cx, null::int as cz, null::bigint as version from a
                   union all select seq, conn_id, data, dim, cx, cz, version from b),
             j as (select u.*, c.compression as comp from u join net.conn c on c.conn_id = u.conn_id and c.state = 'play'),
             g as (select j.*, count(*) filter (where j.data is null) over (partition by j.conn_id order by j.seq rows between unbounded preceding and 1 preceding) as nref_before from j where comp < 0),
             runs as (select conn_id, min(seq) as s0, string_agg(data, ''::bytea order by seq) as data, null::text as dim, null::int as cx, null::int as cz, null::bigint as version
                        from g where data is not null group by conn_id, nref_before
                      union all
                      select conn_id, seq, null::bytea, dim, cx, cz, version from g where data is null),
             ins as (insert into net.outbox_x (conn_id, data, dim, cx, cz, version)
                     select conn_id, data, dim, cx, cz, version from runs order by conn_id, s0 returning 1)
        select null::int as conn_id, null::int as comp, null::bytea as data, (select count(*)::int from j) as n
        union all
        select conn_id, comp, string_agg(coalesce(data, coalesce((select k.packet from mc.chunk_cache k where k.dimension = j.dim and k.cx = j.cx and k.cz = j.cz and k.version = j.version),
                                                                    mc.chunk_packet(j.dim, j.cx, j.cz))), ''::bytea order by seq), 0
          from j where comp >= 0 group by conn_id, comp
    loop
        if r.conn_id is null then
            n := r.n;
        else
            begin
                insert into net.outbox (conn_id, data) values (r.conn_id, net.reframe(r.comp, r.data));
            exception when others then
                insert into mc.error_log (tick, step, message) values (cur, 'reframe', sqlerrm);
                perform net.close(r.conn_id);
            end;
        end if;
    end loop;
    return n;
end $$;

------------------------------------------------------------------------------------------------ gateway side: what the gateway calls instead of net.drain_outbox() when `ref` is on
-- Same result as net.drain_outbox(): per connection all pending bytes in order, and whether to close afterwards.  References are expanded here, by one join to the cache.
create or replace function net.drain_outbox_ref() returns table(conn_id bigint, data bytea, close boolean) language plpgsql as $$
begin
    return query
    with o as (delete from net.outbox returning net.outbox.conn_id, net.outbox.seq, net.outbox.data),
         x as (delete from net.outbox_x returning net.outbox_x.conn_id, net.outbox_x.seq, net.outbox_x.data, net.outbox_x.dim, net.outbox_x.cx, net.outbox_x.cz, net.outbox_x.version),
         u as (select o.conn_id, o.seq, o.data, null::text as dim, null::int as cx, null::int as cz, null::bigint as version from o
               union all select x.conn_id, x.seq, x.data, x.dim, x.cx, x.cz, x.version from x),
         agg as (select u.conn_id,
                        string_agg(coalesce(u.data, coalesce((select k.packet from mc.chunk_cache k where k.dimension = u.dim and k.cx = u.cx and k.cz = u.cz and k.version = u.version),
                                                              mc.chunk_packet(u.dim, u.cx, u.cz))), ''::bytea order by u.seq) as data
                   from u group by u.conn_id),
         cl as (select c.conn_id from net.conn c where c.closing)
    select coalesce(a.conn_id, cl.conn_id), coalesce(a.data, '\x'::bytea), (cl.conn_id is not null)
    from agg a full join cl on cl.conn_id = a.conn_id;
    delete from net.conn where closing;
end $$;
