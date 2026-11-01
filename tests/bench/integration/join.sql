-- Join cost through the real login path (handshake ... finish_configuration, the entry burst, the chunk batch) and the storage a flat area takes.
-- Run by tests/bench/integration/join.sh on the e2e database (needs the datapack loaded by tests/e2e/setup.sh).  Everything runs inside the database:
-- one mc.server_tick() per measurement, timed with clock_timestamp().
create schema if not exists ibench;

create or replace function ibench.reset_world(p_clear_chunks boolean) returns void language plpgsql as $$
begin
    truncate net.conn, net.inbox, net.outbox, net.play_inbox, net.batch, mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor,
             mc.block_event, mc.tick_log, mc.server_tick_log, mc.error_log;
    delete from mc.player;
    if p_clear_chunks then delete from mc.chunk; truncate mc.chunk_cache; end if;
    update mc.game_state set game_time = 100, day_time = 100;
end $$;

-- one player logs in; returns the tick time, the bytes sent to that player, and the tick's phases
create or replace function ibench.join(p_conn bigint, p_name text) returns table (ms_tick float8, ms_chunks_and_join float8, mb_sent numeric, frames int) language plpgsql as $$
declare t0 timestamptz; b bigint; n int;
begin
    perform net.on_connect(p_conn);
    insert into net.inbox (conn_id, payload) values
        (p_conn, proto.varint(net.pkt('handshake', 'serverbound', 'minecraft:intention')) || proto.varint(777) || proto.string('localhost') || proto.i16(25565) || proto.varint(2)),
        (p_conn, proto.varint(net.pkt('login', 'serverbound', 'minecraft:hello')) || proto.string(p_name) || proto.uuid(net.offline_uuid(p_name))),
        (p_conn, proto.varint(net.pkt('login', 'serverbound', 'minecraft:login_acknowledged'))),
        (p_conn, proto.varint(net.pkt('configuration', 'serverbound', 'minecraft:select_known_packs')) || proto.varint(0)),
        (p_conn, proto.varint(net.pkt('configuration', 'serverbound', 'minecraft:finish_configuration')));
    t0 := clock_timestamp();
    perform mc.server_tick();
    ms_tick := extract(epoch from clock_timestamp() - t0) * 1000;
    select ms_process into ms_chunks_and_join from mc.server_tick_log order by tick desc limit 1;
    select coalesce(sum(length(data)), 0), count(*) into b, n from net.outbox where conn_id = p_conn;
    mb_sent := round(b / 1048576.0, 2); frames := n;
    delete from net.outbox where conn_id = p_conn;
    return next;
end $$;
