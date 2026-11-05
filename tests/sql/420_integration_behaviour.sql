-- this test pins the classic (simplified) player broadcast of sql/430-468; the vanilla tracker of sql/900-910 has its own test (900_vis.sql)
update mc.server_property set value = 'false' where key = 'dbcraft.vanilla-tracker';
-- The integrated server's behaviour, driven through net.inbox and mc.server_tick() exactly as a gateway would: settings, login checks, two players
-- joining (ordering, no duplicates, entity ids), keep-alive and teleport forwarding, block actions, chunk streaming, kicks, compression.
-- Needs the captures only for the datapack (skipped by the loaders' own notices if missing).
\ir _net_helpers.sql
\ir ../../sql/400_integration.sql
-- sql/400 reinstalls the original hooks; put the login-path versions back on top of it (what a fresh migration ends with)
\ir ../../sql/460_join_codec.sql
\ir ../../sql/461_join_on_join.sql
\ir ../../sql/462_join_config_burst.sql
\! python3 tools/load_datapack.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
\! python3 tools/load_static_packets.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
\! python3 tools/load_world_ref.py

------------------------------------------------------------------------------------------------ helpers
create or replace function t.join_client(p_conn bigint, p_name text) returns void language plpgsql as $$
begin
    perform net.on_connect(p_conn);
    perform t.feed_pkt(p_conn, 'handshake', 'minecraft:intention', proto.varint(777) || proto.string('localhost') || proto.i16(25565) || proto.varint(2));
    perform t.feed_pkt(p_conn, 'login', 'minecraft:hello', proto.string(p_name) || proto.uuid(net.offline_uuid(p_name)));
    perform t.feed_pkt(p_conn, 'login', 'minecraft:login_acknowledged');
    perform t.feed_pkt(p_conn, 'configuration', 'minecraft:select_known_packs', proto.varint(0));
    perform t.feed_pkt(p_conn, 'configuration', 'minecraft:finish_configuration');
end $$;
-- the play-state frames a connection was sent: (position, packet name, body).  On a join tick pass p_join = true: the frames before and including
-- finish_configuration (frame 01 03) are login and configuration packets, whose ids mean something else in the play state, so they are dropped.
create or replace function t.play(p_conn bigint, p_join boolean default false) returns table (idx int, name text, body bytea) language plpgsql as $$
begin
    return query
    with f as (select * from t.frames(t.take(p_conn))),
         cut as (select coalesce(case when p_join then (select min(f.idx) from f where f.frame = '\x0103'::bytea) end, -1) as c)
    select f.idx, net.pkt_name('play', 'clientbound', (proto.varint_read(f.frame, (proto.varint_read(f.frame, 0)).nxt)).val),
           substring(f.frame from (proto.varint_read(f.frame, (proto.varint_read(f.frame, 0)).nxt)).nxt + 1)
    from f, cut where f.idx > cut.c order by f.idx;
end $$;
-- keep a tick's frames for one connection in table t.g_<label>
create or replace function t.grab(p_conn bigint, p_label text, p_join boolean default false) returns void language plpgsql as $$
begin
    execute format('drop table if exists t.g_%s', p_label);
    execute format('create table t.g_%s as select * from t.play(%s, %L)', p_label, p_conn, p_join);
end $$;
create or replace function t.fresh() returns void language plpgsql as $$
begin
    truncate net.conn, net.inbox, net.outbox, net.play_inbox, net.batch;
    truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor, mc.block_event, mc.error_log, mc.tick_log, mc.server_tick_log;   -- the clock is reset below
    delete from mc.player; delete from mc.op; delete from mc.whitelist; delete from mc.ban;
    perform mc.configure_dev_server('test', 'creative');
    update mc.server_property set value = '2' where key in ('view-distance', 'simulation-distance');
    update mc.server_property set value = '10' where key = 'max-players';
    update mc.server_property set value = 'false' where key = 'white-list';
    update mc.game_state set game_time = 100, day_time = 100;
    perform mc.reset_dev_world(4);
end $$;
create or replace function t.names_of(p_label text) returns text[] language plpgsql as $$
declare r text[];
begin execute format('select coalesce(array_agg(replace(name, ''minecraft:'', '''') order by idx), ''{}'') from t.g_%s', p_label) into r; return r; end $$;
create or replace function t.cnt(p_label text, p_name text) returns int language plpgsql as $$
declare r int;
begin execute format('select count(*)::int from t.g_%s where name = %L', p_label, p_name) into r; return r; end $$;
create or replace function t.pos_of(p_label text, p_name text, p_nth int default 1) returns text language plpgsql as $$
declare r text;
begin execute format('select encode(body, ''hex'') from (select body, row_number() over (order by idx) n from t.g_%s where name = %L) q where n = %s', p_label, p_name, p_nth) into r; return r; end $$;

select t.fresh();
select t.eq('the dev server settings reach the connection layer: offline mode', net.setting('online_mode'), 'false');
select t.eq('... and no compression', net.setting('compression_threshold'), '-1');
update mc.server_property set value = 'a new motd' where key = 'motd';
select t.eq('mc.server_property is authoritative: a change is copied to net.setting', net.setting('motd'), 'a new motd');
update mc.server_property set value = '7' where key = 'view-distance';
select t.eq('... view distance too', net.setting('view_distance'), '7');
update mc.server_property set value = '2' where key = 'view-distance';

------------------------------------------------------------------------------------------------ login checks happen before login_finished
select t.fresh();
update mc.server_property set value = 'true' where key = 'white-list';
select t.join_client(21, 'Zed');
select mc.server_tick();
select t.is_true('whitelist: the refusal names the translation key', position('multiplayer.disconnect.not_whitelisted' in encode((select string_agg(data, ''::bytea) from net.outbox where conn_id = 21), 'escape')) > 0);
select t.eq('whitelist: the only thing sent is login_disconnect', t.names('login', t.take(21)), array['minecraft:login_disconnect']);
select t.is_true('whitelist: the connection is marked for closing', (select closing from net.conn where conn_id = 21));
select t.is_true('whitelist: no player row was created', not exists (select 1 from mc.player));

select t.fresh();
insert into mc.ban (kind, uuid, name, reason) values ('player', net.offline_uuid('Bad'), 'Bad', 'cheating');
select t.join_client(22, 'Bad');
select mc.server_tick();
select t.is_true('ban: the refusal carries the translation key and the reason',
    encode((select string_agg(data, ''::bytea) from net.outbox where conn_id = 22), 'escape') like '%multiplayer.disconnect.banned.reason%'
    and encode((select string_agg(data, ''::bytea) from net.outbox where conn_id = 22), 'escape') like '%cheating%');

select t.fresh();
update mc.server_property set value = '1' where key = 'max-players';
select t.join_client(23, 'Alice'); select mc.server_tick(); select t.grab(23, 'full1', true);
select t.is_true('first player fits', t.cnt('full1', 'minecraft:login') = 1);
select t.join_client(24, 'Bob'); select mc.server_tick();
select t.is_true('server full: the second is refused', position('multiplayer.disconnect.server_full' in encode((select string_agg(data, ''::bytea) from net.outbox where conn_id = 24), 'escape')) > 0);

------------------------------------------------------------------------------------------------ two players join: order, duplicates, entity ids
select t.fresh();
select t.join_client(11, 'Alice');
select mc.server_tick();
select t.grab(11, 'a1', true);
select t.eq('Alice: the login packet carries the entity id the game assigned',
            proto.i32_read((select body from t.g_a1 where name = 'minecraft:login'), 0), (select entity_id from mc.player where name = 'Alice'));
select t.eq('Alice: two tab-list packets in her burst (the others, then herself), nothing duplicated', t.cnt('a1', 'minecraft:player_info_update'), 2);
select t.eq('Alice: no join message of her own', t.cnt('a1', 'minecraft:system_chat'), 0);
select t.eq('Alice: one chunk batch of 49 chunks with the count at the end', t.cnt('a1', 'minecraft:level_chunk_with_light'), 49);
select t.eq('Alice: the batch count', (select val from proto.varint_read((select body from t.g_a1 where name = 'minecraft:chunk_batch_finished'), 0)), 49);
select t.eq('Alice: first keep-alive is not sent on the first tick', t.cnt('a1', 'minecraft:keep_alive'), 0);

select t.join_client(12, 'Bob');
select mc.server_tick();
select t.grab(11, 'a2'); select t.grab(12, 'b1', true);
select t.eq('Alice is told about Bob in vanilla order: join message, tab entry, then the entity',
            (select array_agg(name order by idx) from t.g_a2 where name in ('minecraft:system_chat', 'minecraft:player_info_update', 'minecraft:add_entity')),
            array['minecraft:system_chat', 'minecraft:player_info_update', 'minecraft:add_entity']);
select t.eq('Bob is not sent his own join message', t.cnt('b1', 'minecraft:system_chat'), 0);
select t.eq('Bob: exactly two tab-list packets', t.cnt('b1', 'minecraft:player_info_update'), 2);
select t.eq('Bob: the player_info for Alice and himself are the ones in his burst, none extra after the chunks',
            (select count(*)::int from t.g_b1 where name = 'minecraft:player_info_update' and idx > (select max(idx) from t.g_b1 where name = 'minecraft:chunk_batch_finished')), 0);
select t.eq('the add_entity Alice gets is Bob with his entity id', (select val from proto.varint_read((select body from t.g_a2 where name = 'minecraft:add_entity'), 0)), (select entity_id from mc.player where name = 'Bob'));
select t.eq('Bob sees Alice', t.cnt('b1', 'minecraft:add_entity'), 1);
select t.is_true('entity ids are distinct and set', (select count(distinct entity_id) = 2 from mc.player where conn_id is not null));
select t.eq('the connection layer and the game agree on the entity ids', (select count(*)::int from net.conn c join mc.player p on p.conn_id = c.conn_id where c.entity_id = p.entity_id), 2);

------------------------------------------------------------------------------------------------ keep-alive and teleports are forwarded to the game
update mc.player set keepalive_sent_tick = (select game_time from mc.game_state) - 400 where name = 'Alice';
select mc.server_tick();
select t.grab(11, 'a3');
select t.eq('a keep-alive is sent when due (15 s)', t.cnt('a3', 'minecraft:keep_alive'), 1);
select t.feed_pkt(11, 'play', 'minecraft:keep_alive', (select body from t.g_a3 where name = 'minecraft:keep_alive'));
select mc.server_tick();
select t.is_true('the answer reached the game: no keep-alive pending', (select keepalive_id is null from mc.player where name = 'Alice'));

select t.feed_pkt(11, 'play', 'minecraft:client_tick_end');
select t.feed_pkt(11, 'play', 'minecraft:move_player_pos', proto.f64(40) || proto.f64(-60) || proto.f64(0.5) || proto.i8(1));
select mc.server_tick();
select t.grab(11, 'a4');
select t.eq('a move of 40 blocks is corrected with a new teleport id', t.cnt('a4', 'minecraft:player_position'), 1);
select t.is_true('the game waits for the confirmation', (select awaiting_teleport = 2 from mc.player where name = 'Alice'));
select t.feed_pkt(11, 'play', 'minecraft:accept_teleportation', proto.varint(2) || proto.f64(0.5) || proto.f64(-60) || proto.f64(0.5) || proto.f32(0) || proto.f32(0));
select mc.server_tick();
select t.is_true('the confirmation reached the game', (select awaiting_teleport is null from mc.player where name = 'Alice'));

------------------------------------------------------------------------------------------------ block actions
select t.take(11); select t.take(12);
select t.is_true('Alice stands over the grass layer', mc.get_block('minecraft:overworld', 0, -61, 0) = 'minecraft:grass_block[snowy=false]');
select t.feed_pkt(11, 'play', 'minecraft:player_action', proto.varint(0) || proto.position(0, -61, 0) || proto.i8(1) || proto.varint(31));
select mc.server_tick();
select t.grab(11, 'a5'); select t.grab(12, 'b2');
select t.eq('creative: start_destroy breaks the block', mc.get_block('minecraft:overworld', 0, -61, 0), 'minecraft:air');
select t.eq('the breaker gets the update, then the acknowledgement',
            (select array_agg(name order by idx) from t.g_a5 where name in ('minecraft:block_update', 'minecraft:block_changed_ack')), array['minecraft:block_update', 'minecraft:block_changed_ack']);
select t.eq('block_update body = position + air', t.pos_of('a5', 'minecraft:block_update'), encode(proto.position(0, -61, 0) || '\x00'::bytea, 'hex'));
select t.eq('the acknowledgement carries the sequence', t.pos_of('a5', 'minecraft:block_changed_ack'), encode(proto.varint(31), 'hex'));
select t.eq('the observer gets the break effect (level event 2001, old state as data) then the update',
            (select array_agg(name order by idx) from t.g_b2 where name in ('minecraft:level_event', 'minecraft:block_update', 'minecraft:block_changed_ack')), array['minecraft:level_event', 'minecraft:block_update']);
select t.eq('level_event body', t.pos_of('b2', 'minecraft:level_event'),
            encode(proto.i32(2001) || proto.position(0, -61, 0) || proto.i32((select state_id from ref.block_state where name = 'minecraft:grass_block[snowy=false]')) || '\x00'::bytea, 'hex'));

select t.feed_pkt(11, 'play', 'minecraft:set_creative_mode_slot', proto.i16(36) || proto.varint(1) || proto.varint(mc.item_id('minecraft:stone')) || proto.varint(0) || proto.varint(0));
select mc.server_tick(); select t.take(11); select t.take(12);
select t.feed_pkt(11, 'play', 'minecraft:use_item_on', proto.varint(0) || proto.position(1, -61, 0) || proto.varint(1) || proto.f32(0.5) || proto.f32(1) || proto.f32(0.5) || proto.bool(false) || proto.bool(false) || proto.varint(32));
select mc.server_tick();
select t.grab(11, 'a6'); select t.grab(12, 'b3');
select t.eq('placing: the neighbour of the clicked face becomes the block of the item', mc.get_block('minecraft:overworld', 1, -60, 0), 'minecraft:stone');
select t.eq('the placer gets clicked block, new block, new block again, then the ack (as recorded from vanilla)',
            (select array_agg(case when name = 'minecraft:block_update' then 'u' || substr(encode(body, 'hex'), 1, 16) else name end order by idx) from t.g_a6 where name in ('minecraft:block_update', 'minecraft:block_changed_ack')),
            array['u' || encode(proto.position(1, -61, 0), 'hex'), 'u' || encode(proto.position(1, -60, 0), 'hex'), 'u' || encode(proto.position(1, -60, 0), 'hex'), 'minecraft:block_changed_ack']);
select t.eq('the observer gets one update with the stone state', t.pos_of('b3', 'minecraft:block_update'), encode(proto.position(1, -60, 0) || proto.varint(1), 'hex'));
select t.eq('creative placing does not consume the item', (select count from mc.inventory_slot where player = net.offline_uuid('Alice') and slot = 36)::int, 1);

-- survival: the item is consumed and the client is told; a placement out of reach is refused with the authoritative state
update mc.player set gamemode = 0 where name = 'Bob';
select mc.set_slot(net.offline_uuid('Bob'), 36, 'minecraft:stone', 3);
select t.take(11); select t.take(12);
select t.feed_pkt(12, 'play', 'minecraft:use_item_on', proto.varint(0) || proto.position(2, -61, 0) || proto.varint(1) || proto.f32(0.5) || proto.f32(1) || proto.f32(0.5) || proto.bool(false) || proto.bool(false) || proto.varint(5));
select mc.server_tick();
select t.grab(12, 'b4');
select t.eq('survival placing works', mc.get_block('minecraft:overworld', 2, -60, 0), 'minecraft:stone');
select t.eq('survival placing consumes one item', (select count from mc.inventory_slot where player = net.offline_uuid('Bob') and slot = 36)::int, 2);
select t.eq('... and the client is told the new count', t.cnt('b4', 'minecraft:container_set_slot'), 1);
select t.take(11); select t.take(12);
select t.feed_pkt(12, 'play', 'minecraft:use_item_on', proto.varint(0) || proto.position(15, -61, 0) || proto.varint(1) || proto.f32(0.5) || proto.f32(1) || proto.f32(0.5) || proto.bool(false) || proto.bool(false) || proto.varint(6));
select mc.server_tick();
select t.grab(12, 'b5');
select t.eq('out of reach: nothing is placed', mc.get_block('minecraft:overworld', 15, -60, 0), 'minecraft:air');
select t.eq('out of reach: only the ack (recorded from the real server: handleUseItemOn returns after the acknowledgement, no block update)',
            (select array_agg(name order by idx) from t.g_b5 where name in ('minecraft:block_update', 'minecraft:block_changed_ack')), array['minecraft:block_changed_ack']);
select t.eq('out of reach: the item is not consumed', (select count from mc.inventory_slot where player = net.offline_uuid('Bob') and slot = 36)::int, 2);
select t.feed_pkt(12, 'play', 'minecraft:player_action', proto.varint(3) || proto.position(0, -62, 0) || proto.i8(1) || proto.varint(7));
select mc.server_tick(); select t.take(11); select t.take(12);
select t.eq('survival breaks on stop_destroy_block', mc.get_block('minecraft:overworld', 0, -62, 0), 'minecraft:air');
select t.feed_pkt(12, 'play', 'minecraft:player_action', proto.varint(3) || proto.position(0, -64, 0) || proto.i8(1) || proto.varint(8));
select mc.server_tick(); select t.take(12);
select t.eq('survival cannot break bedrock', mc.get_block('minecraft:overworld', 0, -64, 0), 'minecraft:bedrock');
update mc.player set gamemode = 1 where name = 'Bob';

-- an edit made in SQL reaches the clients too
select mc.set_block('minecraft:overworld', 3, -60, 3, 'minecraft:gold_block');
select mc.server_tick();
select t.grab(11, 'a7');
select t.eq('a block set from SQL is broadcast to players who have the chunk', t.pos_of('a7', 'minecraft:block_update'),
            encode(proto.position(3, -60, 3) || proto.varint((select state_id from ref.block_state where name = 'minecraft:gold_block')), 'hex'));
select t.take(12);

------------------------------------------------------------------------------------------------ chunk streaming
select t.feed_pkt(11, 'play', 'minecraft:client_tick_end');
select t.feed_pkt(11, 'play', 'minecraft:move_player_pos', proto.f64(8.5) || proto.f64(-60) || proto.f64(0.5) || proto.i8(1));
select mc.server_tick(); select t.take(11); select t.take(12);
select t.feed_pkt(11, 'play', 'minecraft:client_tick_end');
select t.feed_pkt(11, 'play', 'minecraft:move_player_pos', proto.f64(16.5) || proto.f64(-60) || proto.f64(0.5) || proto.i8(1));
select mc.server_tick();
select t.grab(11, 'a8');
select t.eq('crossing into chunk 1: centre first, then the forgets, then the batch',
            (select array_agg(name order by idx) from t.g_a8 where name in ('minecraft:set_chunk_cache_center', 'minecraft:forget_level_chunk', 'minecraft:chunk_batch_start', 'minecraft:chunk_batch_finished')),
            array['minecraft:set_chunk_cache_center'] || array_fill('minecraft:forget_level_chunk'::text, array[7]) || array['minecraft:chunk_batch_start', 'minecraft:chunk_batch_finished']);
select t.eq('the new centre', t.pos_of('a8', 'minecraft:set_chunk_cache_center'), encode(proto.varint(1) || proto.varint(0), 'hex'));
select t.eq('forget_level_chunk is z then x (recorded from vanilla): the column x = -3, z = -3..3',
            (select array_agg(proto.i32_read(body, 0) order by idx) from t.g_a8 where name = 'minecraft:forget_level_chunk'), array[-3, -2, -1, 0, 1, 2, 3]);
select t.is_true('... all with x = -3', (select bool_and(proto.i32_read(body, 4) = -3) from t.g_a8 where name = 'minecraft:forget_level_chunk'));
select t.eq('7 new chunks, the column x = 4, nearest first (z = 0 first)',
            (select array_agg(proto.i32_read(body, 4) order by idx) from t.g_a8 where name = 'minecraft:level_chunk_with_light'), array[0, -1, 1, -2, 2, -3, 3]);
select t.is_true('... all x = 4', (select bool_and(proto.i32_read(body, 0) = 4) from t.g_a8 where name = 'minecraft:level_chunk_with_light'));
select t.eq('the connection layer knows the new view centre', (select view_cx from net.conn where conn_id = 11), 1);
select t.take(12);

------------------------------------------------------------------------------------------------ kicks and leaving
select t.feed_pkt(12, 'play', 'minecraft:move_player_pos', proto.f64(0.5) || proto.f64(-60) || proto.f64(0.5) || proto.i8(1));
select t.feed_pkt(12, 'play', 'minecraft:move_player_pos', proto.f64(0.6) || proto.f64(-60) || proto.f64(0.5) || proto.i8(1));
select t.take(11);
select mc.server_tick();
select t.grab(11, 'a9');
select t.is_true('two position packets in one client tick: the kicked connection is marked for closing', (select closing from net.conn where conn_id = 12));
select t.is_true('... and its disconnect was written before the close', exists (select 1 from net.outbox where conn_id = 12));
select t.is_true('... the player is offline now', (select conn_id is null and entity_id is null from mc.player where name = 'Bob'));
select t.eq('the others hear about it in vanilla order: leave message, entity removal, tab-list removal',
            (select array_agg(name order by idx) from t.g_a9 where name in ('minecraft:system_chat', 'minecraft:remove_entities', 'minecraft:player_info_remove')),
            array['minecraft:system_chat', 'minecraft:remove_entities', 'minecraft:player_info_remove']);
select t.is_true('the drain reports the close', (select close from net.drain_outbox() where conn_id = 12));
select t.is_true('... and removes the connection', not exists (select 1 from net.conn where conn_id = 12));

select net.on_disconnect(11);
select t.is_true('a socket closing takes the player offline', (select conn_id is null from mc.player where name = 'Alice'));

------------------------------------------------------------------------------------------------ compression framing for the game's frames
select t.fresh();
select t.join_client(31, 'Zip'); select mc.server_tick(); select t.take(31);
update net.conn set compression = 256 where conn_id = 31;
insert into mc.play_out (conn_id, data) values (31, proto.frame(mc.pid('keep_alive'), proto.i64(7)));
select mc.server_tick();
select t.eq('a small game frame on a compressed connection gets a data length of 0',
            (select encode(string_agg(data, ''::bytea order by seq), 'hex') from net.outbox where conn_id = 31), encode(proto.frame_small_compressed(mc.pid('keep_alive'), proto.i64(7)), 'hex'));
delete from net.outbox where conn_id = 31;
insert into mc.play_out (conn_id, data) values (31, proto.frame(mc.pid('keep_alive'), decode(repeat('ab', 1000), 'hex')));
select mc.server_tick();
-- (until sql/440 there was no deflate in SQL and such a frame closed the connection; the encoder itself is verified by tests/sql/280 with a real inflater)
select t.is_true('a frame over the threshold is compressed: the connection stays open and no error is recorded',
                 not (select closing from net.conn where conn_id = 31) and not exists (select 1 from mc.error_log where step = 'reframe'));
select t.eq('...as [packet length][data length][zlib]: the data length is the id and the 1000 body bytes',
            (select (proto.varint_read(d, (proto.varint_read(d, 0)).nxt)).val from (select string_agg(data, ''::bytea order by seq) d from net.outbox where conn_id = 31) q),
            octet_length(proto.varint(mc.pid('keep_alive'))) + 1000);
select t.is_true('...and the frame is far smaller than the packet', (select octet_length(string_agg(data, ''::bytea)) < 100 from net.outbox where conn_id = 31));
select t.fresh();
