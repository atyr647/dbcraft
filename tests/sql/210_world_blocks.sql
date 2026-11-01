-- get/set/fill, palette growth, batched edits, the readable view, events, cache invalidation.
\! python3 tools/load_world_ref.py
select count(*) > 0 as have_biomes from mc.biome \gset

insert into mc.dimension (name) values ('dbcraft:a'), ('dbcraft:b'), ('dbcraft:c'), ('dbcraft:d') on conflict do nothing;

-- ---------------------------------------------------------------- basics
select t.eq('get_block on a chunk that does not exist is NULL', mc.get_block('dbcraft:a', 0, 0, 0), null);
select t.eq('set_block changes a block', mc.set_block('dbcraft:a', 1, 2, 3, 'minecraft:stone'), true);
select t.eq('get_block returns it', mc.get_block('dbcraft:a', 1, 2, 3), 'minecraft:stone');
select t.eq('other blocks of that section are air', mc.get_block('dbcraft:a', 0, 2, 3), 'minecraft:air');
select t.eq('a missing section of an existing chunk is air', mc.get_block('dbcraft:a', 1, 100, 3), 'minecraft:air');
select t.eq('setting the same block again changes nothing', mc.set_block('dbcraft:a', 1, 2, 3, 'minecraft:stone'), false);
select mc.set_block('dbcraft:a', 2, 2, 3, 'minecraft:oak_log');
select t.eq('bare names resolve to the default state', mc.get_block('dbcraft:a', 2, 2, 3), 'minecraft:oak_log[axis=y]');
select mc.set_block('dbcraft:a', 3, 2, 3, 'minecraft:oak_log[axis=x]');
select t.eq('full state names are kept', mc.get_block('dbcraft:a', 3, 2, 3), 'minecraft:oak_log[axis=x]');
select t.eq('block_count counts non-air blocks', (select block_count from mc.chunk_section where dimension = 'dbcraft:a' and cx = 0 and cz = 0 and sy = 0)::int, 3);
select t.eq('three states + air use a 4-bit palette', (select bits from mc.chunk_section where dimension = 'dbcraft:a' and cx = 0 and cz = 0 and sy = 0)::int, 4);
select mc.set_block('dbcraft:a', 3, 2, 3, 'minecraft:air');
select t.eq('removing a block lowers the count', (select block_count from mc.chunk_section where dimension = 'dbcraft:a' and cx = 0 and cz = 0 and sy = 0)::int, 2);
select mc.set_block('dbcraft:a', -1, -64, -1, 'minecraft:bedrock');
select t.eq('negative coordinates', mc.get_block('dbcraft:a', -1, -64, -1), 'minecraft:bedrock');
select t.eq('negative coordinates land in chunk -1,-1 section -4', (select count(*) from mc.chunk_section where dimension = 'dbcraft:a' and cx = -1 and cz = -1 and sy = -4)::int, 1);
select t.eq('neighbouring negative block is untouched', mc.get_block('dbcraft:a', -2, -64, -1), 'minecraft:air');
select t.raises('y above the dimension', $$select mc.set_block('dbcraft:a', 0, 320, 0, 'minecraft:stone')$$);
select t.raises('y below the dimension', $$select mc.set_block('dbcraft:a', 0, -65, 0, 'minecraft:stone')$$);
select t.raises('unknown block', $$select mc.set_block('dbcraft:a', 0, 0, 0, 'minecraft:no_such_block')$$);
select t.raises('unknown dimension', $$select mc.set_block('dbcraft:nope', 0, 0, 0, 'minecraft:stone')$$);
select mc.set_block('dbcraft:a', 5, 2, 3, 'minecraft:water');
select t.eq('fluid_count tracks waterlogged and fluid blocks', (select fluid_count from mc.chunk_section where dimension = 'dbcraft:a' and cx = 0 and cz = 0 and sy = 0)::int, 1);

-- ---------------------------------------------------------------- palette growth across every bit-width change
-- Place distinct blocks one by one in a fresh section; at each threshold every block placed so far must still read back.
create temp table names300 as
  select (row_number() over (order by s.state_id))::int as n, s.name
  from ref.block b join ref.block_state s on s.state_id = b.default_state where b.name <> 'minecraft:air' order by s.state_id limit 300;
do $d$
declare
    k int; bits_now int; want_bits int; bad int;
    checks int[] := array[1, 2, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 255, 256, 257, 300];
begin
    for k in 1 .. 300 loop
        perform mc.set_block('dbcraft:a', (k - 1) & 15, 100 + ((k - 1) >> 8), ((k - 1) >> 4) & 15, (select name from names300 where n = k));
        if k = any (checks) then
            select s.bits into bits_now from mc.chunk_section s where s.dimension = 'dbcraft:a' and s.cx = 0 and s.cz = 0 and s.sy = 6;
            want_bits := mc.block_bits_for(k + 1);                       -- k distinct blocks plus air
            perform t.eq('growth: ' || k || ' distinct blocks use ' || want_bits || ' bits', bits_now, want_bits);
            select count(*) into bad from names300 m
             where m.n <= k and mc.get_block('dbcraft:a', (m.n - 1) & 15, 100 + ((m.n - 1) >> 8), ((m.n - 1) >> 4) & 15) is distinct from m.name;
            perform t.eq('growth: all ' || k || ' blocks read back', bad, 0);
        end if;
    end loop;
end $d$;
select t.eq('past 256 entries the section uses the global palette (16 bits, empty palette)', (select (bits, cardinality(palette)) from mc.chunk_section where dimension = 'dbcraft:a' and cx = 0 and cz = 0 and sy = 6), (16::smallint, 0));
select t.eq('block_count after 300 placements', (select block_count from mc.chunk_section where dimension = 'dbcraft:a' and cx = 0 and cz = 0 and sy = 6)::int, 300);
select mc.set_block('dbcraft:a', 0, 100, 0, 'minecraft:stone');
select t.eq('a global-palette section is still editable', mc.get_block('dbcraft:a', 0, 100, 0), 'minecraft:stone');
select mc.set_block('dbcraft:a', 0, 100, 0, 'minecraft:air');
select t.eq('...and removable', (select block_count from mc.chunk_section where dimension = 'dbcraft:a' and cx = 0 and cz = 0 and sy = 6)::int, 299);
select t.eq('data length of a global section is 8192 bytes', (select octet_length(data) from mc.chunk_section where dimension = 'dbcraft:a' and cx = 0 and cz = 0 and sy = 6), 8192);

-- ---------------------------------------------------------------- batched edits equal sequential edits
create temp table edits as
  select o, (random() * 31)::int - 8 as x, (random() * 47)::int - 20 as y, (random() * 31)::int - 8 as z,
         (array['minecraft:stone', 'minecraft:dirt', 'minecraft:air', 'minecraft:oak_log', 'minecraft:water', 'minecraft:glass', 'minecraft:gold_block',
                'minecraft:diamond_block', 'minecraft:iron_block', 'minecraft:sand', 'minecraft:gravel', 'minecraft:cobblestone', 'minecraft:oak_planks',
                'minecraft:spruce_planks', 'minecraft:birch_planks', 'minecraft:lava', 'minecraft:obsidian', 'minecraft:netherrack', 'minecraft:bedrock',
                'minecraft:clay', 'minecraft:snow_block', 'minecraft:ice'])[1 + (random() * 21)::int] as block
  from generate_series(1, 3000) o;
select t.is_true('sequential: the individual edits ran', (select count(*) from (select mc.set_block('dbcraft:c', x, y, z, block) from (select * from edits order by o) e) q) = 3000);
select t.is_true('batched: set_blocks changed something', mc.set_blocks('dbcraft:d', (select array_agg(x order by o) from edits), (select array_agg(y order by o) from edits),
                                                                         (select array_agg(z order by o) from edits), (select array_agg(block order by o) from edits)) > 0);
select t.eq('batched and sequential edits give the same blocks', count(*)::int, 0) from (
  (select x, y, z, block from mc.blocks_in('dbcraft:c', -8, -20, -8, 23, 26, 23) except select x, y, z, block from mc.blocks_in('dbcraft:d', -8, -20, -8, 23, 26, 23))
  union all
  (select x, y, z, block from mc.blocks_in('dbcraft:d', -8, -20, -8, 23, 26, 23) except select x, y, z, block from mc.blocks_in('dbcraft:c', -8, -20, -8, 23, 26, 23))) diff;
select t.is_true('the random edits produced a non-trivial world', (select count(*) from mc.blocks_in('dbcraft:c', -8, -20, -8, 23, 26, 23)) > 1000);
select t.eq('batched and sequential edits give the same section counts', count(*)::int, 0)
from mc.chunk_section a full join mc.chunk_section b on (a.cx, a.cz, a.sy) = (b.cx, b.cz, b.sy) and b.dimension = 'dbcraft:d'
where a.dimension = 'dbcraft:c' and (a.block_count, a.fluid_count) is distinct from (b.block_count, b.fluid_count);
select t.eq('block_count equals a count of the readable blocks (sequential dimension)', count(*)::int, 0)
from mc.chunk_section s where s.dimension = 'dbcraft:c' and s.block_count <> (select count(*) from mc.section_blocks(s));
select t.eq('...and in the batched dimension', count(*)::int, 0)
from mc.chunk_section s where s.dimension = 'dbcraft:d' and s.block_count <> (select count(*) from mc.section_blocks(s));
select t.eq('fluid_count equals a count of the readable fluid blocks', count(*)::int, 0)
from mc.chunk_section s where s.dimension = 'dbcraft:c' and s.fluid_count <> (select count(*) from mc.section_blocks(s) b where mc.has_fluid(b.block));

-- ---------------------------------------------------------------- fill
select t.eq('fill of whole sections returns the volume', mc.fill('dbcraft:a', 64, 0, 64, 79, 15, 79, 'minecraft:stone'), 4096);
select t.eq('...as a single-value section', (select (bits, block_count) from mc.chunk_section where dimension = 'dbcraft:a' and cx = 4 and cz = 4 and sy = 0), (0::smallint, 4096::smallint));
select t.eq('...readable', mc.get_block('dbcraft:a', 70, 5, 70), 'minecraft:stone');
select t.eq('fill across chunk borders, negative side', mc.fill('dbcraft:a', -20, 10, -20, -10, 12, -10, 'minecraft:glass'), 11 * 3 * 11);
select t.eq('...inside', mc.get_block('dbcraft:a', -15, 11, -15), 'minecraft:glass');
select t.eq('...outside', mc.get_block('dbcraft:a', -21, 11, -15), 'minecraft:air');
select t.eq('...counts', (select sum(block_count)::int from mc.chunk_section where dimension = 'dbcraft:a' and cx between -2 and -1 and cz between -2 and -1 and sy = 0), 363);
select mc.fill('dbcraft:a', -20, 10, -20, -10, 12, -10, 'minecraft:air') as cleared \gset
select t.eq('fill with air clears', (:cleared, mc.get_block('dbcraft:a', -15, 11, -15)), (363, 'minecraft:air'::text));
select t.eq('fill swaps corners', mc.fill('dbcraft:a', 5, 30, 5, 3, 30, 3, 'minecraft:dirt'), 9);
select t.raises('fill outside the dimension', $$select mc.fill('dbcraft:a', 0, 300, 0, 1, 330, 1, 'minecraft:stone')$$);

-- ---------------------------------------------------------------- readable view
select t.eq('view shows a block', (select block from mc.blocks where dimension = 'dbcraft:a' and x = 1 and y = 2 and z = 3), 'minecraft:stone');
select count(*) as gold_before from mc.blocks where block = 'minecraft:gold_block' and dimension = 'dbcraft:a' \gset
update mc.blocks set block = 'minecraft:gold_block' where dimension = 'dbcraft:a' and x = 1 and y = 2 and z = 3;
select t.eq('view: UPDATE edits the world (one more gold block)', (select count(*) from mc.blocks where block = 'minecraft:gold_block' and dimension = 'dbcraft:a')::int, :gold_before + 1);
select t.eq('view: ...the change is in the section', mc.get_block('dbcraft:a', 1, 2, 3), 'minecraft:gold_block');
insert into mc.blocks (dimension, x, y, z, block) values ('dbcraft:a', 40, 5, 40, 'minecraft:emerald_block');
select t.eq('view: INSERT places a block', mc.get_block('dbcraft:a', 40, 5, 40), 'minecraft:emerald_block');
update mc.blocks set x = 41 where dimension = 'dbcraft:a' and x = 40 and y = 5 and z = 40;
select t.eq('view: moving a block clears the old position', (mc.get_block('dbcraft:a', 40, 5, 40), mc.get_block('dbcraft:a', 41, 5, 40)), ('minecraft:air'::text, 'minecraft:emerald_block'::text));
delete from mc.blocks where dimension = 'dbcraft:a' and x = 41 and y = 5 and z = 40;
select t.eq('view: DELETE sets air', mc.get_block('dbcraft:a', 41, 5, 40), 'minecraft:air');
select t.eq('view never lists air', (select count(*) from mc.blocks where block = 'minecraft:air')::int, 0);
select t.eq('blocks_in restricts to the box', (select count(*) from mc.blocks_in('dbcraft:a', 1, 2, 3, 1, 2, 3))::int, 1);
select t.eq('block_at reports air for an empty position in a loaded chunk', (select block from mc.block_at('dbcraft:a', 9, 9, 9)), 'minecraft:air');
select t.eq('block_at has no row for an unloaded chunk', (select count(*) from mc.block_at('dbcraft:a', 5000, 9, 5000))::int, 0);

-- ---------------------------------------------------------------- events
select t.eq('events record old and new state', (select (old_state, new_state) from mc.block_event where dimension = 'dbcraft:a' and x = 41 and y = 5 and z = 40 order by id desc limit 1),
            ('minecraft:emerald_block'::text, 'minecraft:air'::text));
select t.eq('a section fill queues one section event', (select count(*) from mc.block_event where kind = 'section' and dimension = 'dbcraft:a' and new_state = 'minecraft:stone')::int, 1);
create temp table ev_before as select count(*) as c from mc.block_event;
select mc.set_block('dbcraft:a', 41, 5, 40, 'minecraft:air');
select t.eq('a no-op edit queues nothing', (select count(*) from mc.block_event)::int, (select c from ev_before)::int);

-- ---------------------------------------------------------------- versions, dirty flag, cache invalidation, derived data
select mc.generate_flat('minecraft:overworld', 100, 100) as generated \gset
create temp table v0 as select version, dirty from mc.chunk where dimension = 'minecraft:overworld' and cx = 100 and cz = 100;
select t.eq('a fresh flat chunk is current (not dirty)', (select dirty from v0), false);
create temp table pkt0 as select mc.chunk_packet('minecraft:overworld', 100, 100) as p;
select t.eq('chunk_packet caches', (select count(*) from mc.chunk_cache where dimension = 'minecraft:overworld' and cx = 100 and cz = 100)::int, 1);
select t.eq('the cached copy is returned again', (select p = mc.chunk_packet('minecraft:overworld', 100, 100) from pkt0), true);
select mc.set_block('minecraft:overworld', 1600, 0, 1600, 'minecraft:stone');
select t.eq('an edit bumps the version', (select version from mc.chunk where dimension = 'minecraft:overworld' and cx = 100 and cz = 100) - (select version from v0), 1::bigint);
select t.eq('...and marks the chunk dirty', (select dirty from mc.chunk where dimension = 'minecraft:overworld' and cx = 100 and cz = 100), true);
create temp table pkt1 as select mc.chunk_packet('minecraft:overworld', 100, 100) as p;
select t.eq('the next packet differs from the old one', (select a.p <> b.p from pkt0 a, pkt1 b), true);
select t.eq('...and the cache now holds the new version', (select k.version = c.version from mc.chunk_cache k join mc.chunk c using (dimension, cx, cz) where dimension = 'minecraft:overworld' and cx = 100 and cz = 100), true);
select t.eq('heightmaps follow the edit (y 0 -> value 65 at that column)', (select hm_world_surface[1] from mc.chunk where dimension = 'minecraft:overworld' and cx = 100 and cz = 100), 65::smallint);
select t.eq('other columns keep the flat height', (select hm_world_surface[2] from mc.chunk where dimension = 'minecraft:overworld' and cx = 100 and cz = 100), 4::smallint);
select t.eq('sky light: the new block (y 0) is dark, its east neighbour column (flat) is lit, one layer up both are lit',
            (select (get_byte(sky, 0), get_byte(sky, 128)) from mc.chunk_light where dimension = 'minecraft:overworld' and cx = 100 and cz = 100 and idx = 5), (240, 255));
select mc.set_block('minecraft:overworld', 1600, 0, 1600, 'minecraft:air');
select t.is_true('after removal the edited section still carries an unused palette entry (so the bytes differ)', mc.chunk_packet('minecraft:overworld', 100, 100) <> (select p from pkt0));
select t.eq('compact_section drops it (an all-air section is deleted)', mc.compact_section('minecraft:overworld', 100, 0, 100), true);
select t.eq('...and then the packet is byte-identical to the original', mc.chunk_packet('minecraft:overworld', 100, 100) = (select p from pkt0), true);
select t.eq('compact_section of a section that is not stored', mc.compact_section('minecraft:overworld', 100, 0, 100), false);
-- compaction keeps the blocks and shrinks a palette that grew
select mc.fill('dbcraft:a', 0, 32, 0, 15, 47, 15, 'minecraft:stone');
select mc.set_block('dbcraft:a', 3, 40, 3, 'minecraft:gold_block');
select mc.set_block('dbcraft:a', 3, 40, 3, 'minecraft:stone');
select t.eq('a section edited back to uniform still has two palette entries', (select cardinality(palette) from mc.chunk_section where dimension = 'dbcraft:a' and cx = 0 and cz = 0 and sy = 2)::int, 2);
select mc.compact_section('dbcraft:a', 0, 2, 0) as compacted \gset
select t.eq('compact_section makes it single-valued again', (:'compacted'::boolean, (select (bits, cardinality(palette), block_count) from mc.chunk_section where dimension = 'dbcraft:a' and cx = 0 and cz = 0 and sy = 2)), (true, (0::smallint, 1, 4096::smallint)));
select t.eq('chunk_packet of a chunk that does not exist is NULL', mc.chunk_packet('minecraft:overworld', 9999, 9999), null);

-- ---------------------------------------------------------------- independent decoder: read the wire bytes back and compare with the stored section
\if :have_biomes
  create function pg_temp.decode_blocks(w bytea) returns int[] language plpgsql as $f$
  declare o int := 4; bits int; n int; pal int[] := '{}'; r record; vpl int; len int; vals int[]; i int;
  begin
      bits := get_byte(w, o); o := o + 1;
      if bits = 0 then select * into r from proto.varint_read(w, o); return array_fill(r.val, array[4096]); end if;
      if bits <= 8 then
          select * into r from proto.varint_read(w, o); n := r.val; o := r.nxt;
          for i in 1 .. n loop select * into r from proto.varint_read(w, o); pal := pal || r.val; o := r.nxt; end loop;
      end if;
      vpl := 64 / bits; len := ((4096 + vpl - 1) / vpl) * 8;
      vals := mc.unpack_longs(substring(w from o + 1 for len), bits, 4096);
      if bits <= 8 then vals := array(select pal[e + 1] from unnest(vals) with ordinality t(e, k) order by k); end if;
      return vals;
  end $f$;
  select t.eq('wire decode of section ' || s.sy || ' of ' || s.dimension || ' (' || s.bits || ' bits) matches the stored blocks', d.ids is not distinct from w.want, true)
  from mc.chunk_section s,
       lateral (select pg_temp.decode_blocks(mc.section_wire(s)) as ids) d,
       lateral (select array(select mc.state_id(b.block) from mc.section_blocks(s, true) b order by (b.y - s.sy * 16) * 256 + (b.z - s.cz * 16) * 16 + (b.x - s.cx * 16)) as want) w
  where (s.dimension, s.cx, s.cz, s.sy) in (('dbcraft:a', 0, 0, 0), ('dbcraft:a', 0, 0, 6), ('dbcraft:a', 4, 4, 0), ('dbcraft:a', -1, -1, -4), ('dbcraft:c', 0, 0, 0), ('dbcraft:c', 1, 0, 0));
  select t.is_true('the decoded sections include a global-palette one', (select count(*) from mc.chunk_section where dimension = 'dbcraft:a' and cx = 0 and cz = 0 and sy = 6 and bits = 16) = 1);
\else
  do $d$ begin raise notice 'SKIPPED wire decode checks: no biome data (needs a capture, see tools/load_world_ref.py)'; end $d$;
\endif
