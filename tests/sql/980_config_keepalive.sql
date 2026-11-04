-- The keep-alive of the configuration state (sql/980, docs/PERF-CAPACITY.md): a connection that waits more than 15 s in the configuration state (a joiner held back by the join entry
-- budget in a big login) is sent a keep_alive (clientbound, configuration) with the clock in ms as its id, once a second at most; its answer clears it; 30 s without an answer
-- disconnects it with disconnect.timeout (vanilla: ServerCommonPacketListenerImpl.keepConnectionAlive).  Young connections, play connections and every other tick residue get nothing,
-- and a join that finishes its configuration in less than 15 s is untouched.
truncate net.conn, net.inbox, net.outbox, net.batch, net.join_parked;
update mc.game_state set game_time = 1005;           -- 5 mod 20: the tick that looks
insert into net.conn (conn_id, state, name, connected_at, compression) values
  (1, 'configuration', 'old', now() - interval '16 seconds', -1),
  (2, 'configuration', 'young', now() - interval '3 seconds', -1),
  (3, 'play', 'player', now() - interval '60 seconds', -1),
  (4, 'configuration', 'oldzip', now() - interval '40 seconds', 256),
  (5, 'login', 'parked', now() - interval '16 seconds', -1);
update mc.game_state set game_time = 1006;
select t.eq('at 6 mod 20: nothing sent', net.config_keepalive(), 0);
update mc.game_state set game_time = 1005;
select t.eq('at 5 mod 20: the two old connections in the configuration state get one', net.config_keepalive(), 2);
select t.eq('...connection 1 (old, uncompressed): a keep_alive frame of 8 + 2 bytes with the clock as id',
            (select (length(data), get_byte(data, 0), get_byte(data, 1))::text from net.outbox where conn_id = 1), '(10,9,4)');
select t.is_true('...its id is the wall clock in ms (within a minute) and is recorded on the connection',
                 (select abs(keepalive_id - extract(epoch from clock_timestamp()) * 1000) < 60000 and keepalive_sent is not null from net.conn where conn_id = 1)
                 and (select proto.i64_read(substring(data from 3), 0) = (select keepalive_id from net.conn where conn_id = 1) from net.outbox where conn_id = 1));
select t.eq('...connection 4 (compression on) got a frame as well', (select count(*)::int from net.outbox where conn_id = 4), 1);
select t.eq('...the young one, the play one and the one in the login state got nothing', (select count(*)::int from net.outbox where conn_id in (2, 3, 5)), 0);
select t.eq('a second call in the same state sends nothing again (an answer is pending)', net.config_keepalive(), 0);
-- the answer
select net.h_config(1, 'minecraft:keep_alive', proto.i64((select keepalive_id from net.conn where conn_id = 1)));
select t.is_true('the right answer clears the pending id', (select keepalive_id is null from net.conn where conn_id = 1));
select net.h_config(4, 'minecraft:keep_alive', proto.i64(1));
select t.is_true('a wrong id is ignored (not an error), the pending id stays', (select keepalive_id is not null from net.conn where conn_id = 4));
select net.h_config(4, 'minecraft:keep_alive', '\x01');
select t.is_true('a short body is ignored too', (select keepalive_id is not null from net.conn where conn_id = 4));
-- the next one, 15 s after the last
select t.eq('an answered connection is not sent another one before 15 s have passed', net.config_keepalive(), 0);
update net.conn set keepalive_sent = now() - interval '16 seconds' where conn_id = 1;
select t.eq('...but after 15 s of silence it is', net.config_keepalive(), 1);
-- the timeout
update net.conn set keepalive_sent = now() - interval '31 seconds' where conn_id = 4;
truncate net.outbox;
select t.eq('30 s without an answer: one disconnect, connection 4 is closing', net.config_keepalive(), 0);
select t.is_true('...closing, with a disconnect frame (configuration, clientbound id 2) in the outbox',
                 (select closing from net.conn where conn_id = 4) and (select count(*) = 1 from net.outbox where conn_id = 4 and get_byte(data, 0) > 0));
-- leaving the configuration state clears the id
update net.conn set keepalive_id = 77 where conn_id = 2;
select net.h_config(2, 'minecraft:select_known_packs', '\x00') where false;
select t.is_true('the keep-alive column of a connection that finishes its configuration is cleared by net.h_config (finish_configuration)',
                 (select pg_get_functiondef('net.h_config(bigint,text,bytea)'::regprocedure) like '%state = ''play'', keepalive_id = null%'));
-- the hook: net.process_fast calls it
select t.is_true('net.process_fast calls net.config_keepalive', (select pg_get_functiondef('net.process_fast()'::regprocedure) like '%net.config_keepalive()%'));
truncate net.conn, net.outbox;
