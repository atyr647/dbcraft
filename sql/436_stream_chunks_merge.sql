-- Reconciliation of two independent optimisations of net.stream_chunks (found when merging):
--   * sql/432_tick_perf_world.sql (tick worker): the players that changed chunk and the chunks they need are computed with PL/pgSQL arrays (no temp tables, so no
--     plan invalidation per tick), but it generated missing chunks INLINE on the tick and sent them itself.
--   * sql/430_chunk_queue.sql (chunk worker): missing chunks are REQUESTED (mc.want_chunks) and delivered when ready (mc.deliver_ready_chunks), so exploring
--     does not stall the tick in async mode, and delivery owns batching and compression framing.
-- This file keeps the first one's computation and the second one's request/delivery calls.  It must apply after both (it is numbered 436).
-- tools/check_fresh_migration.sh asserts that a clean migration ends with this definition.
create or replace function net.stream_chunks() returns int language plpgsql as $$
declare r int := mc.prop_int('view-distance') + 1; dim text := 'minecraft:overworld'; n int;
        i_ctr int := mc.pid('set_chunk_cache_center'); i_fg int := mc.pid('forget_level_chunk');
        sc int[]; sncx int[]; sncz int[]; socx int[]; socz int[];            -- the players whose chunk changed: connection, new chunk, chunk their client is centred on
begin
    if mc.world_ready() then
        select array_agg(c.conn_id::int), array_agg(p.chunk_x), array_agg(p.chunk_z), array_agg(c.view_cx), array_agg(c.view_cz) into sc, sncx, sncz, socx, socz
        from net.conn c join mc.player p on p.conn_id = c.conn_id
        where c.state = 'play' and not c.closing and c.view_cx is not null and (p.chunk_x, p.chunk_z) <> (c.view_cx, c.view_cz);
        n := coalesce(cardinality(sc), 0);
        if n > 0 then
            insert into mc.play_out (conn_id, data)
            select s.conn_id, proto.frame(i_ctr, proto.varint(s.ncx) || proto.varint(s.ncz)) from unnest(sc, sncx, sncz) as s(conn_id, ncx, ncz) order by s.conn_id;
            -- chunks that left the client's square: z ascending, then x (the order of the one recorded case)
            insert into mc.play_out (conn_id, data)
            select s.conn_id, proto.frame(i_fg, proto.i32(s.ocz + dz) || proto.i32(s.ocx + dx))
            from unnest(sc, sncx, sncz, socx, socz) as s(conn_id, ncx, ncz, ocx, ocz), generate_series(-r, r) dx, generate_series(-r, r) dz
            where abs(s.ocx + dx - s.ncx) > r or abs(s.ocz + dz - s.ncz) > r
            order by s.conn_id, s.ocz + dz, s.ocx + dx;
            -- the client's view moves now, so the chunks that entered the square pass the range check of the delivery step
            update net.conn c set view_cx = s.ncx, view_cz = s.ncz from unnest(sc, sncx, sncz) as s(conn_id, ncx, ncz) where c.conn_id = s.conn_id;
            -- the chunks that entered the square are wanted (generated now in inline mode, requested in async mode)
            perform mc.want_chunks(q.conn_id, dim, array_agg(q.x), array_agg(q.z), array_agg(q.d))
              from (select s.conn_id, s.ncx + dx as x, s.ncz + dz as z, dx * dx + dz * dz as d
                      from unnest(sc, sncx, sncz, socx, socz) as s(conn_id, ncx, ncz, ocx, ocz), generate_series(-r, r) dx, generate_series(-r, r) dz
                     where abs(s.ncx + dx - s.ocx) > r or abs(s.ncz + dz - s.ocz) > r) q
             group by q.conn_id;
        end if;
    end if;
    perform mc.deliver_ready_chunks();
    return coalesce(n, 0);
end $$;
