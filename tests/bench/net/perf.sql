-- Connection-layer timings: steady-state forwarding, keep-alive, drain, and joins.
-- usage (fresh migrated database with ref data and a vanilla capture): psql -f tests/bench/net/perf.sql   (run from the repository root)
\timing off
\ir ../../sql/_net_helpers.sql
\! python3 tools/load_datapack.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)" >/dev/null
\! python3 tools/load_static_packets.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)" >/dev/null
\echo == 1. steady state: 1000 players in play, 5 movement packets each (5000 frames) through net.process()
insert into net.conn (conn_id, state, name, uuid, gamemode, entity_id) select g, 'play', 'P'||g, net.offline_uuid('P'||g), 1, g from generate_series(1, 1000) g;
insert into net.inbox (conn_id, payload)
select c, proto.varint(net.pkt('play', 'serverbound', 'minecraft:move_player_pos')) || proto.f64(1.5) || proto.f64(64) || proto.f64(2.5) || proto.i8(1)
from generate_series(1, 1000) c, generate_series(1, 5);
do $$ declare t0 timestamptz; n int; begin t0 := clock_timestamp(); n := net.process(); raise notice 'process(): % frames in % ms', n, round(extract(epoch from clock_timestamp() - t0) * 1000, 1); end $$;
select count(*) as forwarded from net.play_inbox;
\echo == 2. the same with keep-alive every player + a drain
do $$ declare t0 timestamptz; n int; begin t0 := clock_timestamp(); n := net.keepalive_tick(); raise notice 'keepalive_tick(): % sent in % ms', n, round(extract(epoch from clock_timestamp() - t0) * 1000, 1); end $$;
do $$ declare t0 timestamptz; n int; begin t0 := clock_timestamp(); select count(*) into n from net.drain_outbox(); raise notice 'drain_outbox(): % connections in % ms', n, round(extract(epoch from clock_timestamp() - t0) * 1000, 1); end $$;
\echo == 3. joins: 20 players log in at once (handshake, hello, ack, known packs, finish): first one builds the config cache
delete from net.conn; delete from net.play_inbox; truncate net.outbox;
do $$
declare t0 timestamptz; g int; hs bytea; bytes bigint;
begin
  hs := proto.varint(0) || proto.varint(777) || proto.string('localhost') || proto.i16(25565) || proto.varint(2);
  for g in 1..20 loop
    perform net.on_connect(g);
    insert into net.inbox (conn_id, payload) values (g, hs), (g, proto.varint(0) || proto.string('Player'||g) || decode(repeat('00', 16), 'hex')), (g, proto.varint(3));
  end loop;
  t0 := clock_timestamp(); perform net.process(); raise notice 'login+ack for 20 players: % ms', round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
  for g in 1..20 loop
    insert into net.inbox (conn_id, payload) values (g, proto.varint(net.pkt('configuration','serverbound','minecraft:select_known_packs')) || proto.varint(0)), (g, proto.varint(net.pkt('configuration','serverbound','minecraft:finish_configuration')));
  end loop;
  t0 := clock_timestamp(); perform net.process(); raise notice 'known packs + finish for 20 players (first builds the cache): % ms', round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
  select sum(length(data)) into bytes from net.outbox; raise notice 'queued % KB for 20 joins (full registry data, no compression)', bytes / 1024;
  truncate net.outbox;
  for g in 21..40 loop
    perform net.on_connect(g);
    insert into net.inbox (conn_id, payload) values (g, hs), (g, proto.varint(0) || proto.string('Player'||g) || decode(repeat('00', 16), 'hex')), (g, proto.varint(3)),
        (g, proto.varint(net.pkt('configuration','serverbound','minecraft:select_known_packs')) || proto.varint(0)), (g, proto.varint(net.pkt('configuration','serverbound','minecraft:finish_configuration')));
  end loop;
  t0 := clock_timestamp(); perform net.process(); raise notice '20 more complete joins with a warm cache: % ms', round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
end $$;
