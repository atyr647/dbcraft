-- Block change packets for several positions of one section (sql/850, mc.broadcast_block_events in sql/432).
-- Layout and rules were read from the 26.3 classes and compared byte for byte against a real vanilla server by tests/e2e/fill_probe.py + compare_fill.py (134 packets,
-- 133,921 entries identical); this file pins the same rules inside the database:
--   * mc.shortset_order against vectors produced by running the real fastutil 8.5.18 ShortOpenHashSet (tests/bench/world/set_order.sh regenerates them),
--   * per section and tick: one changed position -> block_update, two or more -> section_blocks_update, a position that changed and changed back still counts,
--     a fill queues one 'cells' event per section and never the per-block break effect, sections nobody can see are not encoded, events of the legacy 'section' kind still
--     re-send the chunk, the queue is empty afterwards.
-- The decoder below is written separately from the encoder (it reads the wire bytes).
\! python3 tools/load_world_ref.py

------------------------------------------------------------------------------------------------ the set order against the real class
-- md5 of the comma-separated iteration order of fastutil 8.5.18's ShortOpenHashSet after adding the inputs in this order (run with `java -cp fastutil.jar SetOrder`)
create temp table vec (name text, input int[], md5 text);
insert into vec values
 ('a whole section in /fill order (4096)', mc.cells_positions(decode(repeat('ff', 512), 'hex')), '2e598a27bd7b46aeb94b68b4ed74d025'),
 ('4 x 3 x 2 box in /fill order (24, the last size before the first rehash)', array(select (x << 8) | (z << 4) | y from generate_series(0, 1) z, generate_series(0, 2) y, generate_series(0, 3) x order by z, y, x), '54a6a3781bdc0222dc06517a393178d7'),
 ('25 distinct (the first rehash)', array(select (i * 37) % 4096 from generate_series(0, 24) i), '44bfdcd86f6c5b25d78847d27c0997bf'),
 ('49 distinct', array(select (i * 37) % 4096 from generate_series(0, 48) i), '5cf6692be2bee67dadd81d3e038fa3e5'),
 ('97 distinct', array(select (i * 37) % 4096 from generate_series(0, 96) i), 'becb9d025351fdaacac37512d35cbad5'),
 ('193 distinct', array(select (i * 37) % 4096 from generate_series(0, 192) i), 'ce1b7b67e817689289b6455269cc62bb'),
 ('385 distinct', array(select (i * 37) % 4096 from generate_series(0, 384) i), '561a18dded950c70766cf1e85420257a'),
 ('3000 distinct', array(select (i * 2749 + 17) % 4096 from generate_series(0, 2999) i), '79f5bc554598511bf52fb767cd0564e7'),
 ('5001 with duplicates', array(select (i * i * 7 + i) % 4096 from generate_series(0, 5000) i), 'bda7a9378009b63e9b2bd63d7ea539ba'),
 ('0 .. 99 (key 0, the null key, comes first)', array(select i from generate_series(0, 99) i), '1089166a37f9e037d94b7cf14b12a3b4'),
 ('two positions', array[4, 260], '51365a3eb3de460be910461083374c4b'),
 ('one position repeated', array[7, 7, 7], '8f14e45fceea167a5a36dedd4bea2543');
select t.eq('shortset_order: ' || name, md5(array_to_string(mc.shortset_order(input), ',')), md5) from vec order by name;

------------------------------------------------------------------------------------------------ the decoder (reads wire bytes)
create or replace function t.vl(b bytea, o int, out v bigint, out nxt int) language plpgsql immutable as $$
declare s int := 0; c int;
begin
  v := 0;
  loop
    c := get_byte(b, o); o := o + 1;
    v := v | ((c & 127)::bigint << s); s := s + 7;
    exit when c < 128;
  end loop;
  nxt := o;
end $$;
-- a framed packet: packet id, then for section_blocks_update (cx, sy, cz, entries[] as state << 12 | pos); for block_update (pos x, y, z in entries as one entry (state << 12 | 0))
create or replace function t.dec(p_frame bytea) returns table (kind text, cx int, sy int, cz int, n int, entries bigint[]) language plpgsql immutable as $$
declare o int; pid int; v bigint; cnt int; i int; es bigint[] := '{}'; sec bigint; px int; py int; pz int; st bigint;
begin
  select (t.vl(p_frame, 0)).nxt into o;
  select (t.vl(p_frame, o)).v, (t.vl(p_frame, o)).nxt into v, o; pid := v::int;
  if pid = mc.pid('section_blocks_update') then
    sec := proto.i64_read(p_frame, o); o := o + 8;
    select (t.vl(p_frame, o)).v, (t.vl(p_frame, o)).nxt into v, o; cnt := v::int;
    for i in 1 .. cnt loop
      select (t.vl(p_frame, o)).v, (t.vl(p_frame, o)).nxt into v, o; es := es || v;
    end loop;
    if o <> octet_length(p_frame) then raise exception 'trailing bytes in section_blocks_update'; end if;
    -- SectionPos: x in bits 42.., z in bits 20..41, y in bits 0..19 (all signed)
    return query select 'sbu', ((sec >> 42) << 42 >> 42)::int, ((sec << 44) >> 44)::int, (((sec >> 20) & 4194303) << 42 >> 42)::int, cnt, es;
  elsif pid = mc.pid('block_update') then
    select * into px, py, pz from proto.position_read(p_frame, o);
    o := o + 8;
    select (t.vl(p_frame, o)).v into v;
    return query select 'bu', px, py, pz, 1, array[v];
  else
    return query select 'other' || pid, null::int, null::int, null::int, null::int, null::bigint[];
  end if;
end $$;

create or replace function t.fid_of(p_data bytea) returns int language sql immutable as $$ select (proto.varint_read(p_data, (proto.varint_read(p_data, 0)).nxt)).val $$;

------------------------------------------------------------------------------------------------ the world and the connections
-- (the chunks (0..2, 0..2) around the origin, three connections: 1 and 2 see chunk (1, 1); 3 sits far away)
select mc.generate_flat_area('minecraft:overworld', -1, -1, 3, 3);
create or replace function t.world_reset() returns void language plpgsql as $$
begin
  truncate net.conn, mc.play_out, mc.block_event, mc.pending_ack, mc.block_actor;
  insert into net.conn (conn_id, state, compression, closing, view_cx, view_cz) values (1, 'play', -1, false, 1, 1), (2, 'play', -1, false, 0, 0), (3, 'play', -1, false, 60, 60);
  perform mc.fill('minecraft:overworld', -16, -60, -16, 63, 60, 63, 'minecraft:air');
  truncate mc.block_event, mc.play_out;
end $$;
create or replace function t.out(p_conn int) returns table (kind text, cx int, sy int, cz int, n int, entries bigint[]) language sql as $$
  select d.* from mc.play_out o, lateral t.dec(o.data) d where o.conn_id = p_conn order by o.seq $$;
select t.world_reset();

-- 1: one position: block_update, to the connections that see the chunk
select mc.set_block('minecraft:overworld', 5, -60, 5, 'minecraft:stone');
select t.eq('one changed position: broadcast returns 1', mc.broadcast_block_events(), 1);
select t.eq('...one block_update to connection 1', (select array_agg(kind) from t.out(1)), array['bu']);
select t.eq('...at the position, with the state', (select (cx, sy, cz, entries[1])::text from t.out(1)), '(5,-60,5,1)');
select t.eq('...and to connection 2 (it sees chunk (1, 1) too)', (select count(*)::int from t.out(2)), 1);
select t.eq('...and not to the far connection 3', (select count(*)::int from t.out(3)), 0);
select t.eq('...the queue is empty', (select count(*)::int from mc.block_event), 0);

-- 2: two positions in one section: ONE section_blocks_update, entries state << 12 | (x << 8 | z << 4 | y), in the set's iteration order
select t.world_reset();
select mc.set_block('minecraft:overworld', 0, -60, 0, 'minecraft:stone');
select mc.set_block('minecraft:overworld', 1, -60, 0, 'minecraft:gold_block');
select t.eq('two positions: broadcast returns 2', mc.broadcast_block_events(), 2);
select t.eq('...one packet of kind section_blocks_update', (select array_agg(kind) from t.out(1)), array['sbu']);
select t.eq('...section (0, -4, 0), 2 entries', (select (cx, sy, cz, n)::text from t.out(1)), '(0,-4,0,2)');
select t.eq('...the entries: (state id << 12) | (x << 8 | z << 4 | y), y = -60 & 15 = 4, in set order',
            (select entries from t.out(1)),
            (select array_agg(((case when p = 4 then mc.state_id('minecraft:stone') else mc.state_id('minecraft:gold_block') end)::bigint << 12) | p order by o)
               from unnest(mc.shortset_order(array[4, 260])) with ordinality u(p, o)));

-- 3: a position that changes and changes back still counts (vanilla's set keeps it): one block_update with the state it has now
select t.world_reset();
select mc.set_block('minecraft:overworld', 9, -60, 9, 'minecraft:stone');
select mc.set_block('minecraft:overworld', 9, -60, 9, 'minecraft:air');
select t.eq('changed and changed back: broadcast returns 1', mc.broadcast_block_events(), 1);
select t.eq('...a block_update with the current state (air)', (select (kind, cx, sy, cz, entries[1])::text from t.out(1)), '(bu,9,-60,9,0)');
-- ...while the break effect goes by the NET change (none here)
select t.eq('...and no break effect', (select count(*)::int from mc.play_out where conn_id = 1), 1);

-- 4: a fill: one 'cells' event per section, one packet per section, the set of positions is the box
select t.world_reset();
select mc.fill('minecraft:overworld', 2, -60, 3, 5, -57, 6, 'minecraft:stone');
select t.eq('a fill queues one cells event', (select count(*)::int from mc.block_event where kind = 'cells'), 1);
select t.eq('...and no per-block events', (select count(*)::int from mc.block_event where kind = 'block'), 0);
select t.eq('...of 512 bytes with 64 bits set', (select (octet_length(cells), (select count(*) from generate_series(0, 4095) i where get_bit(cells, i) = 1))::text from mc.block_event), '(512,64)');
select t.eq('...the broadcast returns 64', mc.broadcast_block_events(), 64);
select t.eq('...one section_blocks_update with 64 entries', (select (kind, n)::text from t.out(1)), '(sbu,64)');
select t.eq('...whose positions are exactly the box',
            (select array_agg((e & 4095)::int order by e & 4095) from t.out(1), unnest(entries) e),
            (select array_agg((x << 8) | (z << 4) | (y & 15) order by (x << 8) | (z << 4) | (y & 15)) from generate_series(2, 5) x, generate_series(-60, -57) y, generate_series(3, 6) z));
select t.eq('...all of them stone', (select count(*)::int from t.out(1), unnest(entries) e where e >> 12 = mc.state_id('minecraft:stone')), 64);
select t.eq('...in the order of the set filled in /fill order (x fastest, then y, then z)',
            (select array_agg((e & 4095)::int) from t.out(1), unnest(entries) e),
            mc.shortset_order(array(select (x << 8) | (z << 4) | (y & 15) from generate_series(3, 6) z, generate_series(-60, -57) y, generate_series(2, 5) x order by z, y, x)));
select mc.fill('minecraft:overworld', 2, -60, 3, 5, -57, 6, 'minecraft:air');
truncate mc.play_out;
select mc.broadcast_block_events();
select t.eq('...a fill that removes blocks sends the section update and no break effect (level_event)', (select array_agg(kind) from t.out(1)), array['sbu']);
select t.eq('...(nothing but that packet)', (select count(*)::int from mc.play_out where conn_id = 1), 1);

-- 5: a fill of one position is a block_update (vanilla: the set has one element), a fill that changes one of two positions too
select t.world_reset();
select mc.fill('minecraft:overworld', 7, -59, 7, 7, -59, 7, 'minecraft:glass');
select mc.broadcast_block_events();
select t.eq('a fill of one block: block_update', (select array_agg(kind) from t.out(1)), array['bu']);
select t.world_reset();
select mc.fill('minecraft:overworld', 7, -59, 7, 7, -59, 7, 'minecraft:glass');
truncate mc.block_event;
select mc.fill('minecraft:overworld', 7, -59, 7, 8, -59, 7, 'minecraft:glass');
select mc.broadcast_block_events();
select t.eq('a two-block fill over a glass block: only the new position changes: block_update', (select (kind, cx, sy, cz)::text from t.out(1)), '(bu,8,-59,7)');
select t.world_reset();
select mc.fill('minecraft:overworld', 7, -59, 7, 8, -59, 7, 'minecraft:glass');
truncate mc.block_event, mc.play_out;
select mc.fill('minecraft:overworld', 7, -59, 7, 8, -59, 7, 'minecraft:glass');
select t.eq('a fill that changes nothing queues nothing and sends nothing', mc.broadcast_block_events() + (select count(*)::int from mc.play_out), 0);

-- 6: a set_block next to a fill in the same section and tick: the positions of both, the fill's after the single block (the order of the events)
select t.world_reset();
select mc.set_block('minecraft:overworld', 15, -50, 15, 'minecraft:gold_block');
select mc.fill('minecraft:overworld', 0, -50, 0, 3, -50, 3, 'minecraft:stone');
select mc.broadcast_block_events();
select t.eq('a block and a fill in one section: one packet with 17 entries', (select (kind, n)::text from t.out(1)), '(sbu,17)');
select t.eq('...inserted in event order: the block first, then the fill in /fill order',
            (select array_agg((e & 4095)::int) from t.out(1), unnest(entries) e),
            mc.shortset_order((15 << 8) | (15 << 4) | 14 || array(select (x << 8) | (z << 4) | 14 from generate_series(0, 3) z, generate_series(0, 3) x order by z, x)));

-- 7: several sections: chunk by chunk, sections ascending within a chunk; a whole-section fill uses the constant order; connections only get the chunks they see
select t.world_reset();
select mc.fill('minecraft:overworld', 0, -64, 0, 15, -33, 15, 'minecraft:stone');           -- chunk (0, 0): sections -4 and -3, both whole
select mc.fill('minecraft:overworld', 16, -50, 16, 17, -49, 17, 'minecraft:gold_block');     -- chunk (1, 1): 8 blocks in sections -4 (y -50) and -4 .. -3? (y -50, -49 are both section -4)
select mc.broadcast_block_events();
select t.eq('three sections changed: three packets to connection 1', (select count(*)::int from t.out(1)), 3);
select t.eq('...two whole sections of 4096 entries and 8 entries',
            (select array_agg(n order by cx, cz, sy) from t.out(1)), array[4096, 4096, 8]);
select t.eq('...sections ascending within the chunk', (select array_agg(sy order by o) from (select sy, row_number() over () o from t.out(1) where cx = 0) q), array[-4, -3]);
select t.eq('connection 2 (chunk (0, 0)) sees the near chunk too', (select count(*)::int from t.out(2)), 3);
select t.eq('the far connection gets nothing', (select count(*)::int from t.out(3)), 0);
select t.eq('a whole section is the constant order (positions 0 .. 4095 added in /fill order)',
            (select array_agg((e & 4095)::int) from (select entries from t.out(1) where cx = 0 and sy = -4) q, unnest(entries) e),
            (select ord from mc.sbu_const where id = 1));
select t.eq('every entry of a whole stone section is stone', (select count(*)::int from (select entries from t.out(1) where cx = 0 and sy = -3) q, unnest(entries) e where e >> 12 = mc.state_id('minecraft:stone')), 4096);

-- 8: sections nobody sees are not encoded (the far connection is the only one in range of nothing): the packets of an unseen section never exist, the queue is still emptied
select t.world_reset();
update net.conn set view_cx = 60, view_cz = 60;
select mc.fill('minecraft:overworld', 0, -60, 0, 9, -50, 9, 'minecraft:stone');
select t.eq('events nobody can see: nothing is sent', mc.broadcast_block_events() >= 0 and (select count(*) from mc.play_out) = 0, true);
select t.eq('...and the queue is empty', (select count(*)::int from mc.block_event), 0);

-- 9: the legacy 'section' event (a whole section replaced; nothing writes it any more) re-sends the chunk
select t.world_reset();
insert into mc.block_event (kind, dimension, x, y, z, old_state, new_state) values ('section', 'minecraft:overworld', 16, -64, 16, '*', 'minecraft:stone');
select mc.broadcast_block_events();
select t.eq('a section event: the chunk packet to the connections that see it', (select count(*)::int from mc.play_out where conn_id = 1 and t.fid_of(data) = mc.chunk_packet_id()), 1);

-- 10: the break effect of per-block events is unchanged (2001 to everybody but the actor), next to a section_blocks_update
select t.world_reset();
select mc.set_blocks('minecraft:overworld', array[1, 2, 3], array[-61, -61, -61], array[1, 1, 1], array['minecraft:air', 'minecraft:air', 'minecraft:air']);
insert into mc.block_actor values ('minecraft:overworld', 1, -61, 1, 1);
select mc.broadcast_block_events();
select t.eq('three air edits in one section: one section_blocks_update to connection 1', (select count(*)::int from t.out(1) where kind = 'sbu'), 1);
select t.eq('...connection 1 (the actor of the first) gets the break effect of the other two', (select count(*)::int from mc.play_out where conn_id = 1 and t.fid_of(data) = mc.pid('level_event')), 2);
select t.eq('...connection 2 gets all three', (select count(*)::int from mc.play_out where conn_id = 2 and t.fid_of(data) = mc.pid('level_event')), 3);

-- 11: a section_blocks_update decodes to the states the section holds now (an edit after the first event in the same tick wins, as vanilla reads the section at the end)
select t.world_reset();
select mc.set_block('minecraft:overworld', 20, -60, 20, 'minecraft:stone');
select mc.set_block('minecraft:overworld', 21, -60, 20, 'minecraft:stone');
select mc.set_block('minecraft:overworld', 20, -60, 20, 'minecraft:gold_block');
select mc.broadcast_block_events();
select t.eq('three edits, two positions: the packet has the current state of each',
            (select array_agg(e >> 12 order by e & 4095) from t.out(1), unnest(entries) e), array[mc.state_id('minecraft:gold_block'), mc.state_id('minecraft:stone')]::bigint[]);
