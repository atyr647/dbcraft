-- The SQL half of online mode and the gateway control channel (sql/600, sql/601), without any gateway: this file plays the gateway's part.
-- (The full flow with real RSA/AES and a stub session server is tests/gateway/online_test.py.)
\ir _net_helpers.sql
-- other test files re-include older versions of some of these functions; make sure the ones under test are the live ones
\ir ../../sql/600_gateway.sql
\ir ../../sql/601_online_login.sql

update net.setting set value = 'true' where key = 'online_mode';
insert into net.server_key (id, public_der) values (1, '\x3081a0deadbeef'::bytea) on conflict (id) do update set public_der = excluded.public_der;
update mc.server_property set value = 'false' where key = 'white-list';

create or replace function t.login_start(p_conn bigint, p_name text) returns void language plpgsql as $$
begin
    perform net.on_connect(p_conn);
    perform t.feed_pkt(p_conn, 'handshake', 'minecraft:intention', proto.varint(777) || proto.string('localhost') || proto.i16(25565) || proto.varint(2));
    perform t.feed_pkt(p_conn, 'login', 'minecraft:hello', proto.string(p_name) || proto.uuid(net.offline_uuid(p_name)));
    perform net.process();
end $$;
-- what the gateway does with a key response and a verdict
create or replace function t.verdict(p_conn bigint, p_ok boolean, p_reason text, p_uuid uuid, p_name text, p_props jsonb default '[]') returns int language plpgsql as $$
begin
    perform net.auth_begun(array[p_conn]);
    insert into net.auth_result (conn_id, ok, reason, uuid, name, properties) values (p_conn, p_ok, p_reason, p_uuid, p_name, p_props);
    return net.apply_auth_results();
end $$;

------------------------------------------------------------------------------------------------ the encryption request
select t.login_start(1, 'Skinned');
select t.eq('hello in online mode queues exactly one packet: encryption_request', t.names('login', (select string_agg(data, ''::bytea order by seq) from net.outbox where conn_id = 1)), array['minecraft:hello']);
select verify_token as tok1 from net.conn where conn_id = 1 \gset
select t.eq('the challenge is 4 bytes', octet_length(:'tok1'::bytea), 4);
select t.eq('encryption_request = serverId "", public key, challenge, shouldAuthenticate (26.3 layout, from the bytecode)',
            t.take_hex(1),
            encode(proto.frame(net.pkt('login', 'clientbound', 'minecraft:hello'),
                   proto.string('') || proto.varint(7) || '\x3081a0deadbeef'::bytea || proto.varint(4) || :'tok1'::bytea || '\x01'::bytea), 'hex'));
select t.is_true('the connection waits for the key, still in the login state, not encrypted, nothing sent beyond the request',
                 (select await_key and not auth_pending and state = 'login' and not encrypted and name = 'Skinned' from net.conn where conn_id = 1));
select t.is_true('gateway_ctl hands the gateway the name and the challenge',
                 (select await_key and name = 'Skinned' and verify_token = :'tok1'::bytea from net.gateway_ctl(0) where conn_id = 1));
select t.feed_pkt(1, 'login', 'minecraft:hello', proto.string('Skinned') || proto.uuid(net.offline_uuid('Skinned')));
select net.process();
select t.is_true('a second hello during the key exchange closes the connection', (select closing from net.conn where conn_id = 1));

select t.reset_net();
update net.setting set value = 'true' where key = 'online_mode';
insert into net.server_key (id, public_der) values (1, '\x3081a0deadbeef'::bytea) on conflict (id) do update set public_der = excluded.public_der;
delete from net.server_key;
select t.login_start(2, 'NoKey');
select t.is_true('without a published server key the login is refused instead of sending a broken request',
                 t.names('login', (select string_agg(data, ''::bytea order by seq) from net.outbox where conn_id = 2)) = array['minecraft:login_disconnect'] and (select closing from net.conn where conn_id = 2));
insert into net.server_key (id, public_der) values (1, '\x3081a0deadbeef'::bytea);

------------------------------------------------------------------------------------------------ a successful verdict, with properties
select t.reset_net();
update net.setting set value = 'true' where key = 'online_mode';
select t.login_start(3, 'Skin2');
select t.take(3) is not null;
select t.eq('the verdict is applied', t.verdict(3, true, null, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'Skin2',
            '[{"name":"textures","value":"VAL","signature":"SIG"},{"name":"extra","value":"v2"}]'), 1);
select session_id as sid3 from net.conn where conn_id = 3 \gset
select t.eq('login_finished = uuid, name, properties (count, name, value, nullable signature), session id',
            t.take_hex(3),
            encode(proto.frame(net.pkt('login', 'clientbound', 'minecraft:login_finished'),
                   proto.uuid('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee') || proto.string('Skin2')
                   || proto.varint(2) || proto.string('textures') || proto.string('VAL') || '\x01'::bytea || proto.string('SIG') || proto.string('extra') || proto.string('v2') || '\x00'::bytea
                   || proto.uuid(:'sid3'::uuid)), 'hex'));
select t.is_true('the connection has the VERIFIED identity, is encrypted and moves on',
                 (select state = 'login_ack' and name = 'Skin2' and uuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' and encrypted and not auth_pending and not await_key from net.conn where conn_id = 3));
select t.eq('properties are stored as readable rows', (select count(*)::int from mc.player_property where uuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'), 2);
select t.is_true('...in order, the second without a signature',
                 (select array_agg(name || ':' || coalesce(signature, '-') order by ord) = array['textures:SIG', 'extra:-'] from mc.player_property where uuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'));
select t.eq('mc.profile_props is the wire form', encode(mc.profile_props('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'), 'hex'),
            encode(proto.varint(2) || proto.string('textures') || proto.string('VAL') || '\x01'::bytea || proto.string('SIG') || proto.string('extra') || proto.string('v2') || '\x00'::bytea, 'hex'));
select t.eq('a player without properties has the empty list (offline players, the old bytes)', encode(mc.profile_props(net.offline_uuid('Plain')), 'hex'), '00');
select t.eq('the cached tab-entry head carries the properties', (select encode(head, 'hex') from net.conn_tab where conn_id = 3),
            encode(proto.uuid('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee') || proto.string('Skin2') || mc.profile_props('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee') || '\x00'::bytea, 'hex'));
select t.is_true('the player_info_update body for the player contains them',
                 position(mc.profile_props('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee') in net.player_info_body(array[3::bigint])) > 0);
select t.is_true('mc.pie_add (the add-player entry of the game module) carries them right after uuid and name',
                 position(mc.profile_props('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee') in mc.pie_add('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'Skin2', 1))
                   = octet_length(proto.uuid('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee') || proto.string('Skin2')) + 1);
select t.is_true('...and the entry of an offline player is byte for byte what it was (properties count 0)',
                 mc.pie_add(net.offline_uuid('Plain'), 'Plain', 1) = proto.uuid(net.offline_uuid('Plain')) || proto.string('Plain') || '\x00'::bytea || '\x00'::bytea || proto.varint(1) || '\x01'::bytea
                                                                      || proto.varint(0) || '\x00'::bytea || proto.varint(0) || '\x00'::bytea);
select t.login_start(4, 'Skin2b');
select t.take(4) is not null;
select t.verdict(4, true, null, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'Skin2', '[{"name":"textures","value":"NEW","signature":"S2"}]');
select t.eq('...the old rows are gone, the new ones are there', (select array_agg(name || ':' || value order by ord) from mc.player_property where uuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'), array['textures:NEW']);
select t.login_start(5, 'Many');
select t.take(5) is not null;
select t.verdict(5, true, null, 'bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee', 'Many',
                 (select jsonb_agg(jsonb_build_object('name', 'p' || g, 'value', 'v')) from generate_series(1, 20) g));
select t.eq('more than 16 properties are cut at the codec limit', (select count(*)::int from mc.player_property where uuid = 'bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee'), 16);

------------------------------------------------------------------------------------------------ failures
select t.reset_net();
update net.setting set value = 'true' where key = 'online_mode';
select t.login_start(10, 'Inv'); select t.take(10);
select t.eq('invalid session: processed', t.verdict(10, false, 'invalid', null, null), 1);
select t.eq('...multiplayer.disconnect.unverified_username, then close',
            t.take_hex(10), encode(proto.frame(net.pkt('login', 'clientbound', 'minecraft:login_disconnect'), proto.string(nbt.json_translate('multiplayer.disconnect.unverified_username'))), 'hex'));
select t.is_true('...and the connection is closing, not encrypted into play', (select closing and state = 'login' from net.conn where conn_id = 10));
select t.login_start(11, 'Down'); select t.take(11);
select t.verdict(11, false, 'unavailable', null, null);
select t.eq('session server unavailable: multiplayer.disconnect.authservers_down',
            t.take_hex(11), encode(proto.frame(net.pkt('login', 'clientbound', 'minecraft:login_disconnect'), proto.string(nbt.json_translate('multiplayer.disconnect.authservers_down'))), 'hex'));
select t.login_start(12, 'BadName'); select t.take(12);
select t.verdict(12, true, null, 'cccccccc-bbbb-cccc-dddd-eeeeeeeeeeee', 'has space');
select t.eq('an answer with an invalid name is not accepted', t.take_hex(12),
            encode(proto.frame(net.pkt('login', 'clientbound', 'minecraft:login_disconnect'), proto.string(nbt.json_translate('multiplayer.disconnect.unverified_username'))), 'hex'));
select t.login_start(13, 'NoUuid'); select t.take(13);
select t.verdict(13, true, null, null, 'NoUuid');
select t.eq('an answer without a profile id is not accepted', t.take_hex(13),
            encode(proto.frame(net.pkt('login', 'clientbound', 'minecraft:login_disconnect'), proto.string(nbt.json_translate('multiplayer.disconnect.unverified_username'))), 'hex'));

-- the checks the game module owns still apply, after authentication (vanilla's order)
update mc.server_property set value = 'true' where key = 'white-list';
select t.login_start(14, 'NotListed'); select t.take(14);
select t.verdict(14, true, null, 'dddddddd-bbbb-cccc-dddd-eeeeeeeeeeee', 'NotListed');
select t.eq('a verified player who is not whitelisted is refused with the whitelist message', t.take_hex(14),
            encode(proto.frame(net.pkt('login', 'clientbound', 'minecraft:login_disconnect'), proto.string(mc.disconnect_json('multiplayer.disconnect.not_whitelisted', null::text[], null::text[]))), 'hex'));
update mc.server_property set value = 'false' where key = 'white-list';

------------------------------------------------------------------------------------------------ verdicts that must be ignored
select t.reset_net();
update net.setting set value = 'true' where key = 'online_mode';
select t.login_start(20, 'Waiting'); select t.take(20);
insert into net.auth_result (conn_id, ok, uuid, name) values (20, true, 'eeeeeeee-bbbb-cccc-dddd-eeeeeeeeeeee', 'Waiting');
select t.eq('a verdict for a connection whose key response was never reported is ignored', net.apply_auth_results(), 0);
select t.is_true('...it still waits for the key and nothing was sent', (select await_key and state = 'login' from net.conn where conn_id = 20) and t.take(20) = '\x'::bytea);
insert into net.auth_result (conn_id, ok, uuid, name) values (999, true, 'eeeeeeee-bbbb-cccc-dddd-eeeeeeeeeeee', 'Gone');
select t.eq('a verdict for a connection that no longer exists is ignored', net.apply_auth_results(), 0);
select t.eq('applied verdicts are consumed', (select count(*)::int from net.auth_result), 0);
select t.eq('auth_begun only counts connections that were waiting', net.auth_begun(array[20::bigint, 20, 999]), 1);
select t.eq('...a second call does nothing', net.auth_begun(array[20::bigint]), 0);

------------------------------------------------------------------------------------------------ compression with online mode
select t.reset_net();
update net.setting set value = 'true' where key = 'online_mode';
update net.setting set value = '256' where key = 'compression_threshold';
select t.login_start(30, 'Zip'); select t.take(30);
select t.verdict(30, true, null, 'ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee', 'Zip');
select session_id as sid30 from net.conn where conn_id = 30 \gset
select t.eq('compression is announced first (itself uncompressed), then login_finished with a data length of 0',
            t.take_hex(30),
            encode(proto.frame(net.pkt('login', 'clientbound', 'minecraft:login_compression'), proto.varint(256))
                   || proto.frame_small_compressed(net.pkt('login', 'clientbound', 'minecraft:login_finished'),
                        proto.uuid('ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee') || proto.string('Zip') || '\x00'::bytea || proto.uuid(:'sid30'::uuid)), 'hex'));
select t.eq('the connection now has the threshold', (select compression from net.conn where conn_id = 30), 256);
select t.eq('gateway_ctl tells the gateway', (select compression from net.gateway_ctl(0) where conn_id = 30), 256);
update net.setting set value = '-1' where key = 'compression_threshold';

------------------------------------------------------------------------------------------------ the control channel
select t.reset_net();
select net.on_connect(40); select net.on_connect(41);
select t.is_true('every new connection is stamped', (select count(*) = 2 and min(ctl_seq) > 0 from net.gateway_ctl(0)));
select max(ctl_seq) as m1 from net.conn \gset
select t.eq('nothing newer than the last seen sequence', (select count(*)::int from net.gateway_ctl(:m1)), 0);
update net.conn set latency_ms = 7, last_activity = now(), keepalive_id = 5 where conn_id = 40;
select t.eq('the per-tick keep-alive columns do not stamp (they must stay in-place updates)', (select count(*)::int from net.gateway_ctl(:m1)), 0);
update net.conn set state = 'play' where conn_id = 40;
select t.eq('a state change does, for that connection only', (select array_agg(conn_id) from net.gateway_ctl(:m1)), array[40::bigint]);
select t.is_true('...with the state', (select state = 'play' from net.gateway_ctl(:m1) where conn_id = 40));
select max(ctl_seq) as m2 from net.conn \gset
update net.conn set compression = 256 where conn_id = 41;
select t.eq('a threshold change does', (select array_agg(conn_id) from net.gateway_ctl(:m2)), array[41::bigint]);
select t.is_true('the verify token is only revealed while a key is awaited', (select verify_token is null from net.gateway_ctl(0) where conn_id = 41));

------------------------------------------------------------------------------------------------ gateway start
select t.reset_net();
select t.player(50, 'Old1'); select t.player(51, 'Old2');
insert into net.outbox (conn_id, data) values (50, '\x01'), (51, '\x02');
insert into net.inbox (conn_id, payload) values (50, '\x00');
select t.eq('gateway_start cleans every stale connection', net.gateway_start(), 2);
select t.is_true('...its rows and the queues that could carry bytes for the old ids are empty',
                 (select count(*) from net.conn) = 0 and (select count(*) from net.outbox) = 0 and (select count(*) from net.inbox) = 0);
select t.eq('...and it is a no-op on a clean database', net.gateway_start(), 0);
