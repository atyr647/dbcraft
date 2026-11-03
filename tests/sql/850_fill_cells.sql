-- mc.fill (sql/210: mc.fill_section, one 'cells' event per section) against the reference: the same boxes placed block by block with mc.set_blocks in a second dimension.
-- What must be identical: block counts and fluid counts of every section, the block at every position, (for sections that never received a whole-section fill, which
-- becomes a single-value section on purpose) palette, bit width and packed data byte for byte, the set of positions the events report, and the chunk heightmaps after the
-- recompute.  Random boxes over 2 x 2 chunks cover: single-value sections turning into palette sections, palette growth 4 -> 5 -> 6 bits, the global palette (fallback),
-- boxes of 1 to 48 blocks (the per-block path), boxes that change only part of their positions (the mixed bit map), whole-section fills, no-op fills, air, fluids,
-- section and chunk borders, negative coordinates and the error cases.
\! python3 tools/load_world_ref.py

insert into mc.dimension (name) values ('dbcraft:f1'), ('dbcraft:f2');
insert into mc.flat_layer (dimension, y, block)
select d, y, b from (values ('dbcraft:f1'), ('dbcraft:f2')) dd(d),
     (values (-64, 'minecraft:bedrock'), (-63, 'minecraft:dirt'), (-62, 'minecraft:dirt'), (-61, 'minecraft:grass_block')) l(y, b);
select mc.generate_flat_area('dbcraft:f1', -1, -1, 1, 1);
select mc.generate_flat_area('dbcraft:f2', -1, -1, 1, 1);
truncate mc.block_event;

create temp table pool as select array['minecraft:stone','minecraft:dirt','minecraft:gravel','minecraft:sand','minecraft:glass','minecraft:oak_planks','minecraft:oak_leaves',
    'minecraft:water','minecraft:lava','minecraft:cobblestone','minecraft:granite','minecraft:diorite','minecraft:andesite','minecraft:sandstone','minecraft:clay',
    'minecraft:obsidian','minecraft:oak_log','minecraft:birch_log','minecraft:spruce_log','minecraft:air','minecraft:air','minecraft:cave_air','minecraft:stone',
    'minecraft:oak_stairs[facing=east,half=top,shape=straight,waterlogged=true]','minecraft:grass_block','minecraft:gold_block','minecraft:iron_block'] a;
create temp table rstates as select array_agg(name) a from (select name from ref.block_state order by md5(name) limit 330) q;

-- the box fills: (step, x1..z2, block).  Positions inside x -32..31, z -32..31, y -64..40 (sections -4 .. 2).
create temp table fills (step int primary key, x1 int, y1 int, z1 int, x2 int, y2 int, z2 int, block text, kind text);
select setseed(0.31);
-- random boxes of all sizes
insert into fills
select n, x1, y1, z1, x1 + dx, y1 + dy, z1 + dz, a[1 + (random() * 26)::int], 'random'
from (select n, -32 + (random() * 50)::int x1, -64 + (random() * 90)::int y1, -32 + (random() * 50)::int z1,
             case when random() < 0.3 then (random() * 3)::int else (random() * 30)::int end dx, case when random() < 0.3 then (random() * 2)::int else (random() * 22)::int end dy,
             case when random() < 0.3 then (random() * 3)::int else (random() * 30)::int end dz, a
        from generate_series(1, 90) n, pool) q;
-- whole sections and whole chunks (aligned boxes), over content that is air, stone, mixed
insert into fills values (101, 0, -48, 0, 15, -33, 15, 'minecraft:stone', 'aligned'), (102, 0, -48, 0, 15, -33, 15, 'minecraft:stone', 'aligned noop'),
    (103, 0, -48, 0, 15, -33, 15, 'minecraft:air', 'aligned'), (104, -16, -48, -16, -1, -17, -1, 'minecraft:gold_block', 'aligned'),
    (105, -16, -48, -16, 15, -17, 15, 'minecraft:gold_block', 'aligned over mixed'), (106, 0, -64, 0, 15, -49, 15, 'minecraft:water', 'whole section over palette'),
    (107, 3, -40, 3, 6, -38, 9, 'minecraft:oak_log', 'partial'), (108, 0, -48, 0, 15, -33, 15, 'minecraft:oak_log', 'whole over partial'),
    (109, -32, 16, -32, 31, 31, 31, 'minecraft:stone', 'two chunks of sections'), (110, -32, 16, -32, 31, 31, 31, 'minecraft:stone', 'noop big'),
    (111, 5, 20, 5, 5, 20, 5, 'minecraft:glass', 'one block'), (112, 5, 20, 5, 6, 20, 5, 'minecraft:glass', 'two blocks, one changes'),
    (113, 0, 0, 0, 15, 15, 15, 'minecraft:air', 'air over a single-value air section'), (114, 0, 0, 0, 15, 0, 15, 'minecraft:stone', 'one layer');
-- the box that makes a section outgrow 8 bits: one fill per distinct state (only 330 fills of 1 x 1 x 55 so the per-block path is not used)
insert into fills select 200 + n, 20, 40 + 0, 20, 21, 40 + 2, 29, rs.a[1 + n], 'global palette'
from generate_series(0, 329) n, rstates rs;

create temp table steps_done (step int);
create function pg_temp.secdig(p_dim text) returns table (cx int, cz int, sy int, bc int, fc int, pal text, bits int, dat text, content text) language sql stable as $$
  select s.cx, s.cz, s.sy, s.block_count, s.fluid_count, s.palette::text, s.bits, md5(s.data), md5(coalesce((select string_agg(b.block, '|' order by b.y, b.z, b.x) from mc.section_blocks(s, true) b), ''))
    from mc.chunk_section s where s.dimension = p_dim $$;

-- run: through mc.fill in f1, block by block in f2 (set_blocks lists every position of the box), compare what changed
create function pg_temp.positions_of(p_dim text) returns table (x int, y int, z int) language sql stable as $$
  select e.x + (i & 15), e.y + (i >> 8), e.z + ((i >> 4) & 15) from mc.block_event e, generate_series(0, 4095) i
   where e.dimension = p_dim and e.kind = 'cells' and get_bit(e.cells, i) = 1
  union
  select e.x, e.y, e.z from mc.block_event e where e.dimension = p_dim and e.kind = 'block' $$;

create table pg_temp.log (step int, ok_counts boolean, ok_events boolean, ok_ret boolean);
do $$
declare
    f record; r1 int; r2 int; n int := 0; bad_ret int := 0; bad_ev int := 0; bad_cnt int := 0; bad_raw int := 0; bad_cont int := 0; n_cells int := 0; n_blocks int := 0;
    xs int[]; ys int[]; zs int[]; bl text[]; ev1 text; ev2 text; c1 text; c2 text; whole_secs text[] := '{}'; k text;
    a record; p2 text; b2 int; d2 text;
begin
    for f in select * from fills order by step loop
        n := n + 1;
        truncate mc.block_event;
        r1 := mc.fill('dbcraft:f1', f.x1, f.y1, f.z1, f.x2, f.y2, f.z2, f.block);
        select array_agg(x), array_agg(y), array_agg(z), array_agg(f.block) into xs, ys, zs, bl
          from generate_series(f.x1, f.x2) x, generate_series(f.y1, f.y2) y, generate_series(f.z1, f.z2) z;
        select count(*) filter (where kind = 'cells'), count(*) filter (where kind = 'block') into a from mc.block_event where dimension = 'dbcraft:f1';
        n_cells := n_cells + a.count;  n_blocks := n_blocks + (select count(*) from mc.block_event where dimension = 'dbcraft:f1' and kind = 'block');
        select string_agg(x || ',' || y || ',' || z, ';' order by x, y, z) into ev1 from pg_temp.positions_of('dbcraft:f1');
        truncate mc.block_event;
        -- the reference: mc.set_blocks (per-block events only for positions that change)
        r2 := mc.set_blocks('dbcraft:f2', xs, ys, zs, bl);
        select string_agg(x || ',' || y || ',' || z, ';' order by x, y, z) into ev2 from pg_temp.positions_of('dbcraft:f2');
        -- mc.fill returns the blocks covered, set_blocks the blocks changed: compare with the covered count
        if r1 <> cardinality(xs) then bad_ret := bad_ret + 1; raise notice 'step %: fill returned % for % covered', f.step, r1, cardinality(xs); end if;
        if ev1 is distinct from ev2 then bad_ev := bad_ev + 1; raise notice 'step % (%): events differ (% vs % changed positions)', f.step, f.kind, (select count(*) from regexp_split_to_table(coalesce(ev1,''), ';')), r2; end if;
        -- sections that received a whole-section fill become single-value sections in f1 (and stay palette sections in f2): their raw rows are not compared from then on
        if (f.x2 - f.x1 + 1) >= 16 and (f.y2 - f.y1 + 1) >= 16 and (f.z2 - f.z1 + 1) >= 16 then
            for a in select distinct cx, cz, sy from (select x >> 4 cx, z >> 4 cz, y >> 4 sy from generate_series(f.x1, f.x2, 16) x, generate_series(f.y1, f.y2, 16) y, generate_series(f.z1, f.z2, 16) z) q loop
                whole_secs := whole_secs || (a.cx || ',' || a.cz || ',' || a.sy);
            end loop;
        end if;
        -- counts of every section after every step (cheap)
        select string_agg(cx || ',' || cz || ',' || sy || ':' || bc || '/' || fc, ';' order by cx, cz, sy) into c1 from pg_temp.secdig('dbcraft:f1') where true;
        select string_agg(cx || ',' || cz || ',' || sy || ':' || bc || '/' || fc, ';' order by cx, cz, sy) into c2 from pg_temp.secdig('dbcraft:f2') where true;
        if c1 is distinct from c2 then bad_cnt := bad_cnt + 1; raise notice 'step % (%): block/fluid counts differ', f.step, f.kind; end if;
    end loop;
    raise notice 'fills: %, cells events %, block events % (per-block path), bad returns %, event sets %, counts %', n, n_cells, n_blocks, bad_ret, bad_ev, bad_cnt;
    perform t.eq('mc.fill returns the covered count in every step', bad_ret, 0);
    perform t.eq('the changed positions of every fill equal the positions set_blocks changed (' || n || ' fills)', bad_ev, 0);
    perform t.eq('block and fluid counts equal in every section after every fill', bad_cnt, 0);
    perform t.is_true('the box path wrote cells events and the small boxes block events', n_cells > 100 and n_blocks > 0);
    -- the final state: every position equal, raw rows equal where no whole-section fill happened
    for a in select * from pg_temp.secdig('dbcraft:f1') loop
        k := a.cx || ',' || a.cz || ',' || a.sy;
        select s2.content, s2.pal, s2.bits, s2.dat into c2, p2, b2, d2 from pg_temp.secdig('dbcraft:f2') s2 where s2.cx = a.cx and s2.cz = a.cz and s2.sy = a.sy;
        if c2 is null then
            if a.content <> (select md5('') ) and a.bc > 0 then bad_cont := bad_cont + 1; raise notice 'section % missing in f2', k; end if;
            continue;
        end if;
        if a.content <> c2 then bad_cont := bad_cont + 1; raise notice 'section % differs in content', k; end if;
        if not (k = any (whole_secs)) then
            if (a.pal, a.bits, a.dat) is distinct from (p2, b2, d2) then
                bad_raw := bad_raw + 1; raise notice 'section % differs in palette/bits/data', k;
            end if;
        end if;
    end loop;
    perform t.eq('every position holds the same block in both dimensions', bad_cont, 0);
    perform t.eq('palette, bit width and packed data equal in every section that got no whole-section fill', bad_raw, 0);
end $$;

-- heightmaps: the box fills flag the chunk for a full recompute, set_blocks keeps them exact incrementally: after the recompute they must agree
select mc.ensure_chunk_current('dbcraft:f1', cx, cz) from generate_series(-1, 1) cx, generate_series(-1, 1) cz;
select mc.ensure_chunk_current('dbcraft:f2', cx, cz) from generate_series(-1, 1) cx, generate_series(-1, 1) cz;
select t.eq('heightmaps (all three) of all 9 chunks equal after the fills',
  (select count(*)::int from mc.chunk a join mc.chunk b on b.dimension = 'dbcraft:f2' and b.cx = a.cx and b.cz = a.cz
    where a.dimension = 'dbcraft:f1' and (a.hm_world_surface, a.hm_motion_blocking, a.hm_motion_blocking_no_leaves) is distinct from (b.hm_world_surface, b.hm_motion_blocking, b.hm_motion_blocking_no_leaves)), 0);

-- errors and edges
select t.raises('a fill below the world raises', $q$select mc.fill('dbcraft:f1', 0, -80, 0, 1, -70, 1, 'minecraft:stone')$q$);
select t.raises('an unknown block raises', $q$select mc.fill('dbcraft:f1', 0, 0, 0, 20, 20, 20, 'minecraft:no_such_block')$q$);
select t.eq('corners in any order', mc.fill('dbcraft:f1', 20, 30, 20, 10, 25, 10, 'minecraft:stone'), 11 * 6 * 11);
select t.eq('a bare block name is its default state', (select count(*)::int from mc.blocks_in('dbcraft:f1', 10, 25, 10, 20, 30, 20) where block = 'minecraft:oak_log[axis=y]') + mc.fill('dbcraft:f1', 10, 25, 10, 20, 30, 20, 'minecraft:oak_log') - 11 * 6 * 11, 0);
select t.eq('...and is stored as the default state', mc.get_block('dbcraft:f1', 15, 28, 15), 'minecraft:oak_log[axis=y]');
