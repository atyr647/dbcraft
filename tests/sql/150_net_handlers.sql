-- The connection layer's behaviour after entry: client packets, keep-alive, forwarding to the game, several players, the gateway contract,
-- hooks, and bad clients.  Self-contained (no captures needed except where noted).
\ir _net_helpers.sql

-- the one registry entry the join packet needs (the full datapack is loaded in 130)
insert into ref.dp_registry values ('minecraft:dimension_type', 0);
insert into ref.dp_entry (registry, seq, name) values ('minecraft:dimension_type', 0, 'minecraft:overworld');

select t.player(1, 'Alice');
select t.player(2, 'Bob');

------------------------------------------------------------------------------------------------ protocol-level play packets
select t.feed_pkt(1, 'play', 'minecraft:accept_teleportation', proto.varint(1) || proto.f64(0.5) || proto.f64(64) || proto.f64(0.5) || proto.f32(0) || proto.f32(0));
select net.process();
select t.is_true('teleport confirmed with the right id', (select teleport_ok from net.conn where conn_id = 1));
select t.feed_pkt(2, 'play', 'minecraft:accept_teleportation', proto.varint(7) || proto.f64(0) || proto.f64(0) || proto.f64(0) || proto.f32(0) || proto.f32(0));
select net.process();
select t.is_true('wrong teleport id is not a confirmation', not (select teleport_ok from net.conn where conn_id = 2));

select t.feed_pkt(1, 'play', 'minecraft:chunk_batch_received', proto.f32(12.5));
select net.process();
select t.eq('chunks per tick stored', (select chunks_per_tick from net.conn where conn_id = 1), 12.5::real);
select t.feed_pkt(1, 'play', 'minecraft:chunk_batch_received', proto.f32(1e30));
select net.process();
select t.eq('chunks per tick is capped', (select chunks_per_tick from net.conn where conn_id = 1), 64::real);
select t.feed_pkt(1, 'play', 'minecraft:chunk_batch_received', proto.f32('NaN'));
select net.process();
select t.eq('NaN chunks per tick falls back to the minimum', (select chunks_per_tick from net.conn where conn_id = 1), 0.01::real);

select t.feed_pkt(1, 'play', 'minecraft:player_loaded');
select net.process();
select t.is_true('player_loaded recorded', (select loaded from net.conn where conn_id = 1));

-- client_information: language, view distance 12, chat visibility 0, colors on, skin parts 0x7f, right hand, no filtering, listing on, particles 0
select t.feed_pkt(1, 'play', 'minecraft:client_information', proto.string('en_us') || proto.i8(12) || proto.varint(0) || proto.bool(true) || proto.i8(127) || proto.varint(1) || proto.bool(false) || proto.bool(true) || proto.varint(0));
select net.process();
select t.eq('client information parsed', (select client_info ->> 'language' from net.conn where conn_id = 1), 'en_us');
select t.eq('view distance parsed', (select (client_info ->> 'view_distance')::int from net.conn where conn_id = 1), 12);
select t.eq('skin parts parsed', (select (client_info ->> 'skin_parts')::int from net.conn where conn_id = 1), 127);
select t.feed_pkt(1, 'play', 'minecraft:custom_payload', proto.string('minecraft:brand') || proto.string('fabric'));
select net.process();
select t.eq('client brand stored', (select brand from net.conn where conn_id = 1), 'fabric');

------------------------------------------------------------------------------------------------ forwarding to the game
-- a movement-like packet (any id the layer does not handle): moved set-based into play_inbox with the id and body split
select t.feed_pkt(1, 'play', 'minecraft:move_player_pos', proto.f64(1.5) || proto.f64(64) || proto.f64(2.5) || proto.i8(1));
select t.feed_pkt(2, 'play', 'minecraft:chat', '\x0568656c6c6f');
select t.feed_pkt(1, 'play', 'minecraft:keep_alive', proto.i64(42));     -- handled here, not forwarded
select net.process();
select t.eq('two packets forwarded', (select count(*) from net.play_inbox)::int, 2);
select t.eq('forwarded packet id', (select packet_id from net.play_inbox where conn_id = 1), net.pkt('play', 'serverbound', 'minecraft:move_player_pos'));
select t.eq('forwarded body is the packet body only', (select encode(body, 'hex') from net.play_inbox where conn_id = 2), '0568656c6c6f');
select t.eq('inbox is drained', (select count(*) from net.inbox)::int, 0);
delete from net.play_inbox;

------------------------------------------------------------------------------------------------ keep-alive
update net.conn set keepalive_sent = null, keepalive_id = null;
select t.eq('keep-alive sent to both players', net.keepalive_tick(), 2);
select t.eq('keep_alive is the only packet queued', t.names('play', t.take(1)), array['minecraft:keep_alive']);
select t.is_true('id remembered', (select keepalive_id is not null from net.conn where conn_id = 1));
select t.eq('no second keep-alive while one is pending', net.keepalive_tick(), 0);
select t.feed_pkt(1, 'play', 'minecraft:keep_alive', proto.i64((select keepalive_id from net.conn where conn_id = 1)));
select net.process();
select t.is_true('answered keep-alive clears the pending id', (select keepalive_id is null from net.conn where conn_id = 1));
select t.is_true('wrong keep-alive id does not clear it', (select keepalive_id is not null from net.conn where conn_id = 2));
update net.conn set keepalive_sent = now() - interval '31 seconds' where conn_id = 2;
select net.keepalive_tick();
select t.is_true('unanswered for 30 s: kicked', (select closing from net.conn where conn_id = 2));
select t.eq('kick uses the timeout message', encode(t.take(2), 'escape') like '%disconnect.timeout%', true);

------------------------------------------------------------------------------------------------ several players
select t.player(3, 'Carol');
select t.player(4, 'Dave');
select t.take(1); select t.take(3); select t.take(4);
-- a fresh connection that becomes Eve: the real entry path, with only the join record faked
select net.on_connect(5);
update net.conn set state = 'configuration', name = 'Eve', uuid = net.offline_uuid('Eve'), known_packs = '{}' where conn_id = 5;
select t.feed_pkt(5, 'configuration', 'minecraft:finish_configuration');
select net.process();
select t.is_true('Eve is in play', (select state = 'play' and entity_id is not null from net.conn where conn_id = 5));
select t.is_true('Eve got the entry packets, starting with login', (t.names('play', t.take(5)))[1] = 'minecraft:login');
select t.eq('players already in the game each got exactly one player_info_update', t.names('play', t.take(3)), array['minecraft:player_info_update']);
select t.eq('...including Dave', t.names('play', t.take(4)), array['minecraft:player_info_update']);

------------------------------------------------------------------------------------------------ the gateway contract
select net.send(3, net.pkt('play', 'clientbound', 'minecraft:game_event'), '\x0d00000000');
select net.send(3, net.pkt('play', 'clientbound', 'minecraft:game_event'), '\x0d00000000');
select net.close(4);
select t.eq('drain returns one row per connection with output or closing', (select count(*) from net.drain_outbox() d where d.conn_id in (3, 4))::int, 0) where false;
create temp table drained as select * from net.drain_outbox();
select t.eq('Carol: two packets concatenated in order', (select encode(data, 'hex') from drained where conn_id = 3), repeat('0627' || '0d00000000', 2));
select t.is_true('Carol is not closing', not (select close from drained where conn_id = 3));
select t.is_true('Dave is closing with no data', (select close and length(data) = 0 from drained where conn_id = 4));
select t.is_true('closed connections are removed after the drain', not exists (select 1 from net.conn where conn_id = 4) and exists (select 1 from net.conn where conn_id = 3));
select t.eq('outbox is empty after a drain', (select count(*) from net.outbox)::int, 0);

------------------------------------------------------------------------------------------------ hooks
create or replace function net.hook_chunks(p_conn bigint, p_cx int, p_cz int, p_radius int) returns setof bytea language sql stable as $$
    select decode(lpad(to_hex(g), 2, '0') || 'aa', 'hex') from generate_series(1, 3) g $$;
select net.send_chunks(3, 0, 0, 2);
select t.eq('chunk batch: start, 3 chunks, finished', t.names('play', t.take(3)),
            array['minecraft:chunk_batch_start', 'minecraft:level_chunk_with_light', 'minecraft:level_chunk_with_light', 'minecraft:level_chunk_with_light', 'minecraft:chunk_batch_finished']);
create or replace function net.hook_chunks(p_conn bigint, p_cx int, p_cz int, p_radius int) returns setof bytea language sql stable as $$
    select null::bytea where false $$;
select t.eq('no chunks: no batch packets at all', net.send_chunks(3, 0, 0, 2), 0);
select t.eq('...nothing queued', length(t.take(3)), 0);

------------------------------------------------------------------------------------------------ bad clients
select t.player(6, 'Mallory');
select t.player(7, 'Trent');
select t.take(6); select t.take(7);
insert into net.inbox (conn_id, payload) values (6, '\x');                       -- empty payload
insert into net.inbox (conn_id, payload) values (6, '\x808080808080');           -- overlong packet id
select t.feed_pkt(7, 'play', 'minecraft:move_player_pos', '\x00');
select net.process();
select t.is_true('Mallory is dropped', (select closing from net.conn where conn_id = 6));
select t.is_true('Mallory was told why', t.names('play', t.take(6)) = array['minecraft:disconnect']);
select t.is_true('Trent is unaffected and his packet was forwarded', not (select closing from net.conn where conn_id = 7) and (select count(*) from net.play_inbox where conn_id = 7) = 1);
insert into net.inbox (conn_id, payload) values (999, '\x00');                   -- a connection that does not exist
select net.process();
select t.is_true('packets for unknown connections are ignored', true);
select t.eq('unknown play packet id (2-byte, not in the table) disconnects only that player',
            (select count(*) from net.conn where closing and conn_id = 7)::int, 0);
insert into net.inbox (conn_id, payload) values (7, '\xff7f');                   -- id 16383: no such packet
select net.process();
select t.is_true('...a packet id the protocol does not have closes the sender', (select closing from net.conn where conn_id = 7));

-- the disconnect text format vs a real one: vanilla's reaction to a truncated accept_teleportation (capture made with --bad-teleport)
create table t.cap (idx int, dir text, state text, pid int, name text, len int, hex text);
\copy t.cap from program 'python3 tools/capture_to_tsv.py play_disconnect'
select count(*) > 0 as have from t.cap where name = 'minecraft:disconnect' and state = 'play' \gset
\if :have
    select t.eq('play disconnect text equals what vanilla sent',
                encode(proto.frame(net.pkt('play', 'clientbound', 'minecraft:disconnect'),
                       nbt.text_translate('disconnect.genericReason', array['Internal Exception: io.netty.handler.codec.DecoderException: Failed to decode packet ''serverbound/minecraft:accept_teleportation'''])), 'hex'),
                (select hex from t.cap where name = 'minecraft:disconnect' and state = 'play' order by idx limit 1));
\else
    select t.skip('no play-disconnect capture (tools/capture_vanilla.py --bad-teleport --out tests/fixtures/captured/play_disconnect.jsonl)');
\endif
