-- The shared chunk budget of a storm (sql/791, async chunk generation): dbcraft.chunk-budget-per-tick caps the chunk packets sent to ALL connections together in a tick,
-- taken round-robin (everybody's nearest first), and what is not sent stays wanted for the next tick.  Needs the captures only for the datapack.
\ir _net_helpers.sql
\ir ../../sql/400_integration.sql
-- sql/400 reinstalls the original hooks; put the login-path versions back on top of it (what a fresh migration ends with)
\ir ../../sql/460_join_codec.sql
\ir ../../sql/461_join_on_join.sql
\ir ../../sql/462_join_config_burst.sql
\ir ../../sql/430_chunk_queue.sql
\ir ../../sql/790_join_budget.sql
\ir ../../sql/791_join_chunk_budget.sql
\! python3 tools/load_datapack.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
\! python3 tools/load_static_packets.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
\! python3 tools/load_world_ref.py

-- the play-state frames a connection was sent: (position, packet name, body); with p_join the login/configuration frames before finish_configuration are dropped
create or replace function t.play(p_conn bigint, p_join boolean default false) returns table (idx int, name text, body bytea) language plpgsql as $$
begin
    return query
    with f as (select * from t.frames(t.take(p_conn))),
         cut as (select coalesce(case when p_join then (select min(f.idx) from f where f.frame = '\x0103'::bytea) end, -1) as c)
    select f.idx, net.pkt_name('play', 'clientbound', (proto.varint_read(f.frame, (proto.varint_read(f.frame, 0)).nxt)).val),
           substring(f.frame from (proto.varint_read(f.frame, (proto.varint_read(f.frame, 0)).nxt)).nxt + 1)
    from f, cut where f.idx > cut.c order by f.idx;
end $$;
create or replace function t.fresh() returns void language plpgsql as $$
begin
    truncate net.conn, net.inbox, net.outbox, net.play_inbox, net.batch, net.join_parked;
    truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor, mc.block_event, mc.error_log, mc.tick_log, mc.server_tick_log;
    truncate mc.chunk_request, mc.chunk_wanted;
    delete from mc.player; delete from mc.op; delete from mc.whitelist; delete from mc.ban;
    perform mc.configure_dev_server('test', 'creative');
    update mc.server_property set value = '2' where key in ('view-distance', 'simulation-distance');
    update mc.server_property set value = '100' where key = 'max-players';
    update mc.server_property set value = 'false' where key = 'white-list';
    update mc.server_property set value = 'off' where key = 'dbcraft.join-budget-ms';        -- this file is about chunks: no login queue
    update mc.server_property set value = 'async' where key = 'dbcraft.chunk-generation';
    update mc.server_property set value = '64' where key = 'dbcraft.chunk-batch-max';
    update mc.game_state set game_time = 1, day_time = 1;
    delete from mc.chunk where dimension = 'minecraft:overworld';
end $$;
create or replace function t.join_client(p_conn bigint, p_name text) returns void language plpgsql as $$
begin
    perform net.on_connect(p_conn);
    perform t.feed_pkt(p_conn, 'handshake', 'minecraft:intention', proto.varint(777) || proto.string('localhost') || proto.i16(25565) || proto.varint(2));
    perform t.feed_pkt(p_conn, 'login', 'minecraft:hello', proto.string(p_name) || proto.uuid(net.offline_uuid(p_name)));
    perform t.feed_pkt(p_conn, 'login', 'minecraft:login_acknowledged');
    perform t.feed_pkt(p_conn, 'configuration', 'minecraft:select_known_packs', proto.varint(0));
    perform t.feed_pkt(p_conn, 'configuration', 'minecraft:finish_configuration');
end $$;
-- chunk packets in what the connection was sent since the last call (the join tick's login/configuration frames are not play frames: only call after the join tick was drained)
create or replace function t.chunks_to(p_conn bigint) returns int language sql volatile as $$
    select count(*)::int from t.play(p_conn) where name = 'minecraft:level_chunk_with_light' $$;

select t.fresh();
select t.join_client(c, 'Cb' || c) from generate_series(71, 73) c;
select mc.server_tick();
select t.take(c) from generate_series(71, 73) c;                                   -- the join burst (no chunks in async mode)
select t.eq('async: nothing was generated or sent by the join tick', (select count(*)::int from mc.chunk where dimension = 'minecraft:overworld'), 0);
select t.eq('every joiner wants its 49 chunks', (select count(*)::int from mc.chunk_wanted), 147);
select t.eq('the generator makes them all (49 distinct chunks around the spawn: the three joiners share them)', mc.generate_pending(1000), 49);

-- budget 40 for all three connections together
update mc.server_property set value = '40' where key = 'dbcraft.chunk-budget-per-tick';
select mc.server_tick();
create table t.round1 as select c as conn_id, t.chunks_to(c) as n from generate_series(71, 73) c;
select t.eq('tick 1: exactly the budget of 40 chunk packets went out in all', (select sum(n)::int from t.round1), 40);
select t.is_true('...shared round-robin: no connection got fewer than 13 or more than 14', (select min(n) >= 13 and max(n) <= 14 from t.round1));
select t.eq('...and 107 are still wanted', (select count(*)::int from mc.chunk_wanted), 107);
select mc.server_tick();
select t.eq('tick 2: another 40', (select sum(t.chunks_to(c))::int from generate_series(71, 73) c), 40);
select mc.server_tick();
select t.eq('tick 3: another 40', (select sum(t.chunks_to(c))::int from generate_series(71, 73) c), 40);
select mc.server_tick();
select t.eq('tick 4: the last 27', (select sum(t.chunks_to(c))::int from generate_series(71, 73) c), 27);
select t.eq('nothing is left wanted', (select count(*)::int from mc.chunk_wanted), 0);

-- the nearest chunks first: with a budget of 3 per tick for one joiner the first three are the player's own chunk and its nearest neighbours
select t.fresh();
select t.join_client(74, 'Near');
select mc.server_tick();
select t.take(74);
select mc.generate_pending(1000);
update mc.server_property set value = '3' where key = 'dbcraft.chunk-budget-per-tick';
select mc.server_tick();
create table t.near as select proto.i32_read(body, 0) cx, proto.i32_read(body, 4) cz from t.play(74) where name = 'minecraft:level_chunk_with_light';
select t.eq('three chunks in the first tick', (select count(*)::int from t.near), 3);
select t.is_true('...the nearest ones: the player''s own chunk is among them and none is farther than one chunk away',
                 exists (select 1 from t.near, mc.player p where p.conn_id = 74 and t.near.cx = p.chunk_x and t.near.cz = p.chunk_z)
                 and (select max(greatest(abs(cx - (select chunk_x from mc.player where conn_id = 74)), abs(cz - (select chunk_z from mc.player where conn_id = 74)))) <= 1 from t.near));

-- budget 0 = unlimited: one tick sends every wanted chunk (up to the per-connection cap)
select t.fresh();
select t.join_client(c, 'Un' || c) from generate_series(75, 76) c;
select mc.server_tick();
select t.take(c) from generate_series(75, 76) c;
select mc.generate_pending(1000);
update mc.server_property set value = '0' where key = 'dbcraft.chunk-budget-per-tick';
select mc.server_tick();
select t.eq('budget 0: both connections got all 49 chunks in one tick', (select array_agg(t.chunks_to(c) order by c) from generate_series(75, 76) c), array[49, 49]);

-- inline generation is not affected by the budget (a join sends its chunks itself)
select t.fresh();
update mc.server_property set value = 'inline' where key = 'dbcraft.chunk-generation';
update mc.server_property set value = '5' where key = 'dbcraft.chunk-budget-per-tick';
select t.join_client(77, 'Inl');
select mc.server_tick();
select t.eq('inline mode: the join tick still delivers all 49 chunks whatever the budget',
            (select count(*)::int from t.play(77, true) where name = 'minecraft:level_chunk_with_light'), 49);
select t.fresh();
update mc.server_property set value = '600' where key = 'dbcraft.chunk-budget-per-tick';
update mc.server_property set value = 'inline' where key = 'dbcraft.chunk-generation';
