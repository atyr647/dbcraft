-- Login storm harness.  Everything runs inside the database; each jbench.run_tick() call is one statement = one transaction, like one gateway tick:
-- connections + their five login packets are inserted into net.inbox, mc.server_tick() runs, then net.drain_outbox() is read like the gateway would.
create schema if not exists jbench;

create or replace function jbench.reset(p_max_players int default 5000) returns void language plpgsql as $$
begin
    truncate net.conn, net.inbox, net.outbox, net.play_inbox, net.batch, mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack,
             mc.block_actor, mc.block_event, mc.tick_log, mc.server_tick_log, mc.error_log;
    delete from mc.player; delete from mc.chat_log;
    update mc.game_state set game_time = 100, day_time = 100;
    perform setval('mc.entity_id_seq', 1, false); perform setval('net.entity_id_seq', 1, false);     -- entity ids are the same in every run
    update mc.server_property set value = '-1' where key = 'network-compression-threshold';      -- every run starts uncompressed; ab.py --setting turns it on for a run
    update mc.server_property set value = p_max_players::text where key = 'max-players';
    update mc.server_property set value = 'false' where key = 'white-list';
end $$;

create or replace function jbench.name(p_i int, p_prefix text) returns text language sql immutable as $$ select p_prefix || lpad(p_i::text, 6, '0') $$;

-- the five packets of one login (the same as tests/bench/integration/join.sql)
create or replace function jbench.feed(p_from int, p_n int, p_prefix text) returns void language plpgsql as $$
begin
    perform net.on_connect(g) from generate_series(p_from, p_from + p_n - 1) g;
    insert into net.inbox (conn_id, payload)
    select g, x.payload
    from generate_series(p_from, p_from + p_n - 1) g,
         lateral (values
            (1, proto.varint(net.pkt('handshake', 'serverbound', 'minecraft:intention')) || proto.varint(777) || proto.string('localhost') || proto.i16(25565) || proto.varint(2)),
            (2, proto.varint(net.pkt('login', 'serverbound', 'minecraft:hello')) || proto.string(jbench.name(g, p_prefix)) || proto.uuid(net.offline_uuid(jbench.name(g, p_prefix)))),
            (3, proto.varint(net.pkt('login', 'serverbound', 'minecraft:login_acknowledged'))),
            (4, proto.varint(net.pkt('configuration', 'serverbound', 'minecraft:select_known_packs')) || proto.varint(0)),
            (5, proto.varint(net.pkt('configuration', 'serverbound', 'minecraft:finish_configuration')))) x(step, payload)
    order by g, x.step;
end $$;

-- one tick: p_n new connections (conn ids p_from ...) log in; returns the timings of that tick
create or replace function jbench.run_tick(p_from int, p_n int, p_prefix text default 'J')
returns table (ms_tick float8, ms_process float8, ms_game float8, ms_chunks float8, ms_drain float8, ms_gw_drain float8, frames bigint, mb numeric, wal_kb numeric)
language plpgsql as $$
declare t0 timestamptz; t1 timestamptz; l0 pg_lsn; b bigint; n bigint;
begin
    if p_n > 0 then perform jbench.feed(p_from, p_n, p_prefix); end if;
    l0 := pg_current_wal_lsn();
    t0 := clock_timestamp();
    perform mc.server_tick();
    t1 := clock_timestamp();
    ms_tick := extract(epoch from t1 - t0) * 1000;
    select l.ms_process, l.ms_game, l.ms_chunks, l.ms_drain into ms_process, ms_game, ms_chunks, ms_drain from mc.server_tick_log l order by tick desc limit 1;
    t0 := clock_timestamp();
    select count(*), coalesce(sum(length(d.data)), 0) into n, b from net.drain_outbox() d;
    ms_gw_drain := extract(epoch from clock_timestamp() - t0) * 1000;
    frames := n; mb := round(b / 1048576.0, 2);
    wal_kb := round(pg_wal_lsn_diff(pg_current_wal_lsn(), l0) / 1024.0, 0);
    return next;
end $$;
