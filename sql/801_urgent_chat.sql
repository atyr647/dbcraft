-- Idle cost, part 2: what a gateway needs to skip the tick's statements when nothing happens, and the urgent chat lane.  See docs/PERF-IDLE.md.
--
--   net.gateway_pending(p_after)   bit 1: the outbox holds bytes or a connection is closing (net.drain_outbox() has something to hand over); bit 2: net.gateway_ctl(p_after) has rows;
--                                  bit 4: mc.chunk_request has a row (a chunk generator has work: sql/970, gateway/src/generators.rs).
--                                  One probe instead of drain_outbox + gateway_ctl: a gateway that sent no input to the database in a tick can call the tick alone and this, and
--                                  only drain when it says so.  PL/pgSQL (cached plan): about 20 microseconds.
--   mc.drain_play_out(cur)         the drain step of mc.server_tick (mc.play_out -> net.outbox, in generation order; connections with compression re-framed), as a function so
--                                  that the urgent lane uses the same statement.  mc.server_tick keeps its own copy (sql/430): both are compared byte for byte in tests/sql/801.
--   net.urgent_chat(conns, payloads)  the urgent chat lane: serverbound `chat` frames handled between ticks.  Exactly what the tick does with a chat packet (the frame goes to
--                                  mc.play_in_work, mc.apply_chat runs, the output is drained), minus everything else the tick does.  Returns the ordinals (1-based) of the
--                                  frames it did NOT take (connection unknown, not in play, closing, no player, or not a chat packet, or an earlier frame of the same connection
--                                  was not taken: a connection's frames are never reordered); the caller puts those back into its normal path.
--
-- Why it is safe (docs/PERF-IDLE.md has the full argument): the bytes are the ones the tick would produce (same function); what changes is WHEN they leave (up to one tick
-- earlier) and their position among the other frames of a recipient's stream.  The gateway only sends a chat frame here when no frame ahead of it in arrival order (any
-- connection) is a command, and no frame ahead of it from the same connection is anything but chat, client_tick_end or a movement packet, so chat and commands are still handled in
-- arrival order and a connection's own order is kept.

create or replace function net.gateway_pending(p_after bigint default 0) returns int language plpgsql volatile as $$
begin
    -- sql/800: the quiet tick of THIS transaction found nobody connected, the outbox and the chunk request queue empty (so no closing connection and no control row either, net.conn_ctl follows net.conn)
    if current_setting('dbcraft.quiet_xid', true) = pg_current_xact_id_if_assigned()::text then
        perform set_config('dbcraft.quiet_xid', '', false);          -- used up: a second call in this transaction probes (something may have been written since the tick)
        return 0;
    end if;
    return (case when exists (select 1 from net.outbox) or exists (select 1 from net.conn where closing) then 1 else 0 end)
         + (case when exists (select 1 from net.conn_ctl k where k.ctl_seq > p_after) then 2 else 0 end)
         + (case when exists (select 1 from mc.chunk_request) then 4 else 0 end);
end $$;

create or replace function mc.drain_play_out() returns int language plpgsql volatile as $$
declare n_out int; framed_rows mc.drain_row[]; r record; cur bigint;
begin
    with o as (delete from mc.play_out returning seq, conn_id, data),
         j as (select o.seq, o.conn_id, o.data, c.compression as comp from o join net.conn c on c.conn_id = o.conn_id and c.state = 'play'),
         plain as (insert into net.outbox (conn_id, data)
                   select conn_id, data from j where comp < 0 order by seq returning 1)
    select count(*)::int, coalesce(array_agg(row(j.conn_id, j.comp, j.data)::mc.drain_row order by j.seq) filter (where j.comp >= 0), '{}')
      into n_out, framed_rows from j;
    for r in select d.conn_id, d.comp, string_agg(d.data, ''::bytea order by d.ord) as data
               from unnest(framed_rows) with ordinality as d(conn_id, comp, data, ord) group by d.conn_id, d.comp loop
        begin
            insert into net.outbox (conn_id, data) values (r.conn_id, net.reframe(r.comp, r.data));
        exception when others then
            select game_time into cur from mc.game_state;
            insert into mc.error_log (tick, step, message) values (cur, 'reframe', sqlerrm);
            perform net.close(r.conn_id);
        end;
    end loop;
    return n_out;
end $$;

create or replace function net.urgent_chat(p_conns bigint[], p_payloads bytea[]) returns int[] language plpgsql volatile as $$
declare i_chat int := mc.sid('chat'); unhandled int[]; cur bigint;
begin
    -- which frames are taken: a chat packet of a live play connection that has a player, and no earlier frame of that connection was left out
    select coalesce(array_agg(f.ord order by f.ord) filter (where not f.taken), '{}') into unhandled
      from (select u.ord, bool_and(u.ok) over (partition by u.conn order by u.ord) as taken
              from (select u.ord, u.conn,
                           coalesce(c.state = 'play' and not c.closing and net.pid(u.payload) = i_chat and exists (select 1 from mc.player p where p.conn_id = c.conn_id), false) as ok
                      from unnest(p_conns, p_payloads) with ordinality as u(conn, payload, ord) left join net.conn c on c.conn_id = u.conn) u) f;
    insert into mc.play_in_work (conn_id, packet_id, body)
    select u.conn::int, i_chat, substring(u.payload from net.pid_len(u.payload) + 1)
      from unnest(p_conns, p_payloads) with ordinality as u(conn, payload, ord)
     where u.ord <> all (unhandled)
     order by u.ord;
    if exists (select 1 from mc.play_in_work where packet_id = i_chat) then
        select game_time into cur from mc.game_state;
        perform mc.apply_chat(cur);
        perform mc.drain_play_out();
    end if;
    return unhandled;
end $$;
