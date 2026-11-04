-- The fill modes of sql/961 (replace <filter>, keep, outline, hollow) and the filter support of mc.fill_section_core (sql/210) against a reference model: the same
-- boxes applied position by position (in vanilla's loop order: x fastest, then y, then z) with mc.set_blocks, in a second region of the world holding the same blocks.
-- Compared: every block of the region, the block and fluid counts of every section, and the packets a client in range receives (the changed positions in the order of
-- vanilla's loop, and their states).  Vanilla's own packets for these modes were NOT recorded (tests/e2e/compare_fill.py covers the default mode only).
\! python3 tools/load_world_ref.py

------------------------------------------------------------------------------------------------ helpers: filter, boxes, union
select t.eq('mc.fill_filter_states: a bare block name is all its states', mc.fill_filter_states('stone'), array['minecraft:stone']);
select t.eq('...a block with properties: the states that have them', mc.fill_filter_states('minecraft:oak_log[axis=x]'), array['minecraft:oak_log[axis=x]']);
select t.eq('...a block with three states: three states', cardinality(mc.fill_filter_states('oak_log')), 3);
select t.eq('...a tag: the members and the members of nested tags, all their states', cardinality(mc.fill_filter_states('#minecraft:logs')) > cardinality(mc.fill_filter_states('#minecraft:oak_logs')), true);
select t.eq('...#minecraft:oak_logs is the four oak log blocks (oak_log, wood, stripped log and wood), three states each', cardinality(mc.fill_filter_states('#minecraft:oak_logs')), 12);
select t.raises('...an unknown block is an error', $$select mc.fill_filter_states('minecraft:nonexistent_block')$$);
select t.raises('...an unknown tag is an error', $$select mc.fill_filter_states('#minecraft:no_such_tag')$$);
select t.raises('...properties no state has are an error', $$select mc.fill_filter_states('minecraft:oak_log[axis=q]')$$);
select t.eq('mc.bm_or: the union of two bit maps (bit by bit against get_bit)',
            (select count(*)::int from generate_series(0, 4095) i where get_bit(mc.bm_or(mc.box_bitmap(0, 3, 0, 3, 0, 3), mc.box_bitmap(8, 15, 8, 15, 8, 15)), i)
                                                                     <> (get_bit(mc.box_bitmap(0, 3, 0, 3, 0, 3), i) | get_bit(mc.box_bitmap(8, 15, 8, 15, 8, 15), i))), 0);
select t.eq('...with NULL', (mc.bm_or(null, mc.box_bitmap(1, 2, 3, 4, 5, 6)) = mc.box_bitmap(1, 2, 3, 4, 5, 6)) and (mc.bm_or(mc.box_bitmap(1, 2, 3, 4, 5, 6), null) = mc.box_bitmap(1, 2, 3, 4, 5, 6)) and mc.bm_or(null, null) is null, true);
select t.eq('...every bit of both', (select bit_count(mc.bm_or(a, b))::int from (select mc.box_bitmap(0, 7, 0, 7, 0, 7) a, mc.box_bitmap(4, 11, 4, 11, 4, 11) b) q), 512 + 512 - 64);
select t.eq('mc.fill_boxes: the shell of a box is its faces without overlaps (6 x 5 x 7 = 210 blocks, inside 4 x 3 x 5 = 60, shell 150)',
            (select sum((x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1))::int from mc.fill_boxes('outline', 0, 5, 0, 4, 0, 6)), 150);
select t.eq('...hollow adds the inside (kind 1)', (select sum((x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1))::int from mc.fill_boxes('hollow', 0, 5, 0, 4, 0, 6) where kind = 1), 60);
select t.eq('...a box with no inside is all shell (2 x 2 x 2)', (select sum((x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1))::int from mc.fill_boxes('hollow', 0, 1, 0, 1, 0, 1)), 8);
select t.eq('...one block is one shell block', (select sum((x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1))::int from mc.fill_boxes('outline', 3, 3, 3, 3, 3, 3)), 1);
select t.eq('...a plate 5 x 1 x 5 is all shell', (select sum((x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1))::int from mc.fill_boxes('outline', 0, 4, 0, 0, 0, 4)), 25);
select t.eq('...the boxes are disjoint: the shell of 7 x 6 x 5 counted by volume and by distinct positions agree',
            (select count(*)::int from (select x, y, z from mc.fill_boxes('outline', 0, 6, 0, 5, 0, 4) b, generate_series(b.x1, b.x2) x, generate_series(b.y1, b.y2) y, generate_series(b.z1, b.z2) z) q),
            (select count(distinct (x, y, z))::int from (select x, y, z from mc.fill_boxes('outline', 0, 6, 0, 5, 0, 4) b, generate_series(b.x1, b.x2) x, generate_series(b.y1, b.y2) y, generate_series(b.z1, b.z2) z) q));
select t.raises('destroy is refused', $$select mc.fill_mode('minecraft:overworld', 0, 0, 0, 1, 1, 1, 'minecraft:stone', 'destroy')$$);
select t.raises('an unknown mode is refused', $$select mc.fill_mode('minecraft:overworld', 0, 0, 0, 1, 1, 1, 'minecraft:stone', 'frobnicate')$$);
select t.raises('a filter outside replace is refused', $$select mc.fill_mode('minecraft:overworld', 0, 0, 0, 1, 1, 1, 'minecraft:stone', 'keep', 'minecraft:dirt')$$);

------------------------------------------------------------------------------------------------ the reference model
-- Two regions of 3 x 3 chunks, 640 blocks apart in x: A (chunks 20 .. 22, x 320 .. 367) takes mc.fill_mode, B (chunks 60 .. 62) the reference.  Connection 1 sees only A, connection 2 only B.
select mc.generate_flat_area('minecraft:overworld', 20, 20, 22, 22);
select mc.generate_flat_area('minecraft:overworld', 60, 20, 62, 22);
create or replace function t.ref_mode(p_x1 int, p_y1 int, p_z1 int, p_x2 int, p_y2 int, p_z2 int, p_block text, p_mode text, p_filter text) returns int language plpgsql as $$
declare
    nm text := mc.canon_state(p_block); filt text[] := case when p_filter is not null then mc.fill_filter_states(p_filter) end;
    xs int[] := '{}'; ys int[] := '{}'; zs int[] := '{}'; bl text[] := '{}';
    lx int := least(p_x1, p_x2); hx int := greatest(p_x1, p_x2); ly int := least(p_y1, p_y2); hy int := greatest(p_y1, p_y2); lz int := least(p_z1, p_z2); hz int := greatest(p_z1, p_z2);
    x int; y int; z int; old text; tgt text; sh boolean;
begin
    if p_mode = 'keep' then filt := array(select s.name from ref.block_state s where s.block in ('minecraft:air', 'minecraft:cave_air', 'minecraft:void_air')); end if;
    for z in lz .. hz loop
      for y in ly .. hy loop
        for x in lx .. hx loop
            sh := x in (lx, hx) or y in (ly, hy) or z in (lz, hz);
            old := mc.get_block('minecraft:overworld', x, y, z);
            tgt := case p_mode when 'outline' then case when sh then nm end when 'hollow' then case when sh then nm else 'minecraft:air' end else case when filt is null or old = any (filt) then nm end end;
            continue when tgt is null or tgt = old;
            xs := xs || x; ys := ys || y; zs := zs || z; bl := bl || tgt;
        end loop;
      end loop;
    end loop;
    if cardinality(xs) = 0 then return 0; end if;
    return mc.set_blocks('minecraft:overworld', xs, ys, zs, bl);
end $$;

-- the packets of a connection as text, one per packet, sorted by kind and section (the order of sections in a tick is not a vanilla-verified property); entries in packet order
create or replace function t.vl(b bytea, o int, out v bigint, out nxt int) language plpgsql immutable as $$
declare s int := 0; c int;
begin
  v := 0;
  loop c := get_byte(b, o); o := o + 1; v := v | ((c & 127)::bigint << s); s := s + 7; exit when c < 128; end loop;
  nxt := o;
end $$;
create or replace function t.dec(p_frame bytea) returns table (kind text, cx int, sy int, cz int, entries bigint[]) language plpgsql immutable as $$
declare o int; pid int; v bigint; cnt int; i int; es bigint[] := '{}'; sec bigint; px int; py int; pz int;
begin
  select (t.vl(p_frame, 0)).nxt into o;
  select (t.vl(p_frame, o)).v, (t.vl(p_frame, o)).nxt into v, o; pid := v::int;
  if pid = mc.pid('section_blocks_update') then
    sec := proto.i64_read(p_frame, o); o := o + 8;
    select (t.vl(p_frame, o)).v, (t.vl(p_frame, o)).nxt into v, o; cnt := v::int;
    for i in 1 .. cnt loop select (t.vl(p_frame, o)).v, (t.vl(p_frame, o)).nxt into v, o; es := es || v; end loop;
    return query select 'sbu', ((sec >> 42) << 42 >> 42)::int, ((sec << 44) >> 44)::int, (((sec >> 20) & 4194303) << 42 >> 42)::int, es;
  elsif pid = mc.pid('block_update') then
    select * into px, py, pz from proto.position_read(p_frame, o); o := o + 8;
    select (t.vl(p_frame, o)).v into v;
    return query select 'bu', px, py, pz, array[v];
  end if;
end $$;
create or replace function t.packets(p_conn int, p_dx int) returns text language sql as $$       -- p_dx: blocks to shift x by so that region B reads like region A
  select coalesce(string_agg(d.kind || ':' || (case d.kind when 'sbu' then (d.cx - p_dx / 16) else d.cx - p_dx end) || ',' || d.sy || ',' || d.cz || ':' || array_to_string(d.entries, ' '), E'\n'
                             order by d.kind, (case d.kind when 'sbu' then d.cx - p_dx / 16 else d.cx - p_dx end), d.sy, d.cz), '')
    from mc.play_out o, lateral t.dec(o.data) d where o.conn_id = p_conn $$;
-- the blocks of the 3 x 3 chunk area of a region as one md5 per section, and the counts
create or replace function t.sigs(p_cx0 int) returns text language sql as $$
  select string_agg(s.cx - p_cx0 || ',' || s.sy || ',' || s.cz || ':' || s.block_count || '/' || s.fluid_count || ':' ||
                    (select md5(string_agg(b.block, ',' order by b.y, b.z, b.x)) from mc.section_blocks(s, true) b), E'\n' order by s.cx, s.cz, s.sy)
    from mc.chunk_section s where s.dimension = 'minecraft:overworld' and s.cx between p_cx0 and p_cx0 + 2 and s.cz between 20 and 22 and s.sy between -4 and 1 $$;

-- identical content in both regions: some blocks from a pool in random boxes (so that sections have palettes of several sizes), mirrored 640 blocks east
create or replace function t.seed_regions(p_n int) returns void language plpgsql as $$
declare i int; x1 int; y1 int; z1 int; x2 int; y2 int; z2 int; blk text; pool text[] := array['minecraft:stone', 'minecraft:dirt', 'minecraft:gold_block', 'minecraft:oak_log[axis=x]', 'minecraft:oak_log[axis=y]', 'minecraft:glass', 'minecraft:water[level=0]',
   'minecraft:cobblestone', 'minecraft:sand', 'minecraft:gravel', 'minecraft:oak_planks', 'minecraft:birch_log[axis=z]', 'minecraft:air', 'minecraft:iron_block', 'minecraft:diamond_block', 'minecraft:emerald_block', 'minecraft:lapis_block', 'minecraft:coal_block',
   'minecraft:copper_block', 'minecraft:redstone_block', 'minecraft:spruce_planks', 'minecraft:bricks'];
begin
  truncate net.conn, mc.play_out, mc.block_event, mc.pending_ack, mc.block_actor;
  perform mc.fill('minecraft:overworld', 320, -64, 320, 367, 40, 367, 'minecraft:air');          -- a clean slate in both regions: air above stone ground
  perform mc.fill('minecraft:overworld', 960, -64, 320, 1007, 40, 367, 'minecraft:air');
  perform mc.fill('minecraft:overworld', 320, -64, 320, 367, -50, 367, 'minecraft:stone'); perform mc.fill('minecraft:overworld', 960, -64, 320, 1007, -50, 367, 'minecraft:stone');
  for i in 1 .. p_n loop
    x1 := 320 + (random() * 40)::int; y1 := -64 + (random() * 50)::int; z1 := 320 + (random() * 40)::int; x2 := x1 + (random() * 14)::int; y2 := y1 + (random() * 14)::int; z2 := z1 + (random() * 14)::int;
    blk := pool[1 + (random() * (cardinality(pool) - 1))::int];
    perform mc.fill('minecraft:overworld', x1, y1, z1, x2, y2, z2, blk);
    perform mc.fill('minecraft:overworld', x1 + 640, y1, z1, x2 + 640, y2, z2, blk);
  end loop;
  truncate mc.block_event, mc.play_out;
  insert into net.conn (conn_id, state, compression, closing, view_cx, view_cz) values (1, 'play', -1, false, 21, 21), (2, 'play', -1, false, 61, 21);
end $$;

-- one case at a given box: '' when A and B agree, otherwise what differs.  p_late: nobody sees region A while the fill runs (the broadcast builds the packets)
create or replace function t.case_at(p_mode text, p_filter text, p_block text, x1 int, y1 int, z1 int, x2 int, y2 int, z2 int, p_late boolean) returns text language plpgsql as $$
declare ra int; rb int; pa text; pb text; diff text := ''; boxd text := format('%s %s %s %s %s %s .. %s %s %s', p_mode, coalesce(p_filter, '-'), p_block, x1, y1, z1, x2, y2, z2);
begin
  truncate mc.block_event, mc.play_out;
  if p_late then update net.conn set view_cx = 99 where conn_id = 1; end if;
  ra := mc.fill_mode('minecraft:overworld', x1, y1, z1, x2, y2, z2, p_block, p_mode, p_filter);
  if p_late then update net.conn set view_cx = 21 where conn_id = 1; end if;
  perform mc.broadcast_block_events();
  pa := t.packets(1, 0);
  truncate mc.play_out;
  rb := t.ref_mode(x1 + 640, y1, z1, x2 + 640, y2, z2, p_block, p_mode, p_filter);
  perform mc.broadcast_block_events();
  pb := t.packets(2, 640);
  if ra <> rb then diff := diff || format(' changed %s against %s;', ra, rb); end if;
  if pa <> pb then diff := diff || format(' packets differ (%s bytes against %s);', length(pa), length(pb)); end if;
  if t.sigs(20) <> t.sigs(60) then diff := diff || ' blocks or counts differ;'; end if;
  return case when diff = '' then '' else boxd || ':' || diff end;
end $$;
-- a random box inside the generated 3 x 3 chunks (the reference reads NULL outside), some of them thin
create or replace function t.case_(p_mode text, p_filter text, p_block text, p_late boolean) returns text language plpgsql as $$
declare x1 int; y1 int; z1 int; x2 int; y2 int; z2 int;
begin
  x1 := 320 + (random() * 40)::int; y1 := -64 + (random() * 50)::int; z1 := 320 + (random() * 40)::int;
  x2 := least(367, x1 + (random() * 30)::int); y2 := y1 + (random() * 24)::int; z2 := least(367, z1 + (random() * 30)::int);
  if random() < 0.2 then x2 := x1; end if; if random() < 0.2 then z2 := z1 + 1; end if; if random() < 0.15 then y2 := y1; end if;
  return t.case_at(p_mode, p_filter, p_block, x1, y1, z1, x2, y2, z2, p_late);
end $$;
create or replace function t.cases(p_n int, p_mode text, p_filters text[], p_blocks text[], p_late boolean) returns text language plpgsql as $$
declare i int; r text; bad text := ''; nbad int := 0;
begin
  for i in 1 .. p_n loop
    if i % 4 = 1 then perform t.seed_regions(6 + (random() * 20)::int); end if;
    r := t.case_(p_mode, p_filters[1 + (random() * (cardinality(p_filters) - 1))::int], p_blocks[1 + (random() * (cardinality(p_blocks) - 1))::int], p_late and i % 2 = 0);
    if r <> '' then nbad := nbad + 1; bad := bad || E'\n' || r; end if;
  end loop;
  return case when nbad = 0 then '' else nbad || ' differ:' || bad end;
end $$;

select t.seed_regions(8);
select t.eq('a first sanity case: the default mode through mc.fill_mode equals the reference', t.case_('replace', null, 'minecraft:gold_block', false), '');
select t.eq('replace (no filter), 24 random boxes and blocks: blocks, counts and packets equal the position-by-position reference',
            t.cases(24, 'replace', array[null::text], array['minecraft:gold_block', 'minecraft:air', 'minecraft:stone', 'minecraft:water[level=0]', 'minecraft:glass'], true), '');
select t.eq('replace <block>, 24 cases',
            t.cases(24, 'replace', array['minecraft:stone', 'minecraft:dirt', 'minecraft:air', 'minecraft:gold_block', 'oak_log', 'minecraft:water'], array['minecraft:iron_block', 'minecraft:air', 'minecraft:oak_planks', 'minecraft:stone'], true), '');
select t.eq('replace <block with properties>, replace <tag>, 16 cases',
            t.cases(16, 'replace', array['minecraft:oak_log[axis=x]', '#minecraft:logs', '#minecraft:planks', 'minecraft:birch_log[axis=z]'], array['minecraft:glass', 'minecraft:air', 'minecraft:oak_log[axis=x]'], true), '');
select t.eq('keep, 24 cases', t.cases(24, 'keep', array[null::text], array['minecraft:gold_block', 'minecraft:stone', 'minecraft:air', 'minecraft:water[level=0]'], true), '');
select t.eq('outline, 24 cases', t.cases(24, 'outline', array[null::text], array['minecraft:gold_block', 'minecraft:stone', 'minecraft:air', 'minecraft:glass'], true), '');
select t.eq('hollow, 24 cases', t.cases(24, 'hollow', array[null::text], array['minecraft:gold_block', 'minecraft:stone', 'minecraft:air', 'minecraft:glass'], true), '');

------------------------------------------------------------------------------------------------ edge cases
select t.seed_regions(0);
create or replace function t.fm(p_x1 int, p_y1 int, p_z1 int, p_x2 int, p_y2 int, p_z2 int, p_blk text, p_mode text, p_filter text, p_cx int, p_sy int, p_cz int) returns text language plpgsql as $$
declare c int; ev int; bits int; s mc.chunk_section;
begin
  truncate mc.block_event;
  c := mc.fill_mode('minecraft:overworld', p_x1, p_y1, p_z1, p_x2, p_y2, p_z2, p_blk, p_mode, p_filter);
  select count(*), coalesce(max(bit_count(cells)), 0) into ev, bits from mc.block_event;
  select * into s from mc.chunk_section cs where cs.dimension = 'minecraft:overworld' and cs.cx = p_cx and cs.cz = p_cz and cs.sy = p_sy;
  return format('changed %s, events %s, positions %s | bits %s, palette %s, blocks %s, fluids %s', c, ev, bits, s.bits, array_to_string(s.palette, ';'), s.block_count, s.fluid_count);
end $$;
select t.eq('replace <stone> by gold in a whole section of stone: the whole section changes and stays single-valued (the fast update)',
            t.fm(320, -48, 320, 335, -33, 335, 'minecraft:gold_block', 'replace', 'minecraft:air', 20, -3, 20), 'changed 4096, events 1, positions 4096 | bits 0, palette minecraft:gold_block, blocks 4096, fluids 0');
select t.eq('...replace <stone> over that section of gold: nothing matches, nothing changes, no event', t.fm(320, -48, 320, 335, -33, 335, 'minecraft:iron_block', 'replace', 'minecraft:stone', 20, -3, 20), 'changed 0, events 0, positions 0 | bits 0, palette minecraft:gold_block, blocks 4096, fluids 0');
select t.eq('...keep over a section of gold: nothing is air, nothing changes', t.fm(320, -48, 320, 335, -33, 335, 'minecraft:iron_block', 'keep', null, 20, -3, 20), 'changed 0, events 0, positions 0 | bits 0, palette minecraft:gold_block, blocks 4096, fluids 0');
select t.eq('...keep over the air above: the whole section of air changes',  t.fm(320, -32, 320, 335, -17, 335, 'minecraft:iron_block', 'keep', null, 20, -2, 20), 'changed 4096, events 1, positions 4096 | bits 0, palette minecraft:iron_block, blocks 4096, fluids 0');
select t.eq('...hollow 5 x 5 x 5 in the air: 125 - 27 = 98 shell blocks, the inside (air) does not change', t.fm(320, -16, 320, 324, -12, 324, 'minecraft:stone', 'hollow', null, 20, -1, 20), 'changed 98, events 1, positions 98 | bits 4, palette minecraft:air;minecraft:stone, blocks 98, fluids 0');
select t.eq('...hollow again with glass: the shell (98) changes, the inside is air already', t.fm(320, -16, 320, 324, -12, 324, 'minecraft:glass', 'hollow', null, 20, -1, 20), 'changed 98, events 1, positions 98 | bits 4, palette minecraft:air;minecraft:stone;minecraft:glass, blocks 98, fluids 0');
select t.eq('...outline 5 x 5 x 5 of water over the glass box, the inside stays', t.fm(320, -16, 320, 324, -12, 324, 'minecraft:water[level=0]', 'outline', null, 20, -1, 20), 'changed 98, events 1, positions 98 | bits 4, palette minecraft:air;minecraft:stone;minecraft:glass;minecraft:water[level=0], blocks 98, fluids 98');
-- a global palette (more than 256 states in one section): the position-by-position way
select t.seed_regions(0);
do $$                                                         -- one block at a time: mc.set_block grows a palette past 256 states into the global palette (mc.set_blocks keeps a long palette)
declare i int; nm text;
begin
  for i in 0 .. 299 loop
    select name into nm from (select name, row_number() over (order by state_id) rn from ref.block_state where name not like '%[%' or state_id % 7 = 0) q where rn = i + 1;
    perform mc.set_block('minecraft:overworld', 320 + (i % 16), -32 + (i / 16) % 16, 320 + (i / 256), nm);
    perform mc.set_block('minecraft:overworld', 960 + (i % 16), -32 + (i / 16) % 16, 320 + (i / 256), nm);
  end loop;
end $$;
select t.eq('the test world really has a section with a global palette', (select cardinality(palette) from mc.chunk_section where cx = 20 and cz = 20 and sy = -2), 0);
truncate mc.block_event, mc.play_out;
select t.eq('a section with a global palette: keep, outline and replace agree with the reference',
            (select string_agg(t.case_at(m, f, 'minecraft:gold_block', 322, -34, 321, 345, -20, 340, false) || t.case_at(m, f, 'minecraft:glass', 320, -32, 320, 335, -17, 335, true), '') from (values ('keep', null::text), ('outline', null), ('replace', 'minecraft:stone'), ('replace', null), ('hollow', null)) v(m, f)), '');
