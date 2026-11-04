-- Reconciliation of two independent optimisations of net.stream_chunks (found when merging):
--   * sql/432_tick_perf_world.sql (tick worker): the players that changed chunk and the chunks they need are computed with PL/pgSQL arrays (no temp tables, so no
--     plan invalidation per tick), but it generated missing chunks INLINE on the tick and sent them itself.
--   * sql/430_chunk_queue.sql (chunk worker): missing chunks are REQUESTED (mc.want_chunks) and delivered when ready (mc.deliver_ready_chunks), so exploring
--     does not stall the tick in async mode, and delivery owns batching and compression framing.
-- This file keeps the first one's computation and the second one's request/delivery calls.  It must apply after both (it is numbered 436).
-- tools/check_fresh_migration.sh asserts that a clean migration ends with this definition.
create or replace function net.stream_chunks() returns int language plpgsql as $$
declare srv int := mc.prop_int('view-distance'); vison boolean := mc.vis_on(); dim text := 'minecraft:overworld'; n int;
        i_ctr int := mc.pid('set_chunk_cache_center'); i_fg int := mc.pid('forget_level_chunk');
        sc int[]; sncx int[]; sncz int[]; socx int[]; socz int[]; snr int[]; sor int[];            -- the players whose view changes: connection, new chunk, chunk their client is centred on, radii of the new and the old square
        wc_c int[]; wc_x int[]; wc_z int[]; wc_d int[];                                            -- the chunks that entered their squares: connection, chunk, squared distance (async mode)
begin
    if mc.world_ready() then
        -- a player's square has the radius view distance + 1; the view distance is the server's, or (dbcraft.vanilla-tracker, sql/909) the one the client asked for, clamped to 2 .. the server's
        select array_agg(c.conn_id::int), array_agg(p.chunk_x), array_agg(p.chunk_z), array_agg(c.view_cx), array_agg(c.view_cz),
               array_agg(case when vison then greatest(2, least(coalesce(p.view_distance_req, 2), srv)) + 1 else srv + 1 end), array_agg(coalesce(c.view_r, srv + 1))
          into sc, sncx, sncz, socx, socz, snr, sor
        from net.conn c join mc.player p on p.conn_id = c.conn_id
        where c.state = 'play' and not c.closing and c.view_cx is not null
          and ((p.chunk_x, p.chunk_z) <> (c.view_cx, c.view_cz) or coalesce(c.view_r, srv + 1) <> (case when vison then greatest(2, least(coalesce(p.view_distance_req, 2), srv)) + 1 else srv + 1 end));
        n := coalesce(cardinality(sc), 0);
        if n > 0 then
            -- the centre moves only when the player changed chunk (a new view distance alone sends chunks or forgets them, no centre: recorded)
            insert into mc.play_out (conn_id, data)
            select s.conn_id, proto.frame(i_ctr, proto.varint(s.ncx) || proto.varint(s.ncz)) from unnest(sc, sncx, sncz, socx, socz) as s(conn_id, ncx, ncz, ocx, ocz) where (s.ncx, s.ncz) <> (s.ocx, s.ocz) order by s.conn_id;
            -- chunks that left the client's square: x ascending, then z (ChunkTrackingView.difference iterates x in the outer loop: recorded with a shrinking and a teleported view; the body is z first)
            insert into mc.play_out (conn_id, data)
            select s.conn_id, proto.frame(i_fg, proto.i32(s.ocz + dz) || proto.i32(s.ocx + dx))
            from unnest(sc, sncx, sncz, socx, socz, snr, sor) as s(conn_id, ncx, ncz, ocx, ocz, nr, orr), generate_series(-s.orr, s.orr) dx, generate_series(-s.orr, s.orr) dz
            where abs(s.ocx + dx - s.ncx) > s.nr or abs(s.ocz + dz - s.ncz) > s.nr
            order by s.conn_id, s.ocx + dx, s.ocz + dz;
            -- the client's view moves now, so the chunks that entered the square pass the range check of the delivery step
            update net.conn c set view_cx = s.ncx, view_cz = s.ncz, view_r = s.nr from unnest(sc, sncx, sncz, snr) as s(conn_id, ncx, ncz, nr) where c.conn_id = s.conn_id;
            -- the chunks that entered the square are wanted (generated now in inline mode, requested in async mode)
            if mc.chunk_generation_async() then
                -- (docs/PERF-CAPACITY.md) async mode: what mc.want_chunks does for each connection, for all of them in two statements (a call per connection was 0.4 ms each, 9 a tick
                -- with 500 walkers): the wanted rows, and one request per chunk that does not exist yet with the smallest distance of its requesters (the order of the per-connection calls
                -- made the same least())
                -- (the rows go through arrays: the planner estimates 10 rows for an unnest and 10 million for the cross join of generate_series, and with the second estimate it
                -- scanned the whole of mc.chunk to find the chunks that do not exist: 10 ms)
                select array_agg(q.conn_id), array_agg(q.x), array_agg(q.z), array_agg(q.d) into wc_c, wc_x, wc_z, wc_d
                  from (select s.conn_id, s.ncx + dx as x, s.ncz + dz as z, dx * dx + dz * dz as d
                          from unnest(sc, sncx, sncz, socx, socz, snr, sor) as s(conn_id, ncx, ncz, ocx, ocz, nr, orr), generate_series(-s.nr, s.nr) dx, generate_series(-s.nr, s.nr) dz
                         where abs(s.ncx + dx - s.ocx) > s.orr or abs(s.ncz + dz - s.ocz) > s.orr) q;
                if wc_c is not null then
                    insert into mc.chunk_wanted (conn_id, dimension, cx, cz, dist) select u.c, dim, u.x, u.z, u.d from unnest(wc_c, wc_x, wc_z, wc_d) as u(c, x, z, d)
                    on conflict (conn_id, dimension, cx, cz) do update set dist = excluded.dist;
                    insert into mc.chunk_request (dimension, cx, cz, prio)
                    select dim, u.x, u.z, min(u.d) from unnest(wc_c, wc_x, wc_z, wc_d) as u(c, x, z, d)
                     where not exists (select 1 from mc.chunk c where c.dimension = dim and c.cx = u.x and c.cz = u.z)
                     group by u.x, u.z
                    on conflict (dimension, cx, cz) do update set prio = least(mc.chunk_request.prio, excluded.prio);
                end if;
            else
                perform mc.want_chunks(q.conn_id, dim, array_agg(q.x), array_agg(q.z), array_agg(q.d))
                  from (select s.conn_id, s.ncx + dx as x, s.ncz + dz as z, dx * dx + dz * dz as d
                          from unnest(sc, sncx, sncz, socx, socz, snr, sor) as s(conn_id, ncx, ncz, ocx, ocz, nr, orr), generate_series(-s.nr, s.nr) dx, generate_series(-s.nr, s.nr) dz
                         where abs(s.ncx + dx - s.ocx) > s.orr or abs(s.ncz + dz - s.ocz) > s.orr) q
                 group by q.conn_id;
            end if;
        end if;
    end if;
    perform mc.deliver_ready_chunks();
    return coalesce(n, 0);
end $$;
