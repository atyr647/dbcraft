-- sql/800 (the transaction-id gate of mc.tick_quiet), sql/801 (net.gateway_pending's shortcut and bit 4), sql/970 (mc.run_generator_until_idle): what is proved here.
--   1. the gate never hides a change: for every table the quiet predicate probes, and for the switch and the hook, the sequence "two quiet ticks (the gate is armed), the change by another
--      transaction, mc.tick_quiet()" says not quiet.  Every step is its own top-level statement (\gexec): the gate only exists between transactions.
--   2. the same with a SECOND SESSION (dblink): a change committed between two ticks, a change in flight while a tick runs and committed after it, one that is rolled back; and a
--      transaction of the ticking session that has written before the tick (the gate is not used inside it).
--   3. the gate is armed when it should be (an idle session: tick after tick, one probe round per arming, not one per tick) and the mark is cleared when the tick is not quiet.
--   4. net.gateway_pending: 0 right after a quiet tick of the same statement, used up after that, the real probes otherwise; bit 4 for chunk requests.
--   5. mc.run_generator_until_idle generates what is requested, returns after the idle time, and obeys the stop flag.
create extension if not exists dblink;
create or replace function t.gate_reset() returns void language plpgsql as $$
begin
  truncate net.conn_ctl, net.conn, net.inbox, net.outbox, net.play_inbox, net.batch, mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor,
           mc.block_event, mc.chunk_wanted, net.auth_result, net.join_parked, mc.server_tick_log, mc.tick_log, mc.error_log, mc.chunk_request;
  delete from mc.player;
  update net.join_gate_state set active = false;
  update mc.game_state set game_time = 0, day_time = 0;
  perform set_config('dbcraft.quiet_tick', 'on', false);
  perform set_config('dbcraft.quiet_mark', '', false);
  perform set_config('dbcraft.quiet_xid', '', false);
end $$;
select t.gate_reset();

------------------------------------------------------------------------------------------------ 1. every probed table, from another transaction
create temp table gate_cases (id serial, name text, stmt text, clean text);
insert into gate_cases (name, stmt, clean) values
  ('a connection', 'insert into net.conn (conn_id, state, compression) values (1, ''status'', -1)', 'delete from net.conn'),
  ('a frame in the inbox', 'insert into net.inbox (conn_id, payload) values (1, ''\x00'')', 'truncate net.inbox'),
  ('an online player row', 'insert into mc.player (uuid, name, conn_id, entity_id) values (md5(''a'')::uuid, ''a'', 5, 5)', 'delete from mc.player'),
  ('a claimed packet', 'insert into mc.play_in (conn_id, packet_id, body) values (1, 1, ''\x'')', 'truncate mc.play_in'),
  ('a verdict', 'insert into net.auth_result (conn_id, ok) values (1, true)', 'truncate net.auth_result'),
  ('a parked login', 'insert into net.join_parked (seq, conn_id, payload, parked_ms) values (1, 1, ''\x00'', 0)', 'truncate net.join_parked'),
  ('an active login gate', 'update net.join_gate_state set active = true', 'update net.join_gate_state set active = false'),
  ('a kick', 'insert into mc.kick (conn_id, reason_nbt) values (1, ''\x00'')', 'truncate mc.kick'),
  ('a queued frame', 'insert into mc.play_out (conn_id, data) values (1, ''\x00'')', 'truncate mc.play_out'),
  ('a wanted chunk', 'insert into mc.chunk_wanted (conn_id, dimension, cx, cz, dist) values (1, ''minecraft:overworld'', 0, 0, 0)', 'truncate mc.chunk_wanted'),
  ('a block event', 'insert into mc.block_event (dimension, x, y, z, old_state, new_state) values (''minecraft:overworld'', 0, 0, 0, ''a'', ''b'')', 'truncate mc.block_event'),
  ('a pending acknowledgement', 'insert into mc.pending_ack (conn_id, sequence) values (1, 1)', 'truncate mc.pending_ack'),
  ('a block actor', 'insert into mc.block_actor (dimension, x, y, z, conn_id) values (''minecraft:overworld'', 0, 0, 0, 1)', 'truncate mc.block_actor'),
  ('a frame in the connection layer''s batch', 'insert into net.batch (conn_id, seq, payload) values (1, 1, ''\x00'')', 'truncate net.batch'),
  ('a frame in the outbox', 'insert into net.outbox (conn_id, data) values (1, ''\x00'')', 'truncate net.outbox'),
  ('a chunk request', 'insert into mc.chunk_request (dimension, cx, cz, prio) values (''minecraft:overworld'', 0, 0, 0)', 'truncate mc.chunk_request'),
  ('entities switched on', 'update mc.server_property set value = ''inline'' where key = ''dbcraft.entity-mode''', 'update mc.server_property set value = ''off'' where key = ''dbcraft.entity-mode'''),
  ('the switch', 'select set_config(''dbcraft.quiet_tick'', ''off'', false)', 'select set_config(''dbcraft.quiet_tick'', ''on'', false)');
select mc.server_tick();
select mc.server_tick();
select t.is_true('the gate is armed after quiet ticks on an empty server (each tick its own transaction)', (select count(*) from gate_cases) = 18 and current_setting('dbcraft.quiet_mark') <> '');
-- (three ticks arm the gate: background work of the server -- an autovacuum run takes a transaction id -- may spoil one arming, not three in a row)
select s from gate_cases c, lateral (values
    (1, 'select mc.server_tick()'),
    (2, 'select mc.server_tick()'),
    (3, 'select mc.server_tick()'),
    (4, format('select t.is_true(%L, current_setting(''dbcraft.quiet_mark'') <> '''')', c.name || ': the gate is armed before the change')),
    (5, c.stmt),
    (6, format('select t.is_true(%L, not mc.tick_quiet())', c.name || ': the gate does not hide it')),
    (7, c.clean),
    (8, 'select mc.server_tick()'),
    (9, 'select mc.server_tick()'),
    (10, 'select mc.server_tick()'),
    (11, format('select t.is_true(%L, mc.tick_quiet() and current_setting(''dbcraft.quiet_mark'') <> '''')', c.name || ': quiet again after the clean-up, gate armed again'))) v(k, s)
 order by c.id, v.k \gexec

------------------------------------------------------------------------------------------------ 2. a second session
select t.gate_reset();
select dblink_connect('b', format('dbname=%s port=%s host=%s', current_database(), current_setting('port'), (select split_part(setting, ',', 1) from pg_settings where name = 'unix_socket_directories')));
select mc.server_tick();
select mc.server_tick();
select t.is_true('armed', current_setting('dbcraft.quiet_mark') <> '');
select dblink_exec('b', 'insert into net.inbox (conn_id, payload) values (1, ''\x00'')');
select t.is_true('a row committed by another session between two ticks: not quiet', not mc.tick_quiet());
select dblink_exec('b', 'truncate net.inbox');
select mc.server_tick();
select mc.server_tick();
select t.is_true('armed again', current_setting('dbcraft.quiet_mark') <> '');
-- in flight while the tick runs, committed after it
select dblink_exec('b', 'begin');
select dblink_exec('b', 'insert into net.inbox (conn_id, payload) values (1, ''\x00'')');
select t.is_true('a transaction in flight (its row is invisible): the tick is quiet by the probes, and the gate is NOT armed (an id below the tick''s own is running)', mc.tick_quiet() and current_setting('dbcraft.quiet_mark') = '');
select dblink_exec('b', 'commit');
select t.is_true('...and once it commits the next tick sees the row', not mc.tick_quiet());
select dblink_exec('b', 'truncate net.inbox');
select mc.server_tick();
select mc.server_tick();
-- the hole an xmax-only gate would have: B holds an id F, another transaction G > F completes (so the newest completed id is above F), a tick runs (xmax = its own id), and B commits LATER:
-- the commit of B does not raise the newest completed id, but its row is new.  The tick must not arm the gate while F is running (the snapshot's xmin is F).
select dblink_exec('b', 'begin');
select dblink_exec('b', 'insert into net.inbox (conn_id, payload) values (1, ''\x00'')');
insert into mc.error_log (tick, step, message) values (1, 'gate test', 'a transaction that completes while b is in flight');
select t.is_true('b in flight below a completed id: the tick is quiet by the probes, the gate is NOT armed (xmin is the running id)', mc.tick_quiet() and current_setting('dbcraft.quiet_mark') = '');
select mc.server_tick();
select dblink_exec('b', 'commit');
select t.is_true('...and the row of b is seen at the next tick (the commit raised nothing: only the probes can see it)', not mc.tick_quiet());
select dblink_exec('b', 'truncate net.inbox');
select mc.server_tick();
select mc.server_tick();
-- a transaction that began after the tick's id and commits later: the gate was armed, the commit raises the newest completed id
select t.is_true('armed once more', current_setting('dbcraft.quiet_mark') <> '');
select dblink_exec('b', 'begin');
select dblink_exec('b', 'insert into mc.kick (conn_id, reason_nbt) values (1, ''\x00'')');
select t.is_true('in flight after an armed tick: the tick still says quiet (nothing visible)', mc.tick_quiet());
select dblink_exec('b', 'commit');
select t.is_true('...and not after the commit', not mc.tick_quiet());
select dblink_exec('b', 'truncate mc.kick');
select mc.server_tick();
select mc.server_tick();
-- rolled back: nothing to see, the gate recovers
select dblink_exec('b', 'begin');
select dblink_exec('b', 'insert into net.inbox (conn_id, payload) values (1, ''\x00'')');
select dblink_exec('b', 'rollback');
select t.is_true('a rolled-back transaction: still quiet', mc.tick_quiet());
select mc.server_tick();
select mc.server_tick();
select t.is_true('...and the gate arms again', current_setting('dbcraft.quiet_mark') <> '');
select dblink_disconnect('b');

-- a transaction that has written before the tick does not use the gate (it may have written to a probed table itself)
create or replace function t.gate_same_txn() returns boolean language plpgsql as $$
declare q1 boolean; q2 boolean;
begin
  insert into net.inbox (conn_id, payload) values (1, '\x00');
  q1 := mc.tick_quiet();
  delete from net.inbox;
  q2 := mc.tick_quiet();
  return not q1 and q2;
end $$;
select t.gate_reset();
select mc.server_tick();
select mc.server_tick();
select t.is_true('(armed before the same-transaction test, no DDL in between)', current_setting('dbcraft.quiet_mark') <> '');
select t.is_true('a write in the same transaction before the tick: not quiet (and quiet again once it is deleted, by the probes)', t.gate_same_txn());
select t.eq('...and that transaction did not arm the gate for the next one', current_setting('dbcraft.quiet_mark'), '');

-- the hook is asked on every tick, gate or not (it may depend on anything: a clock, a setting)
create or replace function mc.tick_extra_pending() returns boolean language sql volatile as $$ select coalesce(current_setting('dbcraft.test_hook', true), '') = 'on' $$;
select mc.server_tick();
select mc.server_tick();
select t.is_true('the hook is armed-gate-proof: armed', current_setting('dbcraft.quiet_mark') <> '');
select set_config('dbcraft.test_hook', 'on', false);
select t.is_true('the hook says yes: not quiet although nothing was written (the gate does not decide)', not mc.tick_quiet() and current_setting('dbcraft.quiet_mark') = '');
select set_config('dbcraft.test_hook', 'off', false);
select mc.server_tick();
select mc.server_tick();
select t.is_true('the hook says no again: quiet and armed', current_setting('dbcraft.quiet_mark') <> '');
create or replace function mc.tick_extra_pending() returns boolean language sql immutable parallel safe as $$ select false $$;

------------------------------------------------------------------------------------------------ 3. when it is armed
select t.gate_reset();
select mc.server_tick() as t0 \gset
select mc.server_tick();
select mc.server_tick();
select mc.server_tick();
select t.is_true('after a quiet tick the mark is the next transaction id', current_setting('dbcraft.quiet_mark')::bigint = current_setting('dbcraft.quiet_xid')::bigint + 1);
insert into net.inbox (conn_id, payload) values (1, '\x00');
select t.is_true('a tick with a frame in the inbox is not quiet', not mc.tick_quiet() and current_setting('dbcraft.quiet_mark') = '');
truncate net.inbox;
-- the number of probe rounds: count scans of net.conn (the first probe) in one session over 100 idle ticks, statistics flushed
select pg_stat_force_next_flush();
select coalesce(sum(seq_scan + coalesce(idx_scan, 0)), 0)::bigint as scans0 from pg_stat_user_tables where schemaname = 'net' and relname = 'conn' \gset
select count(mc.server_tick()) from generate_series(1, 1) \gset
select 'select mc.server_tick();' from generate_series(1, 100) \gexec
select pg_stat_force_next_flush();
select coalesce(sum(seq_scan + coalesce(idx_scan, 0)), 0)::bigint as scans1 from pg_stat_user_tables where schemaname = 'net' and relname = 'conn' \gset
select t.is_true('100 idle ticks of one session probe at most 3 times (' || (:scans1 - :scans0) || ' probe rounds)', :scans1 - :scans0 <= 3);

------------------------------------------------------------------------------------------------ 4. net.gateway_pending
select t.gate_reset();
select mc.server_tick();
select mc.server_tick();
select t.eq('a quiet tick and the probe in one statement: nothing to hand over', (select p from (select mc.server_tick() as tk, net.gateway_pending(0) as p) q), 0);
select t.is_true('...the shortcut is used up by the call', current_setting('dbcraft.quiet_xid') = '');
insert into net.outbox (conn_id, data) values (5, '\x01');
select t.eq('bytes in the outbox: the tick is not quiet, the probe says bit 1', (select p from (select mc.server_tick() as tk, net.gateway_pending(0) as p) q), 1);
truncate net.outbox;
select mc.server_tick();
insert into mc.chunk_request (dimension, cx, cz, prio) values ('minecraft:overworld', 0, 0, 0);
select t.eq('a chunk request is bit 4 (and makes the tick not quiet)', (select p from (select mc.server_tick() as tk, net.gateway_pending(0) as p) q), 4);
insert into net.conn (conn_id, state, compression) values (77, 'play', -1);
select t.eq('a control row and a chunk request: bits 2 and 4', net.gateway_pending(0), 6);
delete from net.conn;
truncate mc.chunk_request;
select mc.server_tick();
select mc.server_tick();
-- two calls in one transaction: the second probes (something may have been written since the tick)
create or replace function t.pending_twice() returns text language plpgsql as $$
declare a int; b int; tk bigint;
begin
  tk := mc.server_tick();
  a := net.gateway_pending(0);
  insert into net.outbox (conn_id, data) values (5, '\x01');
  b := net.gateway_pending(0);
  return a || '/' || b;
end $$;
select t.eq('in one transaction: the first call right after the quiet tick is 0, the second probes and finds the row', t.pending_twice(), '0/1');
truncate net.outbox;

------------------------------------------------------------------------------------------------ 5. the generator that parks
select t.gate_reset();
update mc.server_property set value = 'async' where key = 'dbcraft.chunk-generation';
select mc.want_chunks(1, 'minecraft:overworld', array(select 9700 + g from generate_series(0, 29) g), array(select 0 from generate_series(0, 29) g), array(select g from generate_series(0, 29) g));
select t.eq('30 chunks are requested', (select count(*)::int from mc.chunk_request), 30);
select clock_timestamp() as g0 \gset
call mc.run_generator_until_idle(16, 1, 200);
select t.eq('run_generator_until_idle generated all 30', (select count(*)::int from mc.chunk where cx between 9700 and 9729 and cz = 0), 30);
select t.eq('...and left an empty queue', (select count(*)::int from mc.chunk_request), 0);
select t.is_true('...and returned after the idle time (at least 200 ms, well under 20 s)', clock_timestamp() - :'g0'::timestamptz between interval '200 milliseconds' and interval '20 seconds');
select clock_timestamp() as g1 \gset
call mc.run_generator_until_idle(16, 1, 300);
select t.is_true('with nothing to do it returns after the idle time', clock_timestamp() - :'g1'::timestamptz between interval '300 milliseconds' and interval '5 seconds');
update mc.generator_control set stop = true;
select clock_timestamp() as g2 \gset
call mc.run_generator_until_idle(16, 1, 5000);
select t.is_true('the stop flag ends it at once', clock_timestamp() - :'g2'::timestamptz < interval '2 seconds');
update mc.generator_control set stop = false;
update mc.server_property set value = 'inline' where key = 'dbcraft.chunk-generation';
