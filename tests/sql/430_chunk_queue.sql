-- The chunk request queue (sql/430): generation off the tick.
--   part 1: the queue itself (priorities, who wants what, failures, the generator loop)
--   part 2: through the connection layer in async mode: a join gets no chunks from the tick, they arrive as the generator produces them, byte-identical
--           and in the same order as inline mode produced them; chunk streaming across a border; pacing; clean-up when a player goes away.
\ir _net_helpers.sql
\ir ../../sql/400_integration.sql
\ir ../../sql/430_chunk_queue.sql
\! python3 tools/load_datapack.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
\! python3 tools/load_static_packets.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
\! python3 tools/load_world_ref.py

create or replace function t.join_client(p_conn bigint, p_name text) returns void language plpgsql as $$
begin
    perform net.on_connect(p_conn);
    perform t.feed_pkt(p_conn, 'handshake', 'minecraft:intention', proto.varint(777) || proto.string('localhost') || proto.i16(25565) || proto.varint(2));
    perform t.feed_pkt(p_conn, 'login', 'minecraft:hello', proto.string(p_name) || proto.uuid(net.offline_uuid(p_name)));
    perform t.feed_pkt(p_conn, 'login', 'minecraft:login_acknowledged');
    perform t.feed_pkt(p_conn, 'configuration', 'minecraft:select_known_packs', proto.varint(0));
    perform t.feed_pkt(p_conn, 'configuration', 'minecraft:finish_configuration');
end $$;
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
    truncate net.conn, net.inbox, net.outbox, net.play_inbox, net.batch;
    truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor, mc.block_event, mc.error_log, mc.tick_log, mc.server_tick_log;
    truncate mc.chunk_request, mc.chunk_wanted;
    delete from mc.player; delete from mc.op; delete from mc.whitelist; delete from mc.ban;
    perform mc.configure_dev_server('test', 'creative');
    update mc.server_property set value = '2' where key in ('view-distance', 'simulation-distance');
    update mc.server_property set value = '10' where key = 'max-players';
    update mc.server_property set value = 'false' where key = 'white-list';
    update mc.server_property set value = 'inline' where key = 'dbcraft.chunk-generation';
    update mc.server_property set value = '64' where key = 'dbcraft.chunk-batch-max';
    update mc.game_state set game_time = 100, day_time = 100;
    delete from mc.chunk where dimension = 'minecraft:overworld';       -- an unexplored world
end $$;
create or replace function t.grab(p_conn bigint, p_label text, p_join boolean default false) returns void language plpgsql as $$
begin
    execute format('drop table if exists t.g_%s', p_label);
    execute format('create table t.g_%s as select * from t.play(%s, %L)', p_label, p_conn, p_join);
end $$;
-- "cx,cz" of the chunk packets in a captured tick, in the order they were sent
create or replace function t.chunk_coords(p_label text) returns text[] language plpgsql as $$
declare r text[];
begin execute format('select coalesce(array_agg(proto.i32_read(body, 0) || '','' || proto.i32_read(body, 4) order by idx), ''{}'') from t.g_%s where name = ''minecraft:level_chunk_with_light''', p_label) into r; return r; end $$;
create or replace function t.names_of(p_label text) returns text[] language plpgsql as $$
declare r text[];
begin execute format('select coalesce(array_agg(replace(name, ''minecraft:'', '''') order by idx), ''{}'') from t.g_%s', p_label) into r; return r; end $$;
create or replace function t.cnt_name(p_label text, p_name text) returns int language plpgsql as $$
declare r int;
begin execute format('select count(*)::int from t.g_%s where name = %L', p_label, p_name) into r; return r; end $$;

------------------------------------------------------------------------------------------------ part 1: the queue
select t.fresh();
update mc.server_property set value = 'async' where key = 'dbcraft.chunk-generation';
select t.is_true('async mode is on', mc.chunk_generation_async());
select mc.want_chunks(1, 'minecraft:overworld', array[9000, 9001, 9002], array[0, 0, 0], array[4, 1, 9]);
select t.eq('a request is recorded, nothing generated', (select count(*)::int from mc.chunk where cx >= 9000), 0);
select t.eq('three requests', (select count(*)::int from mc.chunk_request), 3);
select t.eq('three wanted rows for connection 1', (select count(*)::int from mc.chunk_wanted where conn_id = 1), 3);
-- two connections want the same chunk: one request, the nearest distance wins
select mc.want_chunks(2, 'minecraft:overworld', array[9002], array[0], array[2]);
select t.eq('one request per chunk however many want it', (select count(*)::int from mc.chunk_request where cx = 9002), 1);
select t.eq('the priority is the smallest distance', (select prio from mc.chunk_request where cx = 9002), 2);
select t.eq('two wanted rows for that chunk', (select count(*)::int from mc.chunk_wanted where cx = 9002), 2);
select t.eq('generate_pending(2) creates the two nearest first (9001, 9002)', mc.generate_pending(2), 2);
select t.eq('...those two', (select array_agg(cx order by cx) from mc.chunk where cx >= 9000 and cz = 0), array[9001, 9002]);
select t.eq('...and only 9000 is still requested', (select array_agg(cx) from mc.chunk_request), array[9000]);
select t.is_true('a generated chunk has its packet cached', exists (select 1 from mc.chunk_cache where cx = 9001 and cz = 0 and version = 0));
select t.eq('generate_pending finishes the rest', mc.generate_pending(10), 1);
select t.eq('nothing left to do', mc.generate_pending(10), 0);
select t.eq('the queue is empty', (select count(*)::int from mc.chunk_request), 0);

-- nobody wants it any more: dropped without generating
truncate mc.chunk_request, mc.chunk_wanted;
select mc.want_chunks(1, 'minecraft:overworld', array[9100, 9101], array[0, 0], array[1, 2]);
delete from mc.chunk_wanted where cx = 9100;
select t.eq('an unwanted request is not generated', mc.generate_pending(10), 1);
select t.is_true('...9100 does not exist, 9101 does', not exists (select 1 from mc.chunk where cx = 9100) and exists (select 1 from mc.chunk where cx = 9101));
select t.eq('...and the dropped request is gone', (select count(*)::int from mc.chunk_request), 0);

-- pregeneration: generated although nobody waits
truncate mc.chunk_request, mc.chunk_wanted;
select t.eq('pregenerate (queued) records 9 requests', mc.pregenerate('minecraft:overworld', 9200, 9200, 1, false), 9);
select t.eq('...the centre first', (select cx || ',' || cz from mc.chunk_request order by prio, requested_at limit 1), '9200,9200');
select t.eq('pregeneration requests are generated without a waiting player', mc.generate_pending(100), 9);
select t.eq('pregenerate again requests nothing: the chunks exist', mc.pregenerate('minecraft:overworld', 9200, 9200, 1, false), 0);
select t.eq('pregenerate now creates the missing ones at once', mc.pregenerate('minecraft:overworld', 9200, 9200, 2, true), 16);

-- a generator that fails must not block the queue
create or replace function t.boom(p_dim text, p_cxs int[], p_czs int[]) returns int language plpgsql as $$ begin raise exception 'boom'; end $$;
insert into mc.generator (name, batch_fn) values ('test:fail', 't.boom(text,int[],int[])'::regprocedure);
insert into mc.dimension (name, generator) values ('dbcraft:bad', 'test:fail');
truncate mc.chunk_request, mc.chunk_wanted, mc.error_log;
select mc.want_chunks(1, 'dbcraft:bad', array[1], array[1], array[0]);
select mc.want_chunks(1, 'minecraft:overworld', array[9300], array[0], array[5]);
select t.eq('the good chunk is generated although a bad request exists', mc.generate_pending(10), 1);
select t.is_true('the failure was logged', exists (select 1 from mc.error_log where step = 'generate_pending' and message like '%boom%'));
select t.eq('the failing request is retried (attempts 1)', (select attempts from mc.chunk_request where dimension = 'dbcraft:bad'), 1);
select mc.generate_pending(10);
select mc.generate_pending(10);
select t.eq('...and dropped after 3 attempts', (select count(*)::int from mc.chunk_request), 0);
delete from mc.dimension where name = 'dbcraft:bad';
delete from mc.generator where name = 'test:fail';

-- the generator loop: runs until told to stop or out of time, generating what is requested
truncate mc.chunk_request, mc.chunk_wanted;
select mc.want_chunks(1, 'minecraft:overworld', array(select 9400 + g from generate_series(0, 49) g), array(select 0 from generate_series(0, 49) g), array(select g from generate_series(0, 49) g));
call mc.run_generator(16, 1, 1);
select t.eq('run_generator generated all 50 requested chunks', (select count(*)::int from mc.chunk where cx between 9400 and 9449 and cz = 0), 50);
select t.eq('...and left an empty queue', (select count(*)::int from mc.chunk_request), 0);
update mc.generator_control set stop = true;
call mc.run_generator(16, 1, 30);
select t.is_true('the stop flag ends the loop at once (this line is reached)', true);
update mc.generator_control set stop = false;

------------------------------------------------------------------------------------------------ part 2: through the connection layer
-- inline mode first: what a join sends, the reference for the async runs
select t.fresh();
select t.join_client(31, 'Alice');
select mc.server_tick();
select t.grab(31, 'inl', true);
select t.eq('inline: 49 chunks in the join tick', cardinality(t.chunk_coords('inl')), 49);
select t.eq('inline: nothing left wanted', (select count(*)::int from mc.chunk_wanted), 0);
select t.eq('inline: the first chunk is the player''s own', (t.chunk_coords('inl'))[1], '0,0');
create table t.inline_chunks as select proto.i32_read(body, 0) cx, proto.i32_read(body, 4) cz, body, idx from t.g_inl where name = 'minecraft:level_chunk_with_light';
create table t.inline_order as select cx || ',' || cz as c, row_number() over (order by idx) n from t.inline_chunks;

-- async: the same join
select t.fresh();
update mc.server_property set value = 'async' where key = 'dbcraft.chunk-generation';
select t.join_client(32, 'Alice');
select mc.server_tick();
select t.grab(32, 'q1', true);
select t.eq('async: the join tick sends no chunk', t.cnt_name('q1', 'minecraft:level_chunk_with_light'), 0);
select t.eq('async: ... and no empty batch either', t.cnt_name('q1', 'minecraft:chunk_batch_start'), 0);
select t.is_true('async: the rest of the join burst is there', t.cnt_name('q1', 'minecraft:login') = 1 and t.cnt_name('q1', 'minecraft:set_chunk_cache_center') = 1);
select t.eq('async: 49 chunks are requested', (select count(*)::int from mc.chunk_request), 49);
select t.eq('async: 49 chunks are wanted by the connection', (select count(*)::int from mc.chunk_wanted where conn_id = 32), 49);
select t.eq('async: nothing was generated by the tick', (select count(*)::int from mc.chunk where dimension = 'minecraft:overworld'), 0);
select mc.server_tick();
select t.grab(32, 'q1b');
select t.eq('async: more ticks without a generator still send nothing', t.cnt_name('q1b', 'minecraft:level_chunk_with_light'), 0);
select t.eq('async: and still generate nothing', (select count(*)::int from mc.chunk where dimension = 'minecraft:overworld'), 0);

select t.eq('the generator makes the 20 nearest chunks first', mc.generate_pending(20), 20);
select mc.server_tick();
select t.grab(32, 'q2');
select t.eq('next tick: those 20 are sent', cardinality(t.chunk_coords('q2')), 20);
select t.eq('...as one batch: start, 20 chunks, finished', t.names_of('q2'), array['chunk_batch_start'] || array_fill('level_chunk_with_light'::text, array[20]) || array['chunk_batch_finished']);
select t.eq('...the batch count says 20', (select val from proto.varint_read((select body from t.g_q2 where name = 'minecraft:chunk_batch_finished'), 0)), 20);
select t.eq('...they are the 20 nearest, in the inline order', t.chunk_coords('q2'), array(select c from t.inline_order where n <= 20 order by n));
select t.eq('29 chunks are still wanted', (select count(*)::int from mc.chunk_wanted where conn_id = 32), 29);
select t.eq('the generator makes the other 29', mc.generate_pending(100), 29);
select mc.server_tick();
select t.grab(32, 'q3');
select t.eq('next tick: the other 29', t.chunk_coords('q3'), array(select c from t.inline_order where n > 20 order by n));
select t.eq('every chunk was sent exactly once', (select count(distinct c)::int from (select unnest(t.chunk_coords('q2') || t.chunk_coords('q3')) c) q), 49);
select t.eq('the bytes are identical to what inline mode sent', (select count(*)::int from t.inline_chunks i
        where i.body = (select b.body from t.g_q2 b where b.name = 'minecraft:level_chunk_with_light' and proto.i32_read(b.body, 0) = i.cx and proto.i32_read(b.body, 4) = i.cz
                        union all select b.body from t.g_q3 b where b.name = 'minecraft:level_chunk_with_light' and proto.i32_read(b.body, 0) = i.cx and proto.i32_read(b.body, 4) = i.cz)), 49);
select t.eq('nothing is wanted or requested any more', (select count(*)::int from mc.chunk_wanted) + (select count(*)::int from mc.chunk_request), 0);
select mc.server_tick();
select t.grab(32, 'q4');
select t.eq('a further tick sends no chunk and no batch', t.cnt_name('q4', 'minecraft:level_chunk_with_light') + t.cnt_name('q4', 'minecraft:chunk_batch_start'), 0);

-- chunk streaming across a border, async (two steps: a jump of more than 10 blocks in one tick is refused, as vanilla does)
select t.feed_pkt(32, 'play', 'minecraft:client_tick_end');
select t.feed_pkt(32, 'play', 'minecraft:move_player_pos', proto.f64(8.5) || proto.f64(-60) || proto.f64(0.5) || proto.i8(1));
select mc.server_tick();
select t.take(32);
select t.feed_pkt(32, 'play', 'minecraft:client_tick_end');
select t.feed_pkt(32, 'play', 'minecraft:move_player_pos', proto.f64(16.5) || proto.f64(-60) || proto.f64(0.5) || proto.i8(1));
select mc.server_tick();
select t.grab(32, 'q5');
select t.eq('crossing: the centre and the 7 forgets are sent at once', t.names_of('q5'), array['set_chunk_cache_center'] || array_fill('forget_level_chunk'::text, array[7]));
select t.eq('crossing: the 7 new chunks are requested and wanted', (select count(*)::int from mc.chunk_request) * 10 + (select count(*)::int from mc.chunk_wanted), 77);
select t.eq('crossing: the tick generated none of them', (select count(*)::int from mc.chunk where dimension = 'minecraft:overworld' and cx = 4), 0);
select mc.generate_pending(100);
select mc.server_tick();
select t.grab(32, 'q6');
select t.eq('crossing: next tick the 7 chunks arrive as one batch, nearest first (z = 0 first)',
            (select array_agg(proto.i32_read(body, 4) order by idx) from t.g_q6 where name = 'minecraft:level_chunk_with_light'), array[0, -1, 1, -2, 2, -3, 3]);
select t.is_true('...all of the column x = 4', (select bool_and(proto.i32_read(body, 0) = 4) from t.g_q6 where name = 'minecraft:level_chunk_with_light'));
select t.eq('...inside one batch', t.cnt_name('q6', 'minecraft:chunk_batch_start') * 10 + t.cnt_name('q6', 'minecraft:chunk_batch_finished'), 11);

-- pacing: at most chunk-batch-max per connection per tick
select t.fresh();
update mc.server_property set value = 'async' where key = 'dbcraft.chunk-generation';
update mc.server_property set value = '10' where key = 'dbcraft.chunk-batch-max';
select t.join_client(33, 'Alice');
select mc.server_tick();
select t.take(33);
select mc.generate_pending(100);
select mc.server_tick();
select t.grab(33, 'p1');
select t.eq('pacing: 10 chunks in the first tick', cardinality(t.chunk_coords('p1')), 10);
select mc.server_tick();
select t.grab(33, 'p2');
select t.eq('pacing: the next 10 in the second', cardinality(t.chunk_coords('p2')), 10);
select t.is_true('pacing: nearest first across ticks (no chunk of tick 2 is nearer than a chunk of tick 1)',
    (select max(power(split_part(c, ',', 1)::int, 2) + power(split_part(c, ',', 2)::int, 2)) from unnest(t.chunk_coords('p1')) c)
    <= (select min(power(split_part(c, ',', 1)::int, 2) + power(split_part(c, ',', 2)::int, 2)) from unnest(t.chunk_coords('p2')) c));
select mc.server_tick();
select mc.server_tick();
select mc.server_tick();
select t.eq('pacing: after enough ticks everything has been sent', (select count(*)::int from mc.chunk_wanted), 0);

-- a player who disconnects before the chunks are ready
select t.fresh();
update mc.server_property set value = 'async' where key = 'dbcraft.chunk-generation';
select t.join_client(34, 'Alice');
select mc.server_tick();
select t.take(34);
select t.eq('before: 49 wanted', (select count(*)::int from mc.chunk_wanted where conn_id = 34), 49);
delete from net.conn where conn_id = 34;
select mc.server_tick();
select t.eq('the wanted list of a connection that is gone is dropped', (select count(*)::int from mc.chunk_wanted), 0);
select t.eq('...and its requests are dropped without generating', mc.generate_pending(100), 0);
select t.eq('...leaving an empty queue', (select count(*)::int from mc.chunk_request), 0);

-- a player whose view moved away: the old wanted chunks are no longer wanted
select t.fresh();
update mc.server_property set value = 'async' where key = 'dbcraft.chunk-generation';
select t.join_client(35, 'Alice');
select mc.server_tick();
select t.take(35);
update mc.player set chunk_x = 500, chunk_z = 500 where conn_id = 35;       -- a teleport far away before any chunk arrived
select mc.server_tick();
select t.eq('chunks around the old position are not wanted any more', (select count(*)::int from mc.chunk_wanted where conn_id = 35 and cx < 400), 0);
select t.eq('...the square around the new position is wanted instead', (select count(*)::int from mc.chunk_wanted where conn_id = 35 and cx between 497 and 503 and cz between 497 and 503), 49);
select t.eq('...and the old requests are dropped by the generator without generating them', mc.generate_pending(1000), 49);
select t.is_true('...only the new area exists', not exists (select 1 from mc.chunk where dimension = 'minecraft:overworld' and cx < 400) and exists (select 1 from mc.chunk where cx = 500 and cz = 500));

-- put the settings back for whatever runs next
select t.fresh();
