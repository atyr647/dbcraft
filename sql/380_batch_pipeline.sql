-- Global per-tick batched pipeline: an OPT-IN alternative entry point, mc.server_tick_batched(), that gives the gateway byte-identical output to mc.server_tick()
-- (tests/sql/385_*, 386_*) with fewer statements, no DDL in the tick, and fewer copies of every frame.  Nothing here replaces or edits an existing function.
--
-- What it changes, and why (measured in docs/PERF-BATCH.md):
--   * NO plan invalidation.  The baseline tick TRUNCATEs queue tables, ANALYZEs a temp table, and uses ON COMMIT DELETE ROWS temp tables; each of those invalidates
--     the cached plans of every statement that touches the table, so ~110 statements were re-planned every tick (~12 ms of 75).  The batched tick uses only DELETE
--     on persistent tables and never runs DDL, ANALYZE or TRUNCATE, and it uses data-modifying CTEs instead of stage tables.
--   * Fewer hops.  An inbound frame was copied inbox -> batch -> play_inbox -> play_in -> play_in_work before being decoded; here inbox -> play_in_work.
--     An outbound frame went play_out -> _drain -> outbox -> drain_outbox; here play_out -> outbox as one row per connection.
--   * Set-based chunk lookup instead of one volatile function call (5 statements) per chunk.
--   * Skip phases that have nothing to do (block events, chat, creative slots, visibility) instead of running them to find that out.
--
-- Components can be switched on and off for ablation: `alter database X set mc.batch_flags = 'in,mv'` (or `set mc.batch_flags = ...` in a session).  Unset or 'all' = in, mv, vis,
-- ch, skip; 'none' = the baseline's phases (still orchestrated by this function).  Opt-in, not part of `all`: out (one outbox row per connection: measured net-negative), ref, grid.

create or replace function mc.batch_flags() returns text language sql stable as $$
    select ',' || coalesce(nullif(current_setting('mc.batch_flags', true), ''), 'all') || ',' $$;

------------------------------------------------------------------------------------------------ out: one statement from play_out to one outbox row per connection
-- Same bytes as the baseline's step 8: rows of connections that are not in play state are dropped; a connection with compression enabled gets its frames re-framed
-- (net.reframe, which raises for frames at or above the threshold: SQL has no deflate) and is closed on error.  Returns the number of play_out rows moved.
create or replace function mc.drain_batched(cur bigint) returns int language plpgsql as $$
declare r record; n int := 0;
begin
    for r in
        with o as (delete from mc.play_out returning seq, conn_id, data),
             j as (select o.seq, o.conn_id, o.data, c.compression as comp from o join net.conn c on c.conn_id = o.conn_id and c.state = 'play'),
             ins as (insert into net.outbox (conn_id, data) select conn_id, string_agg(data, ''::bytea order by seq) from j where comp < 0 group by conn_id returning 1)
        select null::int as conn_id, null::int as comp, null::bytea as data, (select count(*)::int from j) as n
        union all
        select conn_id, comp, string_agg(data, ''::bytea order by seq), 0 from j where comp >= 0 group by conn_id, comp
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

------------------------------------------------------------------------------------------------ ch: chunk streaming without per-chunk function calls
-- PLANNER NOTE: the statement's CTEs have no statistics, so the planner assumes hundreds of rows where there are a few dozen and picks hash joins that scan the
-- whole of mc.chunk and mc.chunk_cache (68 ms instead of ~3 ms, measured).  Correlated scalar subselects are planned as per-row primary-key lookups whatever the
-- estimates say, which is what is wanted here.  The same trick is used wherever a small CTE is matched against a big table.
-- Same packets in the same per-connection order as net.stream_chunks (centre, forgets, batch start, chunks nearest first, batch finished) from ONE insert; the chunk
-- packets come from a join with the packet cache when the cached copy is current, and only a chunk whose cache is stale or missing is built through mc.chunk_packet.
-- A chunk that is not cached (or whose cache is stale): generate it if it does not exist yet, then build and cache its packet.  Called per chunk only on that slow
-- path; a chunk that exists with a current cache never reaches it.
create or replace function mc.chunk_packet_generate(p_dim text, p_cx int, p_cz int) returns bytea language plpgsql volatile as $$
begin
    perform mc.generate_flat(p_dim, p_cx, p_cz);
    return mc.chunk_packet(p_dim, p_cx, p_cz);
end $$;

create or replace function net.stream_chunks_batched() returns int language plpgsql as $$
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
    insert into mc.play_out (conn_id, data)
    select conn_id, data from (
        select conn_id, 1 as ph, 0 as k1, 0 as k2, 0 as k3, proto.frame(i_ctr, proto.varint(ncx) || proto.varint(ncz)) as data from st
        union all
        select s.conn_id, 2, s.ocx + dx, s.ocz + dz, 0, proto.frame(i_fg, proto.i32(s.ocz + dz) || proto.i32(s.ocx + dx))
          from st s, generate_series(-r, r) dx, generate_series(-r, r) dz
         where abs(s.ocx + dx - s.ncx) > r or abs(s.ocz + dz - s.ncz) > r
        union all
        select distinct conn_id, 3, 0, 0, 0, proto.frame(i_bs, '\x') from stn
        union all
        select q.conn_id, 4, q.d, q.x, q.z,
               coalesce((select k.packet from mc.chunk ch join mc.chunk_cache k on k.dimension = ch.dimension and k.cx = ch.cx and k.cz = ch.cz and k.version = ch.version
                          where ch.dimension = dim and ch.cx = q.x and ch.cz = q.z and ch.hm_world_surface is not null and not ch.dirty and not ch.hm_dirty),
                        mc.chunk_packet_generate(dim, q.x, q.z))
          from stn q
        union all
        select conn_id, 5, 0, 0, 0, proto.frame(i_bf, proto.varint(count(*)::int)) from stn group by conn_id
    ) u order by conn_id, ph, k1, k2, k3;
    return 1;
end $$;
