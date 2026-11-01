-- Bit packing, bit sets, block-state helpers.
select t.eq('ceillog2 ' || n, mc.ceillog2(n), want)
from (values (1, 0), (2, 1), (3, 2), (4, 2), (5, 3), (16, 4), (17, 5), (256, 8), (257, 9), (35723, 16), (65536, 16), (65537, 17), (67, 7)) v(n, want);

-- Hand-computed vanilla layouts.  4 bits: 16 entries per long, entry i at bit 4*i (LSB first), long written big-endian.
select t.eq('pack 4 bits: 0..15 in one long', encode(mc.pack_longs(array(select generate_series(0, 15)), 4), 'hex'), 'fedcba9876543210');
select t.eq('pack 4 bits: 17 entries need 2 longs', encode(mc.pack_longs(array(select 1 from generate_series(1, 17)), 4), 'hex'), '1111111111111111' || '0000000000000001');
-- 9 bits (heightmaps): 7 per long, bits 63 unused; 256 entries -> 37 longs
select t.eq('pack 9 bits: 256 entries -> 37 longs', length(mc.pack_longs(array_fill(4, array[256]), 9)), 37 * 8);
select t.eq('pack 9 bits: all 4s matches the captured heightmap long', encode(substr(mc.pack_longs(array_fill(4, array[256]), 9), 1, 8), 'hex'), '0100804020100804');
-- 5 bits: 12 per long (60 bits used), so 4096 entries -> 342 longs
select t.eq('pack 5 bits: 4096 entries -> 342 longs', length(mc.pack_longs(array_fill(0, array[4096]), 5)), 342 * 8);
select t.eq('pack 16 bits: 4 per long', encode(mc.pack_longs(array[1, 2, 3, 4], 16), 'hex'), '0004000300020001');
select t.eq('pack 16 bits: 4096 entries -> 1024 longs', length(mc.pack_longs(array_fill(7, array[4096]), 16)), 8192);
select t.eq('pack 1 bit: 64 per long', encode(mc.pack_longs(array_fill(1, array[64]), 1), 'hex'), 'ffffffffffffffff');
select t.eq('pack 2 bits (biomes): 64 entries -> 2 longs', length(mc.pack_longs(array_fill(3, array[64]), 2)), 16);

-- Round trips for every width, with entries at their maximum so no bit is left untested
select t.eq('pack/unpack round trip, ' || b || ' bits, ' || n || ' entries', count(*)::int, 0)
from (values (1, 64), (2, 64), (3, 64), (4, 4096), (5, 4096), (6, 4096), (7, 4096), (8, 4096), (9, 256), (10, 100), (11, 4096), (12, 4096), (13, 500), (14, 4096), (15, 4096), (16, 4096)) cfg(b, n),
     lateral (select a from (select array(select (random() * ((1 << b) - 1))::int from generate_series(1, n)) a) q
              where mc.unpack_longs(mc.pack_longs(a, b), b, n) is distinct from a) bad
group by b, n;
select t.eq('unpack with bits 0 is all zero', mc.unpack_longs('\x', 0, 5), array[0, 0, 0, 0, 0]);
select t.eq('entry_at agrees with unpack (random positions, all widths)', count(*)::int, 0)
from (select b, a, mc.pack_longs(a, b) d from (select b, array(select (random() * ((1 << b) - 1))::int from generate_series(1, 4096)) a
                                                 from (values (4), (5), (6), (7), (8), (16)) w(b)) z) s,
     lateral generate_series(0, 4095, 37) i
where mc.entry_at(s.b, s.d, i) <> s.a[i + 1];

-- Section index and bit sets
select t.eq('section_idx of the origin', mc.section_idx(0, 0, 0), 0);
select t.eq('section_idx negative coordinates wrap like vanilla', mc.section_idx(-1, -1, -1), 4095);
select t.eq('section_idx x,y,z weights', mc.section_idx(1, 0, 0) + 16 * mc.section_idx(0, 0, 1) + 256 * mc.section_idx(0, 0, 0), 1 + 16 * 16);
select t.eq('section_idx y is the high part', mc.section_idx(3, 2, 1), 2 * 256 + 1 * 16 + 3);
select t.eq('bitset empty', encode(mc.bitset_wire('{}'), 'hex'), '00');
select t.eq('bitset {0,1,2} = captured mask', encode(mc.bitset_wire(array[0, 1, 2]), 'hex'), '0107');
select t.eq('bitset {1,2}', encode(mc.bitset_wire(array[1, 2]), 'hex'), '0106');
select t.eq('bitset {0}', encode(mc.bitset_wire(array[0]), 'hex'), '0101');
select t.eq('bitset {8} needs two bytes', encode(mc.bitset_wire(array[8]), 'hex'), '020001');
select t.eq('bitset {25}', encode(mc.bitset_wire(array[25]), 'hex'), '04' || '00000002');

-- Block-state helpers (uses the loaded ref data)
select t.eq('state ids of the captured flat world', array[mc.state_id('minecraft:bedrock'), mc.state_id('minecraft:dirt'), mc.state_id('minecraft:grass_block'), mc.state_id('minecraft:air')], array[88, 10, 9, 0]);
select t.eq('canon_state of a bare name is the default state', mc.canon_state('minecraft:oak_log'), 'minecraft:oak_log[axis=y]');
select t.eq('canon_state of a full name is itself', mc.canon_state('minecraft:oak_log[axis=x]'), 'minecraft:oak_log[axis=x]');
select t.raises('canon_state of nonsense', $$select mc.canon_state('minecraft:no_such_block')$$);
select t.eq('state_name round trip', mc.state_name(88), 'minecraft:bedrock');
select t.eq('global block bits', mc.global_block_bits(), 16);
select t.is_true('air variants', mc.is_air('minecraft:air') and mc.is_air('minecraft:cave_air') and mc.is_air('minecraft:void_air') and not mc.is_air('minecraft:stone'));
select t.is_true('fluid states', mc.has_fluid('minecraft:water[level=0]') and mc.has_fluid('minecraft:oak_stairs[facing=north,half=bottom,shape=straight,waterlogged=true]')
                              and not mc.has_fluid('minecraft:oak_stairs[facing=north,half=bottom,shape=straight,waterlogged=false]') and not mc.has_fluid('minecraft:stone'));
