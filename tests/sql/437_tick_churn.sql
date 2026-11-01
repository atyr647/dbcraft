-- No relation files created or deleted by the tick (sql/437 and the files it names).  The two rewritten functions are compared with their previous bodies, kept in
-- sql/437 as mc.deliver_ready_chunks_general and mc.broadcast_block_events_general: random states are built, the queues are snapshotted, the original runs, the
-- queues are restored, the rewrite runs, and the bytes in every connection's queue, the rows left in the queues and the return values are compared.
\ir ../../sql/430_chunk_queue.sql
\ir ../../sql/430_tick_perf.sql
\ir ../../sql/432_tick_perf_world.sql
\ir ../../sql/436_stream_chunks_merge.sql
\ir ../../sql/437_tick_churn.sql
\! python3 tools/load_world_ref.py
update mc.server_property set value = '2' where key in ('view-distance', 'simulation-distance');
select mc.generate_flat_area('minecraft:overworld', -3, -3, 12, 12) as generated \gset
select count(mc.chunk_packet('minecraft:overworld', cx, cz)) as cached from generate_series(-3, 12) cx, generate_series(-3, 12) cz \gset

------------------------------------------------------------------------------------------------ mc.deliver_ready_chunks
create or replace function t.dl_build(p_seed float8, p_n int, p_async boolean, p_cap int) returns void language plpgsql as $$
begin
  perform setseed(p_seed);
  truncate net.conn, mc.play_out, mc.chunk_wanted, net.outbox;
  update mc.server_property set value = case when p_async then 'async' else 'inline' end where key = 'dbcraft.chunk-generation';
  update mc.server_property set value = p_cap::text where key = 'dbcraft.chunk-batch-max';
  -- some connections are not in play, some are closing, some have no view yet; wanted chunks of connections that do not exist at all (the +3) and chunks
  -- outside the client's square must be dropped; chunks 13 and beyond do not exist (they stay wanted)
  insert into net.conn (conn_id, state, compression, closing, view_cx, view_cz)
  select i, case when i % 7 = 0 then 'configuration' else 'play' end, -1, i % 11 = 0, case when i % 13 = 0 then null else (random() * 6)::int end, (random() * 6)::int from generate_series(1, p_n) i;
  insert into mc.chunk_wanted (conn_id, dimension, cx, cz, dist)
  select distinct on (c, x, z) c, 'minecraft:overworld', x, z, (random() * 6)::int          -- few distinct distances: the tie-break by cx, cz is exercised
    from (select (1 + random() * (p_n + 2))::int as c, (random() * 18 - 4)::int as x, (random() * 18 - 4)::int as z from generate_series(1, p_n * 30)) g;
end $$;

create or replace function t.dl_digest(p_n int) returns jsonb language sql as $$
  select jsonb_build_object(
    'ret',    p_n,
    'out',    (select coalesce(string_agg(conn_id || ':' || md5(d), ',' order by conn_id), '') from (select conn_id, string_agg(encode(data, 'hex'), '|' order by seq) d from mc.play_out group by conn_id) q),
    'frames', (select count(*) from mc.play_out),
    'wanted', (select coalesce(string_agg(conn_id || '/' || cx || '/' || cz || '/' || dist, ',' order by conn_id, cx, cz), '') from mc.chunk_wanted)) $$;

create or replace function t.dl_compare(p_seed float8, p_n int, p_async boolean, p_cap int) returns text language plpgsql as $$
declare na int; nb int; da jsonb; db jsonb; diff text;
begin
  perform t.dl_build(p_seed, p_n, p_async, p_cap);
  drop table if exists t_dl_wanted; create table t_dl_wanted as select * from mc.chunk_wanted;
  na := mc.deliver_ready_chunks_general(); da := t.dl_digest(na);
  truncate mc.play_out, mc.chunk_wanted; insert into mc.chunk_wanted select * from t_dl_wanted;
  nb := mc.deliver_ready_chunks(); db := t.dl_digest(nb);
  if (da->>'frames')::int = 0 and na > 0 then return 'scenario sent nothing'; end if;
  select string_agg(a.key, ',') into diff from jsonb_each_text(da) a join jsonb_each_text(db) b using (key) where a.value is distinct from b.value;
  return coalesce('differs in: ' || diff, 'same');
end $$;

select t.eq('chunk delivery, inline: seed ' || s || ', ' || n || ' connections', t.dl_compare(s / 10.0, n, false, 64), 'same') from generate_series(1, 4) s, unnest(array[10, 40]) n;
select t.eq('chunk delivery, async, cap ' || cap || ': seed ' || s, t.dl_compare(s / 10.0, 30, true, cap), 'same') from generate_series(1, 4) s, unnest(array[1, 3, 8]) cap;
truncate mc.chunk_wanted;
select t.eq('chunk delivery: nothing wanted returns 0', mc.deliver_ready_chunks(), 0);
select t.is_true('chunk delivery: scenarios send chunks, drop stale wanted rows and keep the rest',
  (select count(*) from mc.play_out) > 0 or (select count(*) from mc.chunk_wanted) > 0);
update mc.server_property set value = 'inline' where key = 'dbcraft.chunk-generation';

------------------------------------------------------------------------------------------------ mc.broadcast_block_events
-- the id of a framed packet
create or replace function t.fid(p_data bytea) returns int language sql immutable as $$ select (proto.varint_read(p_data, (proto.varint_read(p_data, 0)).nxt)).val $$;
create or replace function t.bb_build(p_seed float8, p_n int, p_secs boolean, p_acks boolean) returns void language plpgsql as $$
declare blocks text[] := array['minecraft:stone', 'minecraft:air', 'minecraft:gold_block', 'minecraft:dirt', 'minecraft:air'];
        i int; x int; y int; z int;
begin
  perform setseed(p_seed);
  truncate net.conn, mc.play_out, mc.block_event, mc.pending_ack, mc.block_actor, net.outbox;
  insert into net.conn (conn_id, state, compression, closing, view_cx, view_cz)
  select g.cid, case when g.cid % 8 = 0 then 'login' else 'play' end, -1, g.cid % 9 = 0, case when g.cid % 10 = 0 then null else (random() * 4)::int end, (random() * 4)::int from generate_series(1, 12) as g(cid);
  -- the edits of earlier scenarios wear the world away: put the ground back (stone below y -60, air above) and forget the events of doing so
  perform mc.fill('minecraft:overworld', 0, -64, 0, 79, -61, 79, 'minecraft:stone');
  truncate mc.block_event, mc.block_actor, mc.pending_ack;
  for i in 1 .. p_n loop
    x := (random() * 70)::int; y := -64 + (random() * 4)::int; z := (random() * 70)::int;       -- bedrock, dirt, grass and the air above the flat world: real breaks and places
    perform mc.set_block('minecraft:overworld', x, y, z, blocks[1 + (random() * 4)::int]);
    if random() < 0.35 then perform mc.set_block('minecraft:overworld', x, y, z, blocks[1 + (random() * 4)::int]); end if;       -- several edits of one position (some net zero)
    if random() < 0.15 then perform mc.set_block('minecraft:overworld', x, y, z, 'minecraft:air'); end if;
    if random() < 0.5 then insert into mc.block_actor values ('minecraft:overworld', x, y, z, 1 + (random() * 11)::int); end if;
  end loop;
  if p_secs then            -- blocks in sections that did not exist: a section event, the chunk is sent again
    for i in 1 .. 3 loop
      x := (random() * 4)::int * 16; z := (random() * 4)::int * 16;
      perform mc.fill('minecraft:overworld', x, 96 + i * 16, z, x + 15, 96 + i * 16 + 15, z + 15, 'minecraft:glass');          -- a whole section: a section event
    end loop;
  end if;
  if p_acks then insert into mc.pending_ack (conn_id, sequence) select 1 + (random() * 11)::int, (random() * 1000)::int from generate_series(1, 14); end if;
end $$;

-- The chunk frames of a section change are compared as a set per connection: the temp-table version sent them in whatever order the planner's DISTINCT produced, the
-- rewrite sends them in the order the changes were recorded.  Everything else, including the position of the chunk frames among the others, is compared exactly.
create or replace function t.bb_digest(p_n int) returns jsonb language sql as $$
  select jsonb_build_object(
    'ret',    p_n,
    'out',    (select coalesce(string_agg(conn_id || ':' || md5(d), ',' order by conn_id), '')
                 from (select conn_id, string_agg(case when t.fid(data) = mc.chunk_packet_id() then 'CHUNK' else encode(data, 'hex') end, '|' order by seq) d from mc.play_out group by conn_id) q),
    'chunks', (select coalesce(string_agg(conn_id || ':' || md5(d), ',' order by conn_id), '')
                 from (select conn_id, string_agg(encode(data, 'hex'), '|' order by data) d from mc.play_out where t.fid(data) = mc.chunk_packet_id() group by conn_id) q),
    'frames', (select count(*) from mc.play_out),
    'left',   jsonb_build_array((select count(*) from mc.block_event), (select count(*) from mc.pending_ack), (select count(*) from mc.block_actor))) $$;

create or replace function t.bb_compare(p_seed float8, p_n int, p_secs boolean, p_acks boolean) returns text language plpgsql as $$
declare na int; nb int; da jsonb; db jsonb; diff text;
begin
  perform t.bb_build(p_seed, p_n, p_secs, p_acks);
  drop table if exists t_bb_event, t_bb_ack, t_bb_actor;
  create table t_bb_event as select * from mc.block_event; create table t_bb_ack as select * from mc.pending_ack; create table t_bb_actor as select * from mc.block_actor;
  na := mc.broadcast_block_events_general(); da := t.bb_digest(na);
  truncate mc.play_out, mc.block_event, mc.pending_ack, mc.block_actor;
  insert into mc.block_event overriding system value select * from t_bb_event; insert into mc.pending_ack overriding system value select * from t_bb_ack; insert into mc.block_actor select * from t_bb_actor;
  nb := mc.broadcast_block_events(); db := t.bb_digest(nb);
  if (da->>'frames')::int = 0 and (p_n > 0 or p_acks) then return 'scenario sent nothing'; end if;
  select string_agg(a.key, ',') into diff from jsonb_each_text(da) a join jsonb_each_text(db) b using (key) where a.value is distinct from b.value;
  return coalesce('differs in: ' || diff, 'same');
end $$;

select t.eq('block events: seed ' || s || ', ' || n || ' edits, acks', t.bb_compare(s / 10.0, n, false, true), 'same') from generate_series(1, 5) s, unnest(array[3, 12, 40]) n;
select t.eq('block events: seed ' || s || ', edits and a new section', t.bb_compare(s / 10.0, 10, true, true), 'same') from generate_series(1, 4) s;
select t.eq('block events: seed ' || s || ', only acknowledgements', t.bb_compare(s / 10.0, 0, false, true), 'same') from generate_series(1, 3) s;
truncate mc.play_out, mc.block_event, mc.pending_ack, mc.block_actor;
select t.eq('block events: nothing recorded sends nothing', (select mc.broadcast_block_events() + (select count(*) from mc.play_out)::int), 0);

-- the queues are consumed with DELETE, so a second call finds them empty and sends nothing more
select t.bb_build(0.5, 12, true, true);
select mc.broadcast_block_events() as first_call \gset
select count(*) as frames_after_first from mc.play_out \gset
select t.is_true('block events: the first call sent frames', :frames_after_first > 0);
-- the scenarios cover every kind of frame the function writes
select t.is_true('block events: a scenario writes ' || k.name || ' frames', exists (select 1 from mc.play_out where t.fid(data) = k.id))
  from (values ('block_update', mc.pid('block_update')), ('level_event', mc.pid('level_event')), ('block_changed_ack', mc.pid('block_changed_ack')), ('level_chunk_with_light', mc.chunk_packet_id())) k(name, id);
select t.eq('block events: a second call returns 0', mc.broadcast_block_events(), 0);
select t.eq('block events: a second call sends nothing', (select count(*) from mc.play_out), :frames_after_first::bigint);
select t.eq('block events: queues empty afterwards', (select count(*) from mc.block_event) + (select count(*) from mc.pending_ack) + (select count(*) from mc.block_actor), 0::bigint);

------------------------------------------------------------------------------------------------ mc.ensure_chunk_current
create or replace function t.xmax_of(p_cx int, p_cz int) returns text language sql as $$ select xmax::text from mc.chunk where dimension = 'minecraft:overworld' and cx = p_cx and cz = p_cz $$;
-- the block scenarios left chunks dirty: settle them first
select count(mc.ensure_chunk_current('minecraft:overworld', cx, cz)) as settled from generate_series(0, 4) cx, generate_series(0, 4) cz \gset
select t.xmax_of(1, 1) as xmax_before \gset
select t.eq('ensure_chunk_current: a current chunk is left alone', mc.ensure_chunk_current('minecraft:overworld', 1, 1), false);
select t.eq('ensure_chunk_current: and is not row-locked (the lock would stamp a new xmax)', t.xmax_of(1, 1), :'xmax_before');
select t.eq('ensure_chunk_current: a chunk that does not exist', mc.ensure_chunk_current('minecraft:overworld', 900, 900), false);
select mc.set_block('minecraft:overworld', 1 * 16 + 3, -50, 1 * 16 + 5, 'minecraft:stone');      -- (a state that differs from what an earlier run of this file left)
select mc.ensure_chunk_current('minecraft:overworld', 1, 1);
select mc.set_block('minecraft:overworld', 1 * 16 + 3, -50, 1 * 16 + 5, 'minecraft:gold_block');
select t.is_true('ensure_chunk_current: an edit makes the chunk dirty', (select dirty or hm_dirty from mc.chunk where dimension = 'minecraft:overworld' and cx = 1 and cz = 1));
select t.eq('ensure_chunk_current: a dirty chunk is brought up to date', mc.ensure_chunk_current('minecraft:overworld', 1, 1), true);
select t.is_true('ensure_chunk_current: and is clean afterwards', (select not dirty and not hm_dirty and hm_world_surface is not null from mc.chunk where dimension = 'minecraft:overworld' and cx = 1 and cz = 1));
select t.eq('ensure_chunk_current: a second call has nothing to do', mc.ensure_chunk_current('minecraft:overworld', 1, 1), false);
update mc.chunk set hm_world_surface = null where dimension = 'minecraft:overworld' and cx = 2 and cz = 2;
select t.eq('ensure_chunk_current: a chunk without heightmaps is computed', mc.ensure_chunk_current('minecraft:overworld', 2, 2), true);

------------------------------------------------------------------------------------------------ the once-a-second truncates of the tick's own queues
create or replace function t.relfiles() returns text language sql as $$
  select string_agg(oid::regclass || '=' || relfilenode, ',' order by oid::regclass::text) from pg_class where oid in ('mc.play_in_work'::regclass, 'net.batch'::regclass, 'mc.play_out'::regclass) $$;
truncate net.conn, net.inbox, net.outbox, mc.play_in, mc.play_in_work, net.batch, mc.play_out, mc.chunk_wanted, mc.block_event, mc.pending_ack, mc.block_actor, mc.kick;
delete from mc.player;
delete from mc.tick_log;
update mc.game_state set game_time = 19;
select t.relfiles() as before_idle \gset
select mc.server_tick() is not null as ticked \gset
select t.eq('housekeeping tick on an idle server: no queue file is replaced', t.relfiles(), :'before_idle');
-- a queue that was written is truncated: a row in each (the tick's own queues are emptied by the tick, so only the file of the truncated table changes)
delete from mc.tick_log;
update mc.game_state set game_time = 19;
insert into mc.play_in_work (seq, conn_id, packet_id, body) values (1, 999, 0, '\x00');
insert into net.batch (conn_id, seq, payload) values (999, 1, '\x00');
insert into mc.play_out (conn_id, data) values (999, '\x00');
select t.relfiles() as before_busy \gset
select mc.server_tick() is not null as ticked2 \gset
select t.is_true('housekeeping tick after writes: the queues were truncated (new files)', t.relfiles() <> :'before_busy');
select t.eq('housekeeping tick after writes: the queues are empty', (select count(*) from mc.play_in_work) + (select count(*) from net.batch) + (select count(*) from mc.play_out), 0::bigint);

------------------------------------------------------------------------------------------------ net.process_fast: keep-alive answers and teleport confirmations in bulk
-- A random inbox (well-formed and malformed keep-alive answers, matching and non-matching teleport confirmations, moves, pongs, packets nobody expects) on
-- connections in different states goes through net.process_fast_general (the previous body: every protocol-level packet through net.handle) and through the rewrite
-- from the same state; the connection rows, the game's work queue, what reached net.play_inbox and the bytes sent back (a malformed packet closes its connection
-- with a disconnect) are compared.  Both runs happen in one transaction so now() is the same.
create or replace function t.pf_build(p_seed float8, p_n int, p_clean boolean) returns void language plpgsql as $$
declare i_ka int := net.pkt('play', 'serverbound', 'minecraft:keep_alive'); i_tp int := net.pkt('play', 'serverbound', 'minecraft:accept_teleportation');
        i_mv int := net.pkt('play', 'serverbound', 'minecraft:move_player_pos'); i_pong int := net.pkt('play', 'serverbound', 'minecraft:pong');
        i_cb int := net.pkt('play', 'serverbound', 'minecraft:chunk_batch_received'); i_chat int := net.pkt('play', 'serverbound', 'minecraft:chat');
begin
  perform setseed(p_seed);
  truncate net.conn, net.inbox, net.outbox, net.batch, net.play_inbox, mc.play_in, mc.play_in_work;
  insert into net.conn (conn_id, state, closing, compression, teleport_id, teleport_ok, keepalive_id, keepalive_sent)
  select c, case when c % 9 = 0 then 'configuration' else 'play' end, c % 11 = 0, -1, case when c = 1 then 200 else (random() * 3)::int end, random() < 0.3,
         case when random() < 0.8 then (random() * 1e12)::bigint end, now() - ((random() * 5000)::int * interval '1 millisecond')
    from generate_series(1, p_n) c;
  insert into net.inbox (conn_id, payload)
  select r.conn_id, case r.kind
           when 0 then proto.varint(i_ka) || proto.i64(coalesce(r.keepalive_id, 5))
           when 1 then proto.varint(i_ka) || proto.i64(coalesce(r.keepalive_id, 5))
           when 2 then proto.varint(i_ka) || proto.i64((random() * 1e12)::bigint)
           when 3 then proto.varint(i_ka) || '\x01020304'::bytea
           when 4 then proto.varint(i_ka) || proto.i64(coalesce(r.keepalive_id, 5)) || '\xffff'::bytea
           when 5 then proto.varint(i_tp) || proto.varint(r.teleport_id) || proto.f64(1.5) || proto.f64(2.5) || proto.f64(3.5) || proto.f32(1) || proto.f32(2)
           when 6 then proto.varint(i_tp) || proto.varint(r.teleport_id) || proto.f64(1.5) || proto.f64(2.5) || proto.f64(3.5) || proto.f32(1) || proto.f32(2)
           when 7 then proto.varint(i_tp) || proto.varint(r.teleport_id + 1)
           when 8 then proto.varint(i_tp) || proto.varint(200)
           when 9 then proto.varint(i_tp)
           when 10 then proto.varint(i_mv) || decode(repeat('00', 25), 'hex')
           when 11 then proto.varint(i_pong) || '\x00000000'::bytea
           when 12 then proto.varint(i_cb) || proto.f32(1.5)
           when 13 then proto.varint(i_chat) || '\x00'::bytea
           else proto.varint(250) || '\x00'::bytea end
    from (select c.conn_id, c.keepalive_id, c.teleport_id,
                   case when p_clean then (array[0, 1, 2, 5, 6, 7, 10, 13, 10, 13])[1 + (random() * 9.99)::int] else (random() * 14.99)::int end as kind       -- (random() in the select list: one draw per row; p_clean: nothing that needs the ordered path)
            from net.conn c cross join lateral generate_series(1, 1 + (random() * 4)::int + 0 * c.conn_id) k) r
   order by random();
end $$;

create or replace function t.pf_digest(p_n int) returns jsonb language sql as $$
  select jsonb_build_object(
    'n',     p_n,
    'conn',  (select coalesce(string_agg(md5(to_jsonb(c)::text), ',' order by conn_id), '') from net.conn c),
    'work',  (select coalesce(string_agg(conn_id || '/' || seq || '/' || packet_id || '/' || encode(body, 'hex'), ',' order by seq), '') from mc.play_in_work),
    -- (net.batch itself is not compared: the rewrite no longer routes the well-formed keep-alive answers through it)
    'inbox2', (select coalesce(string_agg(conn_id || '/' || packet_id || '/' || encode(body, 'hex'), ',' order by seq), '') from net.play_inbox),
    'out',   (select coalesce(string_agg(conn_id || ':' || md5(d), ',' order by conn_id), '') from (select conn_id, string_agg(encode(data, 'hex'), '|' order by seq) d from net.outbox group by conn_id) q)) $$;

create or replace function t.pf_compare(p_seed float8, p_n int, p_clean boolean) returns text language plpgsql as $$
declare na int; nb int; da jsonb; db jsonb; diff text;
begin
  perform t.pf_build(p_seed, p_n, p_clean);
  drop table if exists t_pf_conn, t_pf_inbox; create table t_pf_conn as select * from net.conn; create table t_pf_inbox as select * from net.inbox;
  na := net.process_fast_general(); da := t.pf_digest(na);
  truncate net.conn, net.inbox, net.outbox, net.batch, net.play_inbox, mc.play_in_work;
  insert into net.conn select * from t_pf_conn; insert into net.inbox select * from t_pf_inbox;
  nb := net.process_fast(); db := t.pf_digest(nb);
  select string_agg(a.key, ',') into diff from jsonb_each_text(da) a join jsonb_each_text(db) b using (key) where a.value is distinct from b.value;
  return coalesce('differs in: ' || diff, 'same');
end $$;
select t.eq('process_fast: seed ' || s || ', ' || n || ' connections', t.pf_compare(s / 10.0, n, false), 'same') from generate_series(1, 6) s, unnest(array[6, 30, 120]) n;
select t.eq('process_fast, only answers and game packets: seed ' || s || ', ' || n || ' connections', t.pf_compare(s / 10.0, n, true), 'same') from generate_series(1, 6) s, unnest(array[6, 30, 120]) n;
select t.is_true('process_fast scenarios: answered keep-alives and confirmed teleports happen', (
  select count(*) filter (where keepalive_id is null) > 0 and count(*) filter (where teleport_ok) > 0 from net.conn));

------------------------------------------------------------------------------------------------ no scratch tables on the tick's path
-- A function that creates a temp table (even one that is emptied at commit) creates relation files in every transaction that uses it and invalidates its own plans.
-- The functions the tick runs every tick must not; the *_general copies and the fallback paths named in docs/PERF-TICK.md are the documented exceptions.
select t.is_true('no scratch table in ' || p.oid::regprocedure, p.prosrc !~* 'create\s+(local\s+)?temp(orary)?\s+table' and p.prosrc !~* '\manalyze\M\s+_')
  from pg_proc p where p.pronamespace in ('mc'::regnamespace, 'net'::regnamespace)
   and p.oid::regprocedure::text in ('mc.server_tick()', 'mc.tick_core()', 'mc.tick()', 'net.process_fast()', 'mc.apply_player_moves(bigint)', 'mc.refresh_visibility()', 'net.stream_chunks()',
                                      'mc.deliver_ready_chunks()', 'mc.want_chunks(integer,text,integer[],integer[],integer[],boolean)', 'mc.apply_block_actions(bigint)', 'mc.broadcast_block_events()',
                                      'mc.apply_misc_input(bigint)', 'mc.apply_chat(bigint)', 'mc.keepalive_due(bigint)');
