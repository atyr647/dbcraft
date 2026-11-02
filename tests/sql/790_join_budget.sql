-- The join budget (sql/790): logins are admitted through a gate so that a storm does not become one huge tick.  Driven through net.inbox and mc.server_tick() as a gateway
-- would.  Checked here: budget off = the old behaviour; the admission order and the AIMD rate; the deadline floor; the status ping is never delayed; a parked connection
-- that closes is cleaned up; and a joiner that WAS delayed receives exactly the bytes it receives without the budget (only the time of the join moves).
\ir _net_helpers.sql
\ir ../../sql/400_integration.sql
-- sql/400 reinstalls the original hooks; put the login-path versions back on top of it (what a fresh migration ends with)
\ir ../../sql/460_join_codec.sql
\ir ../../sql/461_join_on_join.sql
\ir ../../sql/462_join_config_burst.sql
\ir ../../sql/790_join_budget.sql
\! python3 tools/load_datapack.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
\! python3 tools/load_static_packets.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
\! python3 tools/load_world_ref.py

------------------------------------------------------------------------------------------------ helpers
create table if not exists t.stream (conn_id bigint, tick int, data bytea);       -- (the SQL helpers below are validated against it when created; t.fresh recreates it)
create or replace function t.fresh() returns void language plpgsql as $$
begin
    truncate net.conn, net.inbox, net.outbox, net.play_inbox, net.batch, net.join_parked;
    truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor, mc.block_event, mc.error_log, mc.tick_log, mc.server_tick_log;
    delete from mc.player; delete from mc.op; delete from mc.whitelist; delete from mc.ban;
    perform mc.configure_dev_server('test', 'creative');
    update mc.server_property set value = '2' where key in ('view-distance', 'simulation-distance');
    update mc.server_property set value = '100' where key = 'max-players';
    update mc.server_property set value = 'false' where key = 'white-list';
    update mc.server_property set value = 'inline' where key = 'dbcraft.chunk-generation';
    update mc.game_state set game_time = 1, day_time = 1;       -- no set_time broadcast (every 20th tick) inside the few ticks a test runs
    update net.join_gate_state set rate = 3, active = false, base_ms = null, parked_total = 0, released_total = 0, forced_total = 0, max_queue = 0, last_release = 0;
    perform set_config('dbcraft.sim_clock_ms', '', false);
    perform setval('mc.entity_id_seq', 1, false);            -- entity ids are in the join burst: every scenario starts counting at 1
    delete from mc.chunk where dimension = 'minecraft:overworld';
    drop table if exists t.stream;
    create table t.stream (conn_id bigint, tick int, data bytea);
end $$;
create or replace function t.settings(p_budget text, p_wait text, p_initial text) returns void language plpgsql as $$
begin
    update mc.server_property set value = p_budget  where key = 'dbcraft.join-budget-ms';
    update mc.server_property set value = p_wait    where key = 'dbcraft.join-max-wait-s';
    update mc.server_property set value = p_initial where key = 'dbcraft.join-initial-rate';
end $$;
-- a login that sends all its packets at once (handshake, hello, login_acknowledged, select_known_packs, finish_configuration)
create or replace function t.join_client(p_conn bigint, p_name text) returns void language plpgsql as $$
begin
    perform net.on_connect(p_conn);
    perform t.feed_pkt(p_conn, 'handshake', 'minecraft:intention', proto.varint(777) || proto.string('localhost') || proto.i16(25565) || proto.varint(2));
    perform t.feed_pkt(p_conn, 'login', 'minecraft:hello', proto.string(p_name) || proto.uuid(net.offline_uuid(p_name)));
    perform t.feed_pkt(p_conn, 'login', 'minecraft:login_acknowledged');
    perform t.feed_pkt(p_conn, 'configuration', 'minecraft:select_known_packs', proto.varint(0));
    perform t.feed_pkt(p_conn, 'configuration', 'minecraft:finish_configuration');
end $$;
-- only the handshake and the hello (stage one of a login)
create or replace function t.hello_only(p_conn bigint, p_name text) returns void language plpgsql as $$
begin
    perform net.on_connect(p_conn);
    perform t.feed_pkt(p_conn, 'handshake', 'minecraft:intention', proto.varint(777) || proto.string('localhost') || proto.i16(25565) || proto.varint(2));
    perform t.feed_pkt(p_conn, 'login', 'minecraft:hello', proto.string(p_name) || proto.uuid(net.offline_uuid(p_name)));
end $$;
-- one tick; every connection's output of that tick is appended to t.stream
create or replace function t.tick(p_n int) returns void language plpgsql as $$
begin
    update mc.game_state set game_time = 1, day_time = 1;      -- the world clock is in the join burst (set_time): hold it still, ticks of a delayed join are not what is compared
    perform mc.server_tick();
    insert into t.stream select c.conn_id, p_n, t.take(c.conn_id) from net.conn c;
end $$;
-- the connections (among p_conns) whose output so far contains a login_finished frame (state login: its first frame is login_finished, id from ref.packet)
create or replace function t.got_login_finished(p_conn bigint) returns boolean language sql stable as $$
    select exists (select 1 from t.stream s, lateral t.frames(s.data) f
                    where s.conn_id = p_conn and (proto.varint_read(f.frame, (proto.varint_read(f.frame, 0)).nxt)).val = net.pkt('login', 'clientbound', 'minecraft:login_finished')
                      and f.idx = 0 and s.tick = (select min(s2.tick) from t.stream s2 where s2.conn_id = p_conn and length(s2.data) > 0)) $$;
create or replace function t.first_tick_with_output(p_conn bigint) returns int language sql stable as $$
    select min(tick) from t.stream where conn_id = p_conn and length(data) > 0 $$;
-- the join burst of a connection, bytes only: all frames of the stream except the first (login_finished: it holds a random session id) and everything after the
-- chunk_batch_finished that ends the join (what follows depends on who joined when: join messages, add_entity)
create or replace function t.burst_md5(p_conn bigint) returns text language plpgsql stable as $$
declare b bytea; r text;
begin
    select string_agg(data, ''::bytea order by tick) into b from t.stream where conn_id = p_conn;
    with f as (select * from t.frames(b)),
         cut as (select min(idx) c from f where frame = '\x0103'::bytea),
         fin as (select min(f.idx) e from f, cut where f.idx > cut.c
                    and (proto.varint_read(f.frame, (proto.varint_read(f.frame, 0)).nxt)).val = net.pkt('play', 'clientbound', 'minecraft:chunk_batch_finished'))
    select md5(string_agg(f.frame, ''::bytea order by f.idx)) into r from f, fin where f.idx > 0 and f.idx <= fin.e;
    return r;
end $$;

------------------------------------------------------------------------------------------------ 1. budget off: everything at once, nothing parked
select t.fresh();
select t.settings('off', '20', '1');
select t.hello_only(c, 'Off' || c) from generate_series(41, 46) c;
select t.tick(1);
select t.eq('budget off: nothing is ever parked', (select count(*)::int from net.join_parked), 0);
select t.eq('budget off: all six logins are answered in the first tick', (select count(*)::int from generate_series(41, 46) c where t.got_login_finished(c)), 6);

------------------------------------------------------------------------------------------------ 2. admission in arrival order at the AIMD rate (1, then +1 per tick: the budget is huge)
select t.fresh();
select t.settings('100000', '1000', '1');
select t.hello_only(c, 'Aimd' || c) from generate_series(41, 46) c;
select t.tick(1);
select t.eq('tick 1 admits 1 login (the initial rate), the other 5 are parked', (select count(*)::int from net.join_parked), 5);
select t.is_true('...the first to arrive is the one admitted', t.got_login_finished(41) and not t.got_login_finished(42));
select t.eq('the parked packets keep their order: lowest conn_id first', (select array_agg(conn_id order by seq) from net.join_parked), array[42, 43, 44, 45, 46]::bigint[]);
select t.tick(2);
select t.eq('tick 2 admits 2 (rate 2): 42 and 43', (select array_agg(c::bigint order by c) from generate_series(41, 46) c where t.got_login_finished(c)), array[41, 42, 43]::bigint[]);
select t.tick(3);
select t.eq('tick 3 admits the remaining 3 (rate 3): the queue is empty', (select count(*)::int from net.join_parked), 0);
select t.eq('...all six were answered', (select count(*)::int from generate_series(41, 46) c where t.got_login_finished(c)), 6);
select t.eq('the counters agree: 6 parked at most 5 at a time, 6 released', (select released_total::int from net.join_gate_state), 6);
select t.is_true('the gate state returns to idle after the storm', (select not active from net.join_gate_state) or (select count(*) = 0 from net.join_parked));
select t.tick(4);
select t.is_true('one more tick with nothing queued resets the gate', (select not active and rate = 1 from net.join_gate_state));

------------------------------------------------------------------------------------------------ 3. the deadline floor: nobody waits longer than the maximum wait (in the gate's own clock)
select t.fresh();
select t.settings('100000', '0.2', '1');                            -- 200 ms: at most 4 ticks of 50 ms
select set_config('dbcraft.sim_clock_ms', '1000', false);
select t.hello_only(c, 'Dl' || c) from generate_series(51, 60) c;
select t.tick(1);
select t.is_true('the first tick admits at least ceil(10 / 4) = 3 although the AIMD rate is 1', (select count(*) >= 3 from generate_series(51, 60) c where t.got_login_finished(c)));
select set_config('dbcraft.sim_clock_ms', '1050', false);
select t.tick(2);
select set_config('dbcraft.sim_clock_ms', '1100', false);
select t.tick(3);
select set_config('dbcraft.sim_clock_ms', '1150', false);
select t.tick(4);
select set_config('dbcraft.sim_clock_ms', '1200', false);
select t.tick(5);
select t.eq('after the maximum wait (4 ticks of 50 ms and one more) every login is through', (select count(*)::int from net.join_parked), 0);
select t.eq('...all ten answered', (select count(*)::int from generate_series(51, 60) c where t.got_login_finished(c)), 10);
select t.is_true('...and the deadline, not the AIMD rate, decided some of the ticks', (select forced_total > 0 from net.join_gate_state));
select set_config('dbcraft.sim_clock_ms', '', false);

------------------------------------------------------------------------------------------------ 4. a status ping is never delayed, even inside a storm
select t.fresh();
select t.settings('100000', '1000', '1');
select t.hello_only(c, 'St' || c) from generate_series(41, 44) c;
select net.on_connect(99);
select t.feed_pkt(99, 'handshake', 'minecraft:intention', proto.varint(777) || proto.string('localhost') || proto.i16(25565) || proto.varint(1));
select t.feed_pkt(99, 'status', 'minecraft:status_request');
select t.tick(1);
select t.eq('the storm parks three of four logins', (select count(*)::int from net.join_parked), 3);
select t.is_true('...but the status connection (intent 1) got its status_response in the same tick',
                 exists (select 1 from t.stream s, lateral t.frames(s.data) f
                          where s.conn_id = 99 and (proto.varint_read(f.frame, (proto.varint_read(f.frame, 0)).nxt)).val = net.pkt('status', 'clientbound', 'minecraft:status_response')));

------------------------------------------------------------------------------------------------ 5. a parked connection that closes is forgotten
select t.fresh();
select t.settings('100000', '1000', '1');
select t.hello_only(c, 'Gone' || c) from generate_series(41, 44) c;
select t.tick(1);
select t.eq('three parked after the first tick', (select count(*)::int from net.join_parked), 3);
select net.on_disconnect(43);
select t.tick(2);
select t.is_true('connection 43 left while parked: nothing of it remains in the queue', not exists (select 1 from net.join_parked where conn_id = 43));
select t.tick(3);
select t.eq('the others are all admitted regardless', (select count(*)::int from net.join_parked), 0);
select t.is_true('...44 was answered, 43 never was', t.got_login_finished(44) and not exists (select 1 from t.stream where conn_id = 43 and length(data) > 0));

------------------------------------------------------------------------------------------------ 6. the bytes of a delayed joiner are exactly the bytes it gets without the budget
select setseed(0.5);
select t.fresh();
select t.settings('off', '20', '1');
select t.join_client(c, 'Same' || c) from generate_series(81, 85) c;
select t.tick(1);
select t.tick(2);
create table t.md5_off as select c as conn_id, t.burst_md5(c) as h from generate_series(81, 85) c;
select t.eq('without the budget all five joins finish in tick 1', (select count(distinct tick)::int from t.stream where length(data) > 0 and conn_id = 85 and tick = 1), 1);
select setseed(0.5);
select t.fresh();
select t.settings('100000', '1000', '1');
select t.join_client(c, 'Same' || c) from generate_series(81, 85) c;
select t.tick(n) from generate_series(1, 12) n;                 -- the 25 packets of five logins at 1, 2, 3, ... per tick
create table t.md5_on as select c as conn_id, t.burst_md5(c) as h from generate_series(81, 85) c;
select t.is_true('with the budget connection 85 is delayed (first output in a later tick than connection 81)', t.first_tick_with_output(85) > t.first_tick_with_output(81));
select t.is_true('every joiner got a complete burst (the md5 exists)', (select count(*) = 5 and bool_and(h is not null) from t.md5_on));
select t.eq('...and the join burst of every one of the five is byte for byte the same with and without the budget',
            (select count(*)::int from t.md5_off o join t.md5_on n using (conn_id) where o.h is distinct from n.h), 0);
select t.fresh();
select t.settings('25', '20', '3');
