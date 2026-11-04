-- Keep-alive in the configuration state (docs/PERF-CAPACITY.md, "The dropped clients").
--
-- WHAT WAS WRONG.  A joiner that has finished its configuration (it sent finish_configuration) waits for the server's `login` packet.  Under the join entry budget
-- (sql/430 net.process_fast, sql/920: dbcraft.join-entry-budget-ms) that entry is held back while the tick is busy, and in a 500-player run the wait was longer than 30 s:
-- the client sends nothing in that state (its last bytes were the finish_configuration packet) and the server sent nothing, so the Rust gateway's read timeout (30 s with no
-- byte, vanilla's ReadTimeoutHandler) closed 70 - 240 of 500 connections ("read timeout (no bytes)": about 20 s in the login queue, then 30 s of silence, the 50 s mark).  A real
-- vanilla client would have given up on its own at the same time (its own read timeout counts the bytes it receives).  The server did not break a rule; it broke the silence
-- vanilla never has: vanilla's configuration listener sends a keep-alive 15 s after it started (ServerCommonPacketListenerImpl.keepConnectionAlive, shared by the
-- configuration and the play listeners) and every 15 s after the client answered, and the client answers it in the configuration state.
--
-- WHAT THIS DOES.  The same: a connection in the configuration state that has been silent for 15 s (nothing sent since it connected, or since its last keep-alive) is sent a
-- keep_alive (configuration, clientbound) whose id is the wall clock in ms, like vanilla's; the answer (net.h_config) clears it; a client that has not answered within 30 s is
-- disconnected with disconnect.timeout (vanilla's rule).  A join that takes less than 15 s in the configuration state sends and receives exactly what it did before: no
-- test or recorded join sees a difference.  The state is the columns net.conn.keepalive_id / keepalive_sent that the first sketch of the play-state keep-alive left unused (the game's own
-- keep-alive for players is mc.keepalive_due, mc.player.keepalive_id).
--
-- COST.  Once a second (a tick whose clock is 5 mod 20) one scan of net.conn (one row per connection, no index needed: about 20 us for 500 connections).
create or replace function net.config_keepalive() returns int language plpgsql volatile as $$
declare kid int; dis int; r record; n int := 0;
begin
    if (select game_time from mc.game_state) % 20 <> 5 then return 0; end if;
    if not exists (select 1 from net.conn c where c.state = 'configuration' and not c.closing and c.connected_at < now() - interval '15 seconds') then return 0; end if;
    kid := net.pkt('configuration', 'clientbound', 'minecraft:keep_alive');
    dis := net.pkt('configuration', 'clientbound', 'minecraft:disconnect');
    for r in select conn_id from net.conn where state = 'configuration' and not closing and keepalive_id is not null and keepalive_sent < now() - interval '30 seconds' loop
        perform net.send(r.conn_id, dis, nbt.text_translate('disconnect.timeout'));
        perform net.close(r.conn_id);
    end loop;
    with due as (
        update net.conn c set keepalive_id = (extract(epoch from clock_timestamp()) * 1000)::bigint, keepalive_sent = now()
         where c.state = 'configuration' and not c.closing and c.keepalive_id is null and coalesce(c.keepalive_sent, c.connected_at) < now() - interval '15 seconds'
        returning c.conn_id, c.keepalive_id, c.compression)
    insert into net.outbox (conn_id, data)
    select d.conn_id, net.frame(d.compression, kid, proto.i64(d.keepalive_id)) from due d;
    get diagnostics n = row_count;
    return n;
end $$;
