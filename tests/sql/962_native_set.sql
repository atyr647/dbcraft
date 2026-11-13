-- The optional native accelerator for the first fill of a shape (native/dbcraft_set, sql/962): the C simulation of fastutil's ShortOpenHashSet and the C template builder
-- against the SQL ones.  Skipped with a notice when the extension is not installed in this server.  (Against the REAL fastutil class: tests/bench/world2/set_order_native.sh.)
select mc.native_set_available() as have_native \gset
\if :have_native
select t.is_true('the dispatcher points at the native simulation after the migration', mc.shortset_impl() = 'native');

-- random insertion sequences, with duplicates, of every size up to a whole section, and the orders of boxes
create temp table seqs (id serial primary key, a int[]);
select setseed(0.62);
insert into seqs (a) select array(select (random() * 4095)::int from generate_series(1, n)) from (select (1 + (random() * random() * 4095))::int n from generate_series(1, 150)) q;
insert into seqs (a) select array(select p from (select p from generate_series(0, 4095) p order by random() limit n) q) from (select (1 + (random() * 4095))::int n from generate_series(1, 60)) q;
insert into seqs (a) select array(select generate_series(0, n - 1)) from unnest(array[1, 2, 24, 25, 26, 48, 49, 96, 97, 192, 193, 384, 385, 768, 769, 1536, 1537, 3072, 3073, 4096]) n;
insert into seqs (a) select array[0]; insert into seqs (a) select array[0, 0, 0, 5, 0]; insert into seqs (a) select array[7, 7, 7]; insert into seqs (a) select '{}'::int[];
insert into seqs (a)
select mc.cells_positions(mc.box_bitmap(x1, x1 + dx, y1, y1 + dy, z1, z1 + dz))
  from (select (random() * 15)::int x1, (random() * 15)::int y1, (random() * 15)::int z1, random() dxr from generate_series(1, 80)) q,
       lateral (select least(15 - x1, (random() * 15)::int) dx, least(15 - y1, (random() * 15)::int) dy, least(15 - z1, (random() * 15)::int) dz) d;
insert into seqs (a) select mc.cells_positions(mc.block_event_full_cells());
select t.eq('the native simulation equals the SQL simulation on ' || count(*) || ' sequences (random with duplicates, distinct, around every rehash, boxes, a whole section)',
            (select count(*) from seqs where dbcraft_set.shortset_order(a) is distinct from mc.shortset_order_sql(a)), 0::bigint) from seqs;
select t.eq('the dispatcher gives the native result', (select count(*) from seqs where mc.shortset_order(a) is distinct from dbcraft_set.shortset_order(a)), 0::bigint);
select t.raises('a key above 65535 is refused', $$ select dbcraft_set.shortset_order(array[70000]) $$);
select t.raises('a null is refused', $$ select dbcraft_set.shortset_order(array[1, null]) $$);

-- the templates: the SQL expressions of mc.sbu_build (sql/960) over the SQL simulation
create or replace function pg_temp.tpl_sql(p_cells bytea) returns text[] language sql as $$
  select array[string_agg(to_hex(8 + ((p >> 4) & 7)) || to_hex(p & 15) || case when ((p >> 11) & 1) = 0 then 'g' else 'h' end || to_hex((p >> 7) & 15) || 'z', '' order by o),
               string_agg(case when p < 128 then lpad(to_hex(p), 2, '0') else to_hex(8 + ((p >> 4) & 7)) || to_hex(p & 15) || lpad(to_hex(p >> 7), 2, '0') end, '' order by o)]
    from unnest(mc.shortset_order_sql(mc.cells_positions(p_cells))) with ordinality t(p, o) $$;
create temp table maps (id serial primary key, c bytea);
insert into maps (c)
select mc.box_bitmap(x1, least(15, x1 + dx), y1, least(15, y1 + dy), z1, least(15, z1 + dz))
  from (select (random() * 15)::int x1, (random() * 15)::int y1, (random() * 15)::int z1, (random() * 15)::int dx, (random() * 15)::int dy, (random() * 15)::int dz from generate_series(1, 120)) q;
insert into maps (c) select mc.block_event_full_cells();
insert into maps (c) select decode(repeat('01', 512), 'hex');                                      -- one position in every 8
insert into maps (c) select decode(repeat('aa55', 256), 'hex');
insert into maps (c) select overlay(decode(repeat('00', 512), 'hex') placing '\x80'::bytea from 100 for 1);
select t.eq('the native templates (' || count(*) || ' bit maps: boxes, a whole section, patterns, one bit) equal the SQL ones, for the state and the air entries',
            (select count(*) from maps where (select array[dbcraft_set.fill_tpl(c), dbcraft_set.fill_tpl0(c)]) is distinct from pg_temp.tpl_sql(c)), 0::bigint) from maps;

-- the packet of a fill built from either template equals the general encoder's (mc.section_update_packet over the simulated order)
create temp table packs (cells bytea, state int);
insert into packs select c, s from (select c from maps order by id limit 40) m, unnest(array[0, 1, 3, 4, 511, 512, 20000]) s;
select mc.select_shortset('sql');
truncate mc.sbu_tpl;
create temp table pk_sql as select cells, state, mc.fill_packet(1, 2, 3, cells, state) pkt from packs;
select mc.select_shortset('native');
truncate mc.sbu_tpl;
create temp table pk_nat as select cells, state, mc.fill_packet(1, 2, 3, cells, state) pkt from packs;
select t.eq('mc.fill_packet gives the same bytes with the native templates as with the SQL ones (' || count(*) || ' shapes x states)',
            (select count(*) from pk_sql a join pk_nat b using (cells, state) where a.pkt is distinct from b.pkt), 0::bigint) from packs;
select t.eq('... and those equal the general encoder',
            (select count(*) from pk_nat a where bit_count(a.cells) > 1 and a.pkt is distinct from mc.section_update_packet(1, 2, 3, mc.shortset_order_sql(mc.cells_positions(a.cells)), array_fill(a.state, array[bit_count(a.cells)::int]))), 0::bigint);

-- back to SQL and to native again
select t.eq('select_shortset(sql) switches', mc.select_shortset('sql'), 'sql');
select t.eq('select_shortset(native) switches back', mc.select_shortset('native'), 'native');
\else
\echo NOTE: the dbcraft_set extension is not installed in this server (native/dbcraft_set): the native accelerator tests are skipped
\endif
