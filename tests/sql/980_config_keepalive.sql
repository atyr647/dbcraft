-- The keep-alive of the configuration state (sql/980, docs/PERF-CAPACITY.md): a connection that waits more than 10 s in the configuration state (a joiner held back by the join entry
-- budget in a big login) is sent a keep_alive (clientbound, configuration) with the clock in ms as its id, at most once a second by the wall clock; its answer clears it; 30 s without an answer
-- disconnects it with disconnect.timeout (vanilla: ServerCommonPacketListenerImpl.keepConnectionAlive, which waits 15 s: here 10 so that a late tick cannot make the answer arrive after the
-- gateway's 30 s read timeout).  Young connections and play connections get nothing, and a join that finishes its configuration in less than 10 s is untouched.
truncate net.conn, net.inbox, net.outbox, net.batch, net.join_parked;
create or replace function t.cka() returns int language plpgsql as $$
begin perform set_config('dbcraft.cfg_ka_next', '', false); return net.config_keepalive(); end $$;       -- (the wall-clock throttle reset: the test calls it many times in one second)
insert into net.conn (conn_id, state, name, connected_at, compression) values
  (1, 'configuration', 'old', now() - interval '16 seconds', -1),
  (2, 'configuration', 'young', now() - interval '3 seconds', -1),
  (3, 'play', 'player', now() - interval '60 seconds', -1),
  (4, 'configuration', 'oldzip', now() - interval '40 seconds', 256),
  (5, 'login', 'parked', now() - interval '16 seconds', -1);
select t.eq('the first call in a second: the two old connections in the configuration state get one', t.cka(), 2);
select t.eq('...a second call in the same second is throttled (nothing is even looked at)', net.config_keepalive(), 0);
select t.eq('...connection 1 (old, uncompressed): a keep_alive frame of 8 + 2 bytes with the clock as id',
            (select (length(data), get_byte(data, 0), get_byte(data, 1))::text from net.outbox where conn_id = 1), '(10,9,4)');
select t.is_true('...its id is the wall clock in ms (within a minute) and is recorded on the connection',
                 (select abs(keepalive_id - extract(epoch from clock_timestamp()) * 1000) < 60000 and keepalive_sent is not null from net.conn where conn_id = 1)
                 and (select proto.i64_read(substring(data from 3), 0) = (select keepalive_id from net.conn where conn_id = 1) from net.outbox where conn_id = 1));
select t.eq('...connection 4 (compression on) got a frame as well', (select count(*)::int from net.outbox where conn_id = 4), 1);
select t.eq('...the young one, the play one and the one in the login state got nothing', (select count(*)::int from net.outbox where conn_id in (2, 3, 5)), 0);
select t.eq('a call after the throttle ran out sends nothing again (an answer is pending)', t.cka(), 0);
-- the answer
select net.h_config(1, 'minecraft:keep_alive', proto.i64((select keepalive_id from net.conn where conn_id = 1)));
select t.is_true('the right answer clears the pending id', (select keepalive_id is null from net.conn where conn_id = 1));
select net.h_config(4, 'minecraft:keep_alive', proto.i64(1));
select t.is_true('a wrong id is ignored (not an error), the pending id stays', (select keepalive_id is not null from net.conn where conn_id = 4));
select net.h_config(4, 'minecraft:keep_alive', '\x01');
select t.is_true('a short body is ignored too', (select keepalive_id is not null from net.conn where conn_id = 4));
-- the next one, 10 s after the last
select t.eq('an answered connection is not sent another one before 10 s have passed', t.cka(), 0);
update net.conn set keepalive_sent = now() - interval '11 seconds' where conn_id = 1;
select t.eq('...but after 10 s of silence it is', t.cka(), 1);
-- the timeout
update net.conn set keepalive_sent = now() - interval '31 seconds' where conn_id = 4;
truncate net.outbox;
select t.eq('30 s without an answer: one disconnect, connection 4 is closing', t.cka(), 0);
select t.is_true('...closing, with a disconnect frame (configuration, clientbound id 2) in the outbox',
                 (select closing from net.conn where conn_id = 4) and (select count(*) = 1 from net.outbox where conn_id = 4 and get_byte(data, 0) > 0));
-- slow ticks (a storm: 700 ms ticks): the check is by the wall clock, not by the tick count, so a connection that became due between two looks is sent its keep-alive at the next look
truncate net.outbox;
update net.conn set keepalive_id = null, keepalive_sent = null, closing = false, connected_at = now() - interval '10.5 seconds' where conn_id = 1;
update mc.game_state set game_time = 1007;
select t.eq('a connection 10.5 s old is sent a keep-alive whatever the tick count is (1007 is not 5 mod 20)', t.cka(), 1);
-- leaving the configuration state clears the id
select t.is_true('the keep-alive column of a connection that finishes its configuration is cleared by net.h_config (finish_configuration)',
                 (select pg_get_functiondef('net.h_config(bigint,text,bytea)'::regprocedure) like '%state = ''play'', keepalive_id = null%'));
-- the hook: net.process_fast calls it
select t.is_true('net.process_fast calls net.config_keepalive', (select pg_get_functiondef('net.process_fast()'::regprocedure) like '%net.config_keepalive()%'));
truncate net.conn, net.outbox;
