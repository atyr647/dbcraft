-- The packet of a fill from a cached template, built by the fill itself (sql/960, mc.fill in sql/210, mc.broadcast_block_events in sql/432; docs/PERF-WORLD2.md).
-- Everything is compared with the ORIGINAL encoder (mc.section_update_packet over mc.shortset_order over mc.cells_positions, which tests/sql/851 and the comparison with a
-- real vanilla server tests/e2e/compare_fill.py pin down): the new code must produce the same bytes for every shape, every block state class and every fill.
\! python3 tools/load_world_ref.py

create or replace function t.ref_packet(p_cx int, p_sy int, p_cz int, p_cells bytea, p_state int) returns bytea language sql as $$
  select mc.section_update_packet(p_cx, p_sy, p_cz, o, array_fill(p_state, array[cardinality(o)])) from (select mc.shortset_order(mc.cells_positions(p_cells)) o) q $$;

------------------------------------------------------------------------------------------------ 1: mc.fill_packet against the original encoder
-- shapes: the whole section, prefixes and suffixes, a single column, two positions, one position, a thin slab, a ragged box, positions spread over the section
create temp table shapes (name text, cells bytea);
insert into shapes values
 ('whole section', mc.block_event_full_cells()),
 ('9 x 12 x 16 (a partial edge section)', mc.box_bitmap(7, 15, 4, 15, 0, 15)),
 ('9 x 12 x 16 the other way round', mc.box_bitmap(0, 8, 0, 11, 0, 15)),
 ('one column of 3', mc.box_bitmap(3, 3, 5, 5, 0, 2)),
 ('two positions', mc.box_bitmap(0, 1, 0, 0, 0, 0)),
 ('one position', mc.box_bitmap(15, 15, 15, 15, 15, 15)),
 ('a slab 16 x 1 x 16', mc.box_bitmap(0, 15, 7, 7, 0, 15)),
 ('3 x 5 x 2', mc.box_bitmap(4, 6, 2, 6, 9, 10)),
 ('key 0 and the last position', set_bit(set_bit(decode(repeat('00', 512), 'hex'), 0, 1), 4095, 1)),
 ('scattered', (select decode(string_agg(case when i % 7 = 0 or i % 11 = 3 then 'ff' else '00' end, ''), 'hex') from generate_series(0, 511) i));
-- state ids around every length class of the VarLong (state << 12 | position): 0 (1 to 2 bytes), 1 .. 3 (2 bytes), 4 .. 511 (3 bytes), 512 and up (4 bytes), the largest the encoder handles
create temp table states (s int);
insert into states values (0), (1), (2), (3), (4), (5), (6), (7), (100), (511), (512), (513), (2047), (9000), (16384), (35722), (65535);
select t.eq('mc.fill_packet equals the original encoder: ' || (select count(*) from shapes) || ' shapes x ' || (select count(*) from states) || ' states, other section coordinates too',
            (select count(*)::int from shapes h, states st where mc.fill_packet(-3, -2, 7, h.cells, st.s) is distinct from t.ref_packet(-3, -2, 7, h.cells, st.s)), 0);
select t.eq('...the same again from the cache (a second call finds the templates)', (select count(*)::int from shapes h, states st where mc.fill_packet(5, 3, -9, h.cells, st.s) is distinct from t.ref_packet(5, 3, -9, h.cells, st.s)), 0);
select t.eq('...a state id the template classes do not cover (65536 and up, negative) goes through the general encoder',
            (select count(*)::int from shapes h, (values (65536), (70000), (-1)) st(s) where mc.fill_packet(0, 0, 0, h.cells, st.s) is distinct from t.ref_packet(0, 0, 0, h.cells, st.s)), 0);
select t.eq('...one position is a block_update, not a section_blocks_update', (select mc.fill_packet(0, 0, 0, cells, 5) = t.ref_packet(0, 0, 0, cells, 5) from shapes where name = 'one position'), true);
select t.eq('...an empty bit map gives nothing', mc.fill_packet(0, 0, 0, decode(repeat('00', 512), 'hex'), 5) is null, true);
select t.eq('the templates are cached, one row per distinct bit map', (select count(*)::int from mc.sbu_tpl where key in (select md5(cells) from shapes where name <> 'one position')), (select count(distinct md5(cells))::int from shapes where name <> 'one position'));
select t.eq('...the cached count agrees with the bit map', (select bool_and(n = bit_count(h.cells)) from mc.sbu_tpl s join shapes h on md5(h.cells) = s.key), true);

-- the cache is bounded: more than 1,000 shapes drop the oldest, keeping 800
insert into mc.sbu_tpl (key, n, tpl, tpl0) select 'dummy' || i, 2, 'x', 'y' from generate_series(1, 1100) i;
select mc.sbu_build(mc.box_bitmap(1, 2, 3, 4, 5, 6));
select t.eq('the cache keeps its newest 800 shapes when it grows past 1,000', (select count(*)::int from mc.sbu_tpl), 800);
select t.eq('...including the one just built', (select count(*)::int from mc.sbu_tpl where key = md5(mc.box_bitmap(1, 2, 3, 4, 5, 6))), 1);
delete from mc.sbu_tpl;

------------------------------------------------------------------------------------------------ 2: the fill builds the packet when a connection can see the section
create or replace function t.world_reset() returns void language plpgsql as $$
begin
  truncate net.conn, mc.play_out, mc.block_event, mc.pending_ack, mc.block_actor;
  insert into net.conn (conn_id, state, compression, closing, view_cx, view_cz) values (1, 'play', -1, false, 1, 1), (3, 'play', -1, false, 60, 60);
end $$;
select mc.generate_flat_area('minecraft:overworld', -3, -3, 6, 6);
select t.world_reset();
select mc.fill('minecraft:overworld', 0, -60, 0, 40, -20, 40, 'minecraft:gold_block');       -- 3 x 3 chunks, sections -4 .. -2
select t.eq('a fill that connection 1 can see queues a pre-built packet with every section event', (select (count(*), count(pkt))::text from mc.block_event), '(27,27)');
select t.eq('...each equal to the original encoder''s bytes',
            (select count(*)::int from mc.block_event e where e.pkt is distinct from t.ref_packet(e.x >> 4, e.y >> 4, e.z >> 4, e.cells, mc.state_id('minecraft:gold_block'))), 0);
select t.eq('...the events are queued in the order of the sections written (chunk x, chunk z, section)',
            (select array_agg(id order by id) = array_agg(id order by x, z, y) from mc.block_event), true);
create temp table ev1 as select * from mc.block_event order by id;
select mc.broadcast_block_events();
select t.eq('...the broadcast sends the stored packets: 27 packets to connection 1 (chunks and sections in ascending order)', (select count(*)::int from mc.play_out where conn_id = 1), 27);
select t.eq('...the same bytes as the originals, in chunk, then section order',
            (select array_agg(data order by seq) from mc.play_out where conn_id = 1),
            (select array_agg(t.ref_packet(x >> 4, y >> 4, z >> 4, cells, mc.state_id('minecraft:gold_block')) order by x, z, y) from ev1));
select t.eq('...and nothing to the far connection', (select count(*)::int from mc.play_out where conn_id = 3), 0);
select t.eq('...the queue is empty', (select count(*)::int from mc.block_event), 0);

-- nobody in range when the fill runs: nothing is built, and a connection that arrives before the tick gets the same packets built by the broadcast
select t.world_reset();
update net.conn set view_cx = 60, view_cz = 60;
select mc.fill('minecraft:overworld', 0, -60, 0, 40, -20, 40, 'minecraft:stone');
select t.eq('nobody in range: the events carry no packet', (select (count(*), count(pkt))::text from mc.block_event), '(27,0)');
update net.conn set view_cx = 1, view_cz = 1 where conn_id = 1;
create temp table ev2 as select * from mc.block_event order by id;
select mc.broadcast_block_events();
select t.eq('...a connection that arrives before the tick still gets all 27 packets, equal to the originals',
            (select array_agg(data order by seq) from mc.play_out where conn_id = 1),
            (select array_agg(t.ref_packet(x >> 4, y >> 4, z >> 4, cells, mc.state_id('minecraft:stone')) order by x, z, y) from ev2));

-- a second event in the section in the same tick: the general path (the stored packet describes the fill alone)
select t.world_reset();
select mc.fill('minecraft:overworld', 0, -64, 0, 15, -49, 15, 'minecraft:air'); truncate mc.block_event;           -- (a clean slate: the steps above left blocks here)
select mc.fill('minecraft:overworld', 0, -60, 0, 9, -50, 9, 'minecraft:stone');
select mc.set_block('minecraft:overworld', 15, -50, 15, 'minecraft:gold_block');
select mc.broadcast_block_events();
select t.eq('a fill and a block in one section: one packet with both (the stored packet is not used)', (select count(*)::int from mc.play_out where conn_id = 1), 1);
create or replace function t.sbu_count(p bytea) returns int language plpgsql immutable as $$     -- the entry count of a framed section_blocks_update: after the length, the packet id and the 8-byte section position
declare o int := 0; v int := 0; s int := 0; c int;
begin
  for k in 1 .. 2 loop                                  -- skip the length and the id (VarInts)
    loop c := get_byte(p, o); o := o + 1; exit when c < 128; end loop;
  end loop;
  o := o + 8;
  loop c := get_byte(p, o); o := o + 1; v := v | ((c & 127) << s); s := s + 7; exit when c < 128; end loop;
  return v;
end $$;
select t.eq('...with 10 x 11 x 10 + 1 entries', (select t.sbu_count(data) from mc.play_out where conn_id = 1), 1101);

------------------------------------------------------------------------------------------------ 3: random fills, with and without a viewer at the time of the fill
-- boxes whose pieces in every section are at least 4 wide in every direction, so that every section goes through the cells path; shapes repeat, the cache is warm for some
create or replace function t.rand_box(out x1 int, out y1 int, out z1 int, out x2 int, out y2 int, out z2 int) language plpgsql as $$
declare ok boolean := false;
begin
  while not ok loop
    x1 := (random() * 60)::int - 10; z1 := (random() * 60)::int - 10; y1 := -64 + (random() * 100)::int;
    x2 := x1 + 3 + (random() * 40)::int; z2 := z1 + 3 + (random() * 40)::int; y2 := y1 + 3 + (random() * 40)::int;
    ok := y2 < 100
      and (x1 >> 4 = x2 >> 4 or ((16 - (x1 & 15)) >= 4 and ((x2 & 15) + 1) >= 4))
      and (z1 >> 4 = z2 >> 4 or ((16 - (z1 & 15)) >= 4 and ((z2 & 15) + 1) >= 4))
      and (y1 >> 4 = y2 >> 4 or ((16 - (y1 & 15)) >= 4 and ((y2 & 15) + 1) >= 4));
  end loop;
end $$;
create or replace function t.random_fills(p_n int, p_viewer_first boolean) returns int language plpgsql as $$
declare i int; b record; blk text; bad int := 0; got bytea[]; want bytea[]; st int;
begin
  for i in 1 .. p_n loop
    perform t.world_reset();
    if not p_viewer_first then update net.conn set view_cx = 60, view_cz = 60 where conn_id = 1; end if;
    b := t.rand_box();
    blk := (array['minecraft:stone', 'minecraft:air', 'minecraft:gold_block', 'minecraft:oak_log[axis=x]', 'minecraft:glass', 'minecraft:water[level=0]', 'minecraft:redstone_block'])[1 + (random() * 6)::int];
    perform mc.fill('minecraft:overworld', b.x1, b.y1, b.z1, b.x2, b.y2, b.z2, blk);
    if not p_viewer_first then update net.conn set view_cx = 1, view_cz = 1 where conn_id = 1; end if;
    st := mc.state_id(blk);
    select array_agg(t.ref_packet(e.x >> 4, e.y >> 4, e.z >> 4, e.cells, st) order by e.x, e.z, e.y) into want from mc.block_event e where e.kind = 'cells';
    perform mc.broadcast_block_events();
    select array_agg(data order by seq) into got from mc.play_out where conn_id = 1;
    if got is distinct from want then bad := bad + 1; raise notice 'random fill % differs: box %, block %', i, b, blk; end if;
  end loop;
  return bad;
end $$;
select t.eq('40 random fills with a viewer at the time of the fill: every packet equals the original encoder''s', t.random_fills(40, true), 0);
select t.eq('40 random fills, the viewer arrives after the fill (the broadcast builds the packets)', t.random_fills(40, false), 0);

------------------------------------------------------------------------------------------------ 4: the whole-section shortcut (one UPDATE) and the general path agree
-- (one function does the fill and reads the results back: a single SELECT would show the old snapshot to its sub-selects)
create or replace function t.fr(x1 int, y1 int, z1 int, x2 int, y2 int, z2 int, blk text, p_cx int, p_sy int, p_cz int) returns text language plpgsql as $$
declare c int; ev int; bits int; s mc.chunk_section;
begin
  truncate mc.block_event;
  c := mc.fill('minecraft:overworld', x1, y1, z1, x2, y2, z2, blk);
  select count(*), coalesce(max(bit_count(cells)), 0) into ev, bits from mc.block_event;
  select * into s from mc.chunk_section cs where cs.dimension = 'minecraft:overworld' and cs.cx = p_cx and cs.cz = p_cz and cs.sy = p_sy;
  return format('covered %s, events %s, positions %s | bits %s, palette %s, blocks %s, fluids %s', c, ev, bits, s.bits, array_to_string(s.palette, ';'), s.block_count, s.fluid_count);
end $$;
select t.world_reset();
select mc.fill('minecraft:overworld', 0, -48, 0, 15, -33, 15, 'minecraft:stone');             -- (the section above the flat ground is air)
select t.eq('a whole section of stone becomes gold: 4096 positions changed, one event, a single-value section',
            t.fr(0, -48, 0, 15, -33, 15, 'minecraft:gold_block', 0, -3, 0), 'covered 4096, events 1, positions 4096 | bits 0, palette minecraft:gold_block, blocks 4096, fluids 0');
select t.eq('...the same block again: nothing changes, no event', t.fr(0, -48, 0, 15, -33, 15, 'minecraft:gold_block', 0, -3, 0), 'covered 4096, events 0, positions 0 | bits 0, palette minecraft:gold_block, blocks 4096, fluids 0');
select t.eq('...to water: the fluid count is 4096, the block count too', t.fr(0, -48, 0, 15, -33, 15, 'minecraft:water[level=0]', 0, -3, 0), 'covered 4096, events 1, positions 4096 | bits 0, palette minecraft:water[level=0], blocks 4096, fluids 4096');
select t.eq('...to air: both counts 0', t.fr(0, -48, 0, 15, -33, 15, 'minecraft:air', 0, -3, 0), 'covered 4096, events 1, positions 4096 | bits 0, palette minecraft:air, blocks 0, fluids 0');
-- a palette section (the untouched flat ground of chunk (-3, -3): bedrock, dirt, grass in section -4) filled whole with grass: only the positions that differ change
select t.eq('a whole palette section: the event holds exactly the positions that were not that block, the section becomes single-valued',
            t.fr(-48, -64, -48, -33, -49, -33, 'minecraft:grass_block[snowy=false]', -3, -4, -3), 'covered 4096, events 1, positions 3840 | bits 0, palette minecraft:grass_block[snowy=false], blocks 4096, fluids 0');
select t.eq('a whole section that does not exist yet (a new chunk) is created: event and row', t.fr(1600, -48, 1600, 1615, -33, 1615, 'minecraft:stone', 100, -3, 100), 'covered 4096, events 1, positions 4096 | bits 0, palette minecraft:stone, blocks 4096, fluids 0');
select t.eq('the chunk row of a changed chunk is versioned and flagged once per fill', (select (version, dirty, hm_dirty)::text from mc.chunk where dimension = 'minecraft:overworld' and cx = 100 and cz = 100), '(1,t,t)');

------------------------------------------------------------------------------------------------ 5: mc.fill_section (the original interface) still queues its own event
create or replace function t.fs(p_blk text) returns text language plpgsql as $$
declare c int;
begin
  truncate mc.block_event;
  c := mc.fill_section('minecraft:overworld', -2, -3, -2, 0, 15, 0, 15, 0, 15, p_blk, 'minecraft:plains');
  return c || ',' || (select count(*) from mc.block_event where kind = 'cells');
end $$;
select t.world_reset();
select t.eq('mc.fill_section of one box: returns the count and queues the cells event', t.fs('minecraft:stone'), '4096,1');
select t.eq('...and nothing for a section that already is that block', t.fs('minecraft:stone'), '0,0');
select t.eq('the pkt column is stored without compression', (select attstorage from pg_attribute where attrelid = 'mc.block_event'::regclass and attname = 'pkt'), 'e');
