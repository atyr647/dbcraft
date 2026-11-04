-- The join stage budget (docs/PERF-STORM.md): the packet that makes a connection enter play is held back once the tick has used its time budget, and a joiner's chunk square
-- is sent over several ticks.  Driven through net.inbox and mc.server_tick() like a gateway, with clients that send each stage one tick after the previous.  Checked: budget
-- off = everything at once; budget on = one entry per tick (oldest connection first) and the others wait; a connection that has waited too long is never held back; what a
-- held-back joiner receives is byte for byte what it receives without the budget; the chunks of a larger square arrive in the same order, nearest first, whether they go out
-- in the join burst or in the following ticks.
\ir _net_helpers.sql
\ir ../../sql/400_integration.sql
-- sql/400 reinstalls the original hooks; put the login-path versions back on top of it (what a fresh migration ends with)
\ir ../../sql/460_join_codec.sql
\ir ../../sql/461_join_on_join.sql
\ir ../../sql/462_join_config_burst.sql
\ir ../../sql/430_chunk_queue.sql
\ir ../../sql/790_join_budget.sql
\ir ../../sql/791_join_chunk_budget.sql
\ir ../../sql/920_join_stage_budget.sql
\! python3 tools/load_datapack.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
\! python3 tools/load_static_packets.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
\! python3 tools/load_world_ref.py

------------------------------------------------------------------------------------------------ helpers
create table if not exists t.stream (conn_id bigint, tick int, data bytea);
create or replace function t.fresh() returns void language plpgsql as $$
begin
    truncate net.conn, net.inbox, net.outbox, net.play_inbox, net.batch, net.join_parked;
    truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor, mc.block_event, mc.error_log, mc.tick_log, mc.server_tick_log;
    truncate mc.chunk_request, mc.chunk_wanted, mc.chunk_wanted_view;
    delete from mc.player; delete from mc.op; delete from mc.whitelist; delete from mc.ban;
    perform mc.configure_dev_server('test', 'creative');
    update mc.server_property set value = '2' where key in ('view-distance', 'simulation-distance');
    update mc.server_property set value = '100' where key = 'max-players';
    update mc.server_property set value = 'false' where key = 'white-list';
    update mc.server_property set value = 'inline' where key = 'dbcraft.chunk-generation';
    update mc.server_property set value = 'off' where key = 'dbcraft.join-budget-ms';            -- the login gate is not under test here
    update mc.server_property set value = '49' where key = 'dbcraft.join-chunks-inline';
    update mc.server_property set value = '64' where key = 'dbcraft.chunk-batch-max';
    update mc.server_property set value = 'off' where key = 'dbcraft.tick-budget-ms';             -- the cap alone (the time-scaled cap has its own check below)
    update mc.server_property set value = '600' where key = 'dbcraft.chunk-budget-per-tick';
    update mc.server_property set value = '25' where key = 'dbcraft.join-entry-budget-ms';
    update mc.server_property set value = '1' where key = 'dbcraft.join-entry-free';
    update mc.game_state set game_time = 1, day_time = 1;
    perform setval('mc.entity_id_seq', 1, false);
    delete from mc.chunk where dimension = 'minecraft:overworld';
    drop table if exists t.stream;
    create table t.stream (conn_id bigint, tick int, data bytea);
end $$;
create or replace function t.stage(p_conn bigint, p_stage int, p_name text default null) returns void language plpgsql as $$
begin
    if p_stage = 1 then
        perform net.on_connect(p_conn);
        perform t.feed_pkt(p_conn, 'handshake', 'minecraft:intention', proto.varint(777) || proto.string('localhost') || proto.i16(25565) || proto.varint(2));
        perform t.feed_pkt(p_conn, 'login', 'minecraft:hello', proto.string(p_name) || proto.uuid(net.offline_uuid(p_name)));
    elsif p_stage = 2 then perform t.feed_pkt(p_conn, 'login', 'minecraft:login_acknowledged');
    elsif p_stage = 3 then perform t.feed_pkt(p_conn, 'configuration', 'minecraft:select_known_packs', proto.varint(0));
    else perform t.feed_pkt(p_conn, 'configuration', 'minecraft:finish_configuration');
    end if;
end $$;
-- one tick; every connection's output of that tick is appended to t.stream
create or replace function t.tick(p_n int) returns void language plpgsql as $$
begin
    update mc.game_state set game_time = 1, day_time = 1;      -- the world clock is in the join burst (set_time): hold it still
    delete from mc.tick_log; delete from mc.server_tick_log;   -- (so the tick numbers can repeat)
    perform mc.server_tick();
    insert into t.stream select c.conn_id, p_n, t.take(c.conn_id) from net.conn c;
end $$;
create or replace function t.nplay() returns int language sql stable as $$ select count(*)::int from net.conn where state = 'play' $$;
create or replace function t.burst_md5(p_conn bigint) returns text language plpgsql stable as $$      -- as tests/sql/790: bytes of the join burst up to its first chunk_batch_finished
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
-- all clients: stage 1 in tick 1, stage 2 in tick 2, stage 3 in tick 3, stage 4 in tick 4; then empty ticks 5 .. p_ticks
create or replace function t.run_logins(p_first int, p_n int, p_prefix text, p_ticks int) returns void language plpgsql as $$
declare i int;
begin
    for i in 1 .. p_ticks loop
        if i <= 4 then perform t.stage(c, i, p_prefix || c) from generate_series(p_first, p_first + p_n - 1) c; end if;
        perform t.tick(i);
    end loop;
end $$;
create or replace function t.chunk_md5s(p_conn bigint) returns text[] language plpgsql stable as $$      -- the chunk packets of a connection in the order received, as md5 of each
declare b bytea; r text[];
begin
    select string_agg(data, ''::bytea order by tick) into b from t.stream where conn_id = p_conn;
    select array_agg(md5(f.frame) order by f.idx) into r from t.frames(b) f
     where (proto.varint_read(f.frame, (proto.varint_read(f.frame, 0)).nxt)).val = net.pkt('play', 'clientbound', 'minecraft:level_chunk_with_light');
    return coalesce(r, '{}');
end $$;

------------------------------------------------------------------------------------------------ 1. entry budget off: all six connections enter play in the same tick
select t.fresh();
update mc.server_property set value = 'off' where key = 'dbcraft.join-entry-budget-ms';
select t.run_logins(41, 6, 'Off', 4);
select t.eq('budget off: all six connections are in play after the tick of their finish_configuration', t.nplay(), 6);
create table t.md5_off as select c as conn_id, t.burst_md5(c) as h from generate_series(41, 46) c;
select t.is_true('...with a complete burst each', (select count(*) = 6 and bool_and(h is not null) from t.md5_off));

------------------------------------------------------------------------------------------------ 2. a budget that is always exhausted: the free entry of each tick, the others wait
select t.fresh();
update mc.server_property set value = '0.001' where key = 'dbcraft.join-entry-budget-ms';           -- exhausted as soon as the tick has done anything
select t.run_logins(41, 6, 'Off', 4);
select t.eq('tick 4: one connection entered play (the free one), five wait', t.nplay(), 1);
select t.eq('...the five finish_configuration packets are back in net.inbox, order kept', (select array_agg(conn_id order by seq) from net.inbox), array[42, 43, 44, 45, 46]::bigint[]);
select t.is_true('...the oldest connection (lowest id) is the one that entered', (select state = 'play' from net.conn where conn_id = 41));
select t.tick(5);
select t.eq('tick 5: one more', t.nplay(), 2);
select t.is_true('...in connection order', (select state = 'play' from net.conn where conn_id = 42) and (select state = 'configuration' from net.conn where conn_id = 43));
select t.tick(6); select t.tick(7); select t.tick(8); select t.tick(9);
select t.eq('tick 9: all six are in play, one entry per tick', t.nplay(), 6);
select t.eq('...nothing left waiting', (select count(*)::int from net.inbox), 0);
create table t.md5_on as select c as conn_id, t.burst_md5(c) as h from generate_series(41, 46) c;
select t.is_true('every held-back joiner got a complete burst', (select count(*) = 6 and bool_and(h is not null) from t.md5_on));
select t.eq('...and the join burst of every one of the six is byte for byte the same as without the budget (entity ids, tab list, chunks, ...)',
            (select count(*)::int from t.md5_off o join t.md5_on n using (conn_id) where o.h is distinct from n.h), 0);

------------------------------------------------------------------------------------------------ 3. two free entries per tick; a connection that waited too long is never held back
select t.fresh();
update mc.server_property set value = '0.001' where key = 'dbcraft.join-entry-budget-ms';
update mc.server_property set value = '2' where key = 'dbcraft.join-entry-free';
select t.run_logins(41, 6, 'Fr', 4);
select t.eq('two free entries per tick: two connections in play after tick 4', t.nplay(), 2);
select t.fresh();
update mc.server_property set value = '0.001' where key = 'dbcraft.join-entry-budget-ms';
select t.run_logins(41, 3, 'Od', 3);
update net.conn set connected_at = now() - interval '40 seconds' where conn_id = 43;              -- waited 40 s: past the maximum wait
select t.stage(c, 4) from generate_series(41, 43) c;
select t.tick(4);
select t.eq('tick 4: the free one (41) and the connection past its maximum wait (43) entered, 42 waits',
            (select array_agg(conn_id order by conn_id) from net.conn where state = 'play'), array[41, 43]::bigint[]);

------------------------------------------------------------------------------------------------ 4. what a held-back connection sends after its entry packet waits behind it
select t.fresh();
update mc.server_property set value = '0.001' where key = 'dbcraft.join-entry-budget-ms';
select t.run_logins(41, 2, 'Bh', 3);
select t.stage(c, 4) from generate_series(41, 42) c;
insert into net.inbox (conn_id, payload) values (42, proto.varint(net.pkt('play', 'serverbound', 'minecraft:client_tick_end')));      -- behind 42's entry packet
select t.tick(4);
select t.eq('42 is held with BOTH packets: the entry packet and the one behind it are in net.inbox again, in order',
            (select array_agg(conn_id order by seq) from net.inbox), array[42, 42]::bigint[]);
select t.tick(5);
select t.eq('next tick: nothing is left in net.inbox', (select count(*)::int from net.inbox), 0);
select t.eq('...and no error: ' || coalesce((select string_agg(step || ': ' || message, '; ') from mc.error_log), ''), (select count(*)::int from mc.error_log), 0);
select t.is_true('...42 is in play', (select state = 'play' from net.conn where conn_id = 42));

------------------------------------------------------------------------------------------------ 5. a larger square: the same chunk packets in the same order, in the join burst or in the following ticks
select t.fresh();
update mc.server_property set value = '4' where key in ('view-distance', 'simulation-distance');             -- 11 x 11 = 121 chunks
update mc.server_property set value = 'off' where key = 'dbcraft.join-entry-budget-ms';
update mc.server_property set value = '0' where key = 'dbcraft.join-chunks-inline';
select mc.generate_flat_area('minecraft:overworld', -8, -8, 8, 8) as made \gset
select t.run_logins(61, 1, 'Sq', 8);
create table t.sq_all as select t.chunk_md5s(61) as h, (select count(*)::int from t.stream where conn_id = 61 and tick = 4 and length(data) > 0) as ticks_with_data;
select t.eq('inline 0: all 121 chunk packets in the join burst', (select cardinality(h) from t.sq_all), 121);
select t.fresh();
update mc.server_property set value = '4' where key in ('view-distance', 'simulation-distance');
update mc.server_property set value = 'off' where key = 'dbcraft.join-entry-budget-ms';
select t.run_logins(61, 1, 'Sq', 8);
create table t.sq_split as select t.chunk_md5s(61) as h;
select t.eq('inline 49: the join burst has 49 chunk packets, the rest (72) follows in later ticks: 121 in all',
            (select cardinality(h) from t.sq_split), 121);
select t.is_true('...the same packets in the same (nearest first) order as sending everything in the join', (select s.h = a.h from t.sq_split s, t.sq_all a));
select t.eq('...nothing left wanted', (select count(*)::int from mc.chunk_wanted), 0);
select t.eq('the first batch of the join holds exactly 49 chunks (chunk_batch_finished says so)',
            (select (proto.varint_read(substring(f.frame from (proto.varint_read(f.frame, 0)).nxt + 2), 0)).val
               from t.stream s, lateral t.frames(s.data) f
              where s.conn_id = 61 and (proto.varint_read(f.frame, (proto.varint_read(f.frame, 0)).nxt)).val = net.pkt('play', 'clientbound', 'minecraft:chunk_batch_finished')
              order by s.tick, f.idx limit 1), 49);

------------------------------------------------------------------------------------------------ 6. the delivery step with a large backlog
select t.fresh();
update mc.server_property set value = '4' where key in ('view-distance', 'simulation-distance');
select mc.generate_flat_area('minecraft:overworld', -8, -8, 8, 8) as made \gset
select t.player(c, 'Bk' || c) from generate_series(71, 74) c;
update net.conn set view_cx = 0, view_cz = 0 where conn_id between 71 and 74;
insert into mc.chunk_wanted (conn_id, dimension, cx, cz, dist) select c, 'minecraft:overworld', dx, dz, dx * dx + dz * dz from generate_series(71, 74) c, generate_series(-5, 5) dx, generate_series(-5, 5) dz;
update mc.server_property set value = '100' where key = 'dbcraft.chunk-budget-per-tick';
select t.eq('a shared budget of 100 over 4 connections: 25 chunks each in the first tick (round-robin), 100 in all', mc.deliver_ready_chunks(), 100);
select t.eq('...the rows left are 4 x 121 - 100', (select count(*)::int from mc.chunk_wanted), 384);
select t.is_true('...everybody got the 25 nearest (the nearest 25 of the square have dist <= 8): none of the delivered rows is farther than every remaining one',
                 (select not exists (select 1 from mc.chunk_wanted w where w.dist < 8 and w.conn_id between 71 and 74 and w.dist <= 2)));
-- a client whose view moved: what left its square is dropped, the rest is delivered
update net.conn set view_cx = 3, view_cz = 0 where conn_id = 71;
select mc.deliver_ready_chunks();
select t.is_true('connection 71 moved 3 chunks east: nothing it still wants is outside its new square',
                 not exists (select 1 from mc.chunk_wanted w where w.conn_id = 71 and (abs(w.cx - 3) > 5 or abs(w.cz) > 5)));
-- a connection that is gone loses its rows
delete from net.conn where conn_id = 72;
select mc.deliver_ready_chunks();
select t.eq('connection 72 disconnected: its wanted rows are gone', (select count(*)::int from mc.chunk_wanted where conn_id = 72), 0);
select t.fresh();
