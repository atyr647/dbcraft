-- dlcraft PostgreSQL implementation: golden vectors and semantic tests.  Prints one PASS line per check and aborts (ON_ERROR_STOP) on the first failure.
-- Oracles in schema mct are written independently (plain loops, brute force) so that they do not share code with schema mc.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
\timing off
set client_min_messages = warning;
drop schema if exists mct cascade;
create schema mct;
create function mct.ok(name text, cond boolean) returns text language plpgsql as $$
begin
    if cond is not true then raise exception 'FAIL: %', name; end if;
    return 'PASS ' || name;
end $$;

-- independent reference packer: plain loops over 64-bit words
create function mct.pack_ref(entries int[], bits int) returns bytea language plpgsql as $$
declare vpl int := 64 / bits; nl int := (cardinality(entries) + vpl - 1) / vpl; w bigint; out bytea := '\x'; i int; l int; b int;
begin
    for l in 0 .. nl - 1 loop
        w := 0;
        for i in 0 .. vpl - 1 loop
            if l * vpl + i < cardinality(entries) then w := w | (entries[l * vpl + i + 1]::bigint << (i * bits)); end if;
        end loop;
        for b in reverse 7 .. 0 loop out := out || set_byte('\x00'::bytea, 0, ((w >> (b * 8)) & 255)::int); end loop;
    end loop;
    return out;
end $$;
-- independent varint (loop)
create function mct.varint_ref(v bigint) returns bytea language plpgsql as $$
declare out bytea := '\x'; b int;
begin
    loop
        b := (v & 127)::int; v := v >> 7;
        if v > 0 then out := out || set_byte('\x00'::bytea, 0, b | 128); else out := out || set_byte('\x00'::bytea, 0, b); exit; end if;
    end loop;
    return out;
end $$;
-- independent section blob from a section row
create function mct.blob_ref(bc int, bits int, pal int[], data bytea) returns bytea language plpgsql as $$
declare out bytea; p int;
begin
    out := set_byte('\x0000'::bytea, 0, bc >> 8);  out := set_byte(out, 1, bc & 255);
    out := out || set_byte('\x00'::bytea, 0, bits);
    if bits = 0 then out := out || mct.varint_ref(pal[1]);
    else
        out := out || mct.varint_ref(cardinality(pal));
        foreach p in array pal loop out := out || mct.varint_ref(p); end loop;
        out := out || data;
    end if;
    return out || '\x0000'::bytea;
end $$;

------------------------------------------------------------------------------------------------ golden vectors (spec/golden.edn)
create temp table golden_hash2 as select * from (values (0,0,0,0),(1,2,3,400418183),(-5,7,11,640748684),(1000,-1000,1337,370995784),(-123456,654321,7,1907878556),(20000000,-20000000,1338,355581621)) v(a,b,s,r);
create temp table golden_oct as select * from (values (0,0,527,397),(1,0,567,488),(-1,-1,612,648),(100,-250,2913,2759),(-12345,6789,1894,2122),(33554,-4000,2473,1672),(15,16,1015,430),(-16,-17,1789,2242)) v(x,z,o6,o4);
create temp table golden_height as select * from (values (0,0,56),(1,0,57),(-1,-1,57),(100,-250,80),(-12345,6789,71),(33554,-4000,75),(15,16,60),(-16,-17,70)) v(x,z,h);
create temp table golden_block as select * from (values (0,-64,0,4),(0,-40,0,1),(0,-17,0,1),(0,0,0,1),(0,20,0,1),(0,31,0,1),(0,55,0,5),(0,61,0,6),(0,62,0,6),(0,63,0,0),(0,64,0,0),(0,70,0,0),(0,95,0,0),(-1,-64,-1,4),(-1,-40,-1,1),(-1,-17,-1,1),(-1,0,-1,1),(-1,20,-1,1),(-1,31,-1,1),(-1,55,-1,5),(-1,61,-1,6),(-1,62,-1,6),(-1,63,-1,0),(-1,64,-1,0),(-1,70,-1,0),(-1,95,-1,0),(100,-64,-250,4),(100,-40,-250,1),(100,-17,-250,1),(100,0,-250,1),(100,20,-250,1),(100,31,-250,1),(100,55,-250,1),(100,61,-250,1),(100,62,-250,1),(100,63,-250,1),(100,64,-250,1),(100,70,-250,1),(100,95,-250,0)) v(x,y,z,s);
create temp table golden_chunk as select * from (values (0,0,18608,'51c4b16cccff9f4f8295e1a09fd238d985c44370f86eea6e2364ffde2e8d03d3'),(-1,-1,18612,'d616be5bab982bf02a8aad3c2eb7c468c3d106dd546ecd31b7dafe8a6ed840b6'),(5,-7,18608,'67ac2796b86717e6c688282bf18198e09e37063cb1d16f9c446e53f39fecba46'),(-300,120,18608,'96e469e2b99bee2a03eaa0e043f0e47216d48ac548759d3fab14fd99a976037a')) v(cx,cz,len,sha);
create temp table golden_varint as select * from (values (0,'00'),(127,'7f'),(128,'8001'),(300,'ac02'),(2097151,'ffff7f'),(2147483647,'ffffffff07')) v(n,hex);
select mct.ok('golden hash2 (int overload)', (select bool_and(mc.hash2(a, b, s) = r) from golden_hash2));
select mct.ok('golden hash2 (bigint overload)', (select bool_and(mc.hash2(a::bigint, b::bigint, s::bigint) = r) from golden_hash2));
select mct.ok('hash2 overloads agree at the int extremes',
              mc.hash2(2147483647, -2147483647, 2147483647) = mc.hash2(2147483647::bigint, -2147483647::bigint, 2147483647::bigint)
          and mc.hash2(-2147483648, -2147483648, -2147483648) = mc.hash2(-2147483648::bigint, -2147483648::bigint, -2147483648::bigint));
select mct.ok('golden oct (both octaves)', (select bool_and(mc.oct(x, z, 6, 1337) = o6 and mc.oct(x, z, 4, 1338) = o4) from golden_oct));
select mct.ok('golden height', (select bool_and(mc.height(x, z) = h) from golden_height));
select mct.ok('golden block_at (39 points)', (select bool_and(mc.block_at(x, y, z) = s) from golden_block));
select mct.ok('golden varint', (select bool_and(encode(mc.varint(n), 'hex') = hex) from golden_varint));
select mct.ok('varint == independent loop (all byte lengths)',
              (select bool_and(mc.varint(n) = mct.varint_ref(n)) from unnest(array[0,1,127,128,255,16383,16384,2097151,2097152,268435455,268435456,2147483647]) n));
select mct.ok('round() is rint (half to even)', round(0.5::float8) = 0 and round(1.5::float8) = 2 and round(2.5::float8) = 2 and round(-2.5::float8) = -2 and round(-0.5::float8) = 0);
select mct.ok('f64be/f32be round trip', mc.f64be(float8send(-123456.789012345), 0) = -123456.789012345 and mc.f64be(float8send(1e-310), 0) = 1e-310
              and mc.f32be(float4send(-33.3::float4), 0) = -33.3::float4 and mc.f64be('\x00'::bytea || float8send(0.1), 1) = 0.1);

select mc.reset_world() \g /dev/null
select mc.gen_chunk(0, 0), mc.gen_chunk(-1, -1), mc.gen_chunk(5, -7), mc.gen_chunk(-300, 120) \g /dev/null
select mct.ok('golden chunk payload length and sha256 (4 chunks)',
              (select count(*) = 4 and bool_and(length(mc.chunk_payload(cx, cz)) = len and encode(sha256(mc.chunk_payload(cx, cz)), 'hex') = sha) from golden_chunk));
select mct.ok('golden block_at read back from the generated world',
              (select bool_and(mc.get_block(x, y, z) = s) from golden_block where (x >> 4, z >> 4) in ((0, 0), (-1, -1))));
select mct.ok('chunk_heights == height() for 4 chunks',
              (select bool_and((mc.chunk_heights(cx, cz))[z * 16 + x + 1] = mc.height(cx * 16 + x, cz * 16 + z))
                 from golden_chunk, generate_series(0, 15) z, generate_series(0, 15) x));
select mct.ok('generated chunk: 24 sections, version 0', (select count(*) = 24 from mc.chunk_section where cx = 0 and cz = 0) and (select version = 0 from mc.chunk where cx = 0 and cz = 0));
select mc.gen_chunk(0, 0) \g /dev/null
select mct.ok('gen_chunk twice is a no-op', (select count(*) = 24 from mc.chunk_section where cx = 0 and cz = 0));
select mct.ok('gen_chunk == block_at, every block of chunks (0,0) and (-1,-1)',
              (select count(*) = 0 from (select cx, cz from (values (0, 0), (-1, -1)) c(cx, cz)) c, generate_series(0, 15) lx, generate_series(-64, 319) y, generate_series(0, 15) lz
                where mc.get_block(c.cx * 16 + lx, y, c.cz * 16 + lz) <> mc.block_at(c.cx * 16 + lx, y, c.cz * 16 + lz)));
select mct.ok('generated sections: sorted distinct palette, bits rule, block_count, data length, blob == independent blob',
              (select bool_and(
                  palette = (select array_agg(distinct p order by p) from unnest(palette) p)
                  and bits = (case when cardinality(palette) = 1 then 0 else greatest(4, ceil(log(2, cardinality(palette)))::int) end)
                  and length(data) = (case when bits = 0 then 0 else ((4096 + 64 / bits - 1) / (64 / bits)) * 8 end)
                  and block_count = (select count(*) from unnest(mc.unpack(bits, data)) e where palette[e + 1] <> 0)
                  and (bits = 0 or data = mct.pack_ref(mc.unpack(bits, data), bits))
                  and mc.section_blob(block_count, bits, palette, data) = mct.blob_ref(block_count, bits, palette, data))
                 from mc.chunk_section));
select mct.ok('all-air sections are stored as palette [0], bits 0, count 0', (select count(*) >= 10 and bool_and(palette = array[0] and bits = 0 and data = '\x') from mc.chunk_section where cx = 0 and cz = 0 and block_count = 0));
select mct.ok('get_block outside the world / ungenerated chunk is air', mc.get_block(0, -65, 0) = 0 and mc.get_block(0, 320, 0) = 0 and mc.get_block(1000, 60, 1000) = 0);
select mct.ok('gen_area returns the number of chunks generated', mc.gen_area(0, 0, 2, 1) = 5 and mc.gen_area(0, 0, 2, 1) = 0);

------------------------------------------------------------------------------------------------ set_block and the palette rules (SPEC 3, 5)
select mc.reset_world() \g /dev/null
select mc.gen_area(0, 0, 1, 0) \g /dev/null
select mc.set_block(3, 100, 4, 0) as a, mc.set_block(-100, 100, 4, 1) as b, mc.set_block(3, 320, 4, 1) as c, mc.set_block(3, -65, 4, 1) as d \gset
select mct.ok('set_block: same state / missing chunk / y out of range -> false', not :'a'::boolean and not :'b'::boolean and not :'c'::boolean and not :'d'::boolean);
select mct.ok('set_block no-ops: no event, no version bump', (select count(*) = 0 from mc.block_event) and (select version = 0 from mc.chunk where cx = 0 and cz = 0));
select mc.set_block(3, 100, 4, 1) as a \gset
select mct.ok('set_block into a single-value section -> true', :'a'::boolean);
select mct.ok('single-value section becomes palette [0,1], bits 4, 2048 data bytes, count 1',
              (select palette = array[0, 1] and bits = 4 and length(data) = 2048 and block_count = 1 from mc.chunk_section where cx = 0 and cz = 0 and sy = 6));
select mct.ok('version bumped once, only for the touched chunk', (select version from mc.chunk where cx = 0 and cz = 0) = 1 and (select version from mc.chunk where cx = 1 and cz = 0) = 0);
select mct.ok('get_block sees the edit and only the edit', mc.get_block(3, 100, 4) = 1 and mc.get_block(4, 100, 4) = 0 and mc.get_block(3, 101, 4) = 0);
select mct.ok('one block event (x,y,z,old,new)', (select count(*) = 1 and bool_and(kind = 'block' and (x, y, z, old_state, new_state) = (3, 100, 4, 0, 1)) from mc.drain_block_events()));
select mct.ok('drain removed the events', (select count(*) = 0 from mc.block_event));

-- grow the palette one state at a time at distinct positions: 4 bits up to 16 entries, repack to 5 bits at the 17th, never reorder
select mc.set_block(i, 100, 0, i + 2) from generate_series(0, 13) i \g /dev/null
select mct.ok('palette of 16 entries still 4 bits', (select cardinality(palette) = 16 and bits = 4 and length(data) = 2048 and palette = array[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15] from mc.chunk_section where cx = 0 and cz = 0 and sy = 6));
select mc.set_block(14, 100, 0, 16) \g /dev/null
select mct.ok('17th entry repacks to 5 bits (342 longs = 2736 bytes), palette order preserved',
              (select cardinality(palette) = 17 and bits = 5 and length(data) = 2736 and palette[17] = 16 and palette[1:3] = array[0,1,2] from mc.chunk_section where cx = 0 and cz = 0 and sy = 6));
select mc.set_block(i, 100, 1, i + 17) from generate_series(0, 3) i \g /dev/null
select mct.ok('21 entries, 5 bits, count = number of non-air', (select cardinality(palette) = 21 and bits = 5 and block_count = 1 + 14 + 1 + 4 from mc.chunk_section where cx = 0 and cz = 0 and sy = 6));
select mct.ok('every placed block reads back after the repack',
              (select bool_and(mc.get_block(i, 100, 0) = i + 2) from generate_series(0, 13) i) and mc.get_block(14, 100, 0) = 16 and mc.get_block(3, 100, 4) = 1
              and (select bool_and(mc.get_block(i, 100, 1) = i + 17) from generate_series(0, 3) i) and mc.get_block(15, 100, 0) = 0);
select mct.ok('5-bit data == independent packing of the unpacked entries, entries equal palette indices of the edits',
              (select data = mct.pack_ref(mc.unpack(bits, data), bits)
                  and (mc.unpack(bits, data))[(((100 & 15) << 8) | (4 << 4) | 3) + 1] = 1
                  and (mc.unpack(bits, data))[(((100 & 15) << 8) | (1 << 4) | 3) + 1] = 20
                  and (mc.unpack(bits, data))[(((100 & 15) << 8) | (0 << 4) | 5) + 1] = 7
                 from mc.chunk_section where cx = 0 and cz = 0 and sy = 6));
select mct.ok('blob of the edited 5-bit section == independent blob', (select mc.section_blob(block_count, bits, palette, data) = mct.blob_ref(block_count, bits, palette, data) from mc.chunk_section where cx = 0 and cz = 0 and sy = 6));
select mc.set_block(3, 100, 4, 0) as a \gset
select mct.ok('overwriting to air keeps the palette (never shrinks) and lowers block_count',
              :'a'::boolean and (select cardinality(palette) = 21 and bits = 5 and block_count = 19 from mc.chunk_section where cx = 0 and cz = 0 and sy = 6));
select mct.ok('events of the series: 14+1+4+1, in call order, old values right', (select count(*) = 20 and (array_agg(new_state order by id))[1] = 2 and bool_and(old_state = 0) filter (where id < (select max(id) from mc.block_event) + 1 and new_state <> 0) is not null and (array_agg(old_state order by id))[20] = 1 and (array_agg(new_state order by id))[20] = 0 from mc.drain_block_events()));

-- set_blocks vs set_block: the same random edit sequence (with duplicates, no-ops, many sections) on the same starting chunk, once as single edits and once as one call
select mc.drain_block_events() \g /dev/null
create temp table snap0 as select * from mc.chunk_section where cx = 0 and cz = 0;
select version as ver0 from mc.chunk where cx = 0 and cz = 0 \gset
select setseed(0.42) \g /dev/null
create temp table edits as
  select n, (random() * 15)::int as lx, (random() * 150 - 64)::int as y, (random() * 15)::int as lz,
         (case when random() < 0.3 then 0 else (random() * 20)::int end) as s
    from generate_series(1, 4000) n;
select count(*) filter (where mc.set_block(lx, y, lz, s)) as changed_single from (select * from edits order by n) e \gset
create temp table snap1 as select * from mc.chunk_section where cx = 0 and cz = 0;
create temp table ev1 as select * from mc.drain_block_events();
update mc.chunk_section s set block_count = o.block_count, palette = o.palette, bits = o.bits, data = o.data from snap0 o where s.cx = o.cx and s.cz = o.cz and s.sy = o.sy;
update mc.chunk set version = :ver0 where cx = 0 and cz = 0;
select mc.set_blocks(array_agg(lx order by n), array_agg(y order by n), array_agg(lz order by n), array_agg(s order by n)) as changed_bulk from edits \gset
select mct.ok('set_blocks returns the number of changed blocks == single set_block calls', :changed_single = :changed_bulk and :changed_bulk > 1000);
select mct.ok('set_blocks leaves every section byte-identical to the single-edit sequence (palette, bits, data, count)',
              (select count(*) = 24 and bool_and(a.palette = b.palette and a.bits = b.bits and a.data = b.data and a.block_count = b.block_count)
                 from mc.chunk_section a join snap1 b on b.cx = a.cx and b.cz = a.cz and b.sy = a.sy where a.cx = 0 and a.cz = 0));
select mct.ok('set_blocks bumps the chunk version once per call (single edits bump per change)', (select version = :ver0 + 1 from mc.chunk where cx = 0 and cz = 0));
select mct.ok('set_blocks event stream == single-edit event stream (kind, position, old, new, order)',
              (select count(*) = :changed_bulk and bool_and(e.x = f.x and e.y = f.y and e.z = f.z and e.old_state = f.old_state and e.new_state = f.new_state and e.kind = f.kind)
                 from (select *, row_number() over (order by id) rn from mc.drain_block_events()) e
                 join (select *, row_number() over (order by id) rn from ev1) f using (rn)));
select mc.drain_block_events() \g /dev/null
select version as v0 from mc.chunk where cx = 0 and cz = 0 \gset
select mc.get_block(0, 10, 0) as o0, mc.get_block(1, 10, 0) as o1, mc.get_block(2, 10, 0) as o2 \gset
select mc.set_blocks(array[0, 1, 2, 0, 5000, 3], array[10, 10, 10, 10, 10, 400], array[0, 0, 0, 0, 0, 0], array[3, 3, 3, 4, 3, 3]) as n \gset
select mct.ok('set_blocks: duplicates apply in order; missing chunk and y out of range are skipped', :n = 4 and mc.get_block(0, 10, 0) = 4 and mc.get_block(1, 10, 0) = 3 and mc.get_block(3, 400, 0) = 0);
select mct.ok('set_blocks events in array order with sequential old values (the duplicate sees 3)',
              (select count(*) = 4 and array_agg(old_state order by id) = array[:o0, :o1, :o2, 3] and array_agg(new_state order by id) = array[3, 3, 3, 4] from mc.drain_block_events()));
select mct.ok('set_blocks: one version bump for the call', (select version = :v0 + 1 from mc.chunk where cx = 0 and cz = 0));
select mct.ok('set_blocks no-op call changes nothing', mc.set_blocks(array[0], array[10], array[0], array[4]) = 0 and (select version = :v0 + 1 from mc.chunk where cx = 0 and cz = 0) and (select count(*) = 0 from mc.block_event));

------------------------------------------------------------------------------------------------ fill (SPEC 3, 5)
select mc.reset_world() \g /dev/null
select mc.gen_area(-1, -1, 1, 1) \g /dev/null
select mc.fill(0, 96, 0, 15, 111, 15, 20) as n \gset
select mct.ok('fill covering a whole air section: n = 4096', :n = 4096);
select mct.ok('whole-section fill collapses to palette [state], bits 0, no data, count 4096',
              (select palette = array[20] and bits = 0 and data = '\x' and block_count = 4096 from mc.chunk_section where cx = 0 and cz = 0 and sy = 6));
select mct.ok('whole-section fill: one fill event (lowest corner, old -1, new, count) and one version bump',
              (select count(*) = 1 and bool_and(kind = 'fill' and (x, y, z, old_state, new_state, cnt) = (0, 96, 0, -1, 20, 4096)) from mc.drain_block_events())
              and (select version = 1 from mc.chunk where cx = 0 and cz = 0));
select mc.fill(15, 111, 15, 0, 96, 0, 20) as n \gset
select mct.ok('fill with nothing to change: 0, no event, no version bump, section untouched (corners in any order)',
              :n = 0 and (select count(*) = 0 from mc.block_event) and (select version = 1 from mc.chunk where cx = 0 and cz = 0));
select mc.fill(0, 96, 0, 15, 111, 15, 0) as n \gset
select mct.ok('fill air over a full section', :n = 4096 and (select palette = array[0] and bits = 0 and block_count = 0 from mc.chunk_section where cx = 0 and cz = 0 and sy = 6));
select mc.drain_block_events() \g /dev/null
select count(*) as nstone from generate_series(0, 15) x, generate_series(0, 15) y, generate_series(0, 15) z where mc.get_block(x, y, z) = 1 \gset
select mc.fill(0, 0, 0, 15, 15, 15, 1) as n \gset
select mct.ok('whole fill of a stone section: n = 4096 - already stone (hex nibble counting)', :n = 4096 - :nstone and (select palette = array[1] and bits = 0 and block_count = 4096 from mc.chunk_section where cx = 0 and cz = 0 and sy = 0));
select mct.ok('whole fill: event count = n', (select count(*) = 1 and bool_and(cnt = 4096 - :nstone and (x, y, z) = (0, 0, 0)) from mc.drain_block_events()));

-- partial fill across a chunk boundary: counts, per-section events, per-chunk version bumps
select count(*) as expect_n from generate_series(-8, 8) x, generate_series(60, 70) y, generate_series(0, 3) z where mc.get_block(x, y, z) <> 20 \gset
create temp table expect_ev as
  select cx, sy, greatest(-8, cx * 16) as x, greatest(60, sy * 16) as y, 0 as z, count(*) as cnt
    from (select x >> 4 as cx, y >> 4 as sy from generate_series(-8, 8) x, generate_series(60, 70) y, generate_series(0, 3) z where mc.get_block(x, y, z) <> 20) q
   group by cx, sy;
select version as vm1 from mc.chunk where cx = -1 and cz = 0 \gset
select version as v0 from mc.chunk where cx = 0 and cz = 0 \gset
select mc.fill(8, 70, 3, -8, 60, 0, 20) as n \gset
select mct.ok('partial fill across chunks: n == brute force', :n = :expect_n and :n > 0);
select mct.ok('partial fill: box now holds the state, neighbours untouched',
              (select bool_and(mc.get_block(x, y, z) = 20) from generate_series(-8, 8) x, generate_series(60, 70) y, generate_series(0, 3) z)
              and mc.get_block(9, 65, 1) <> 20 and mc.get_block(-9, 65, 1) <> 20 and mc.get_block(0, 65, 4) <> 20 and mc.get_block(0, 71, 1) <> 20);
select mct.ok('partial fill: one event per touched section = (lowest corner of box ∩ section, old -1, new, count of changed blocks)',
              (select count(*) = (select count(*) from expect_ev) and count(*) = 4
                      and bool_and(e.kind = 'fill' and e.old_state = -1 and e.new_state = 20 and (e.x, e.y, e.z, e.cnt) = (x.x, x.y, x.z, x.cnt))
                 from mc.drain_block_events() e join expect_ev x on e.x >> 4 = x.cx and e.y >> 4 = x.sy and e.z >> 4 = 0));
select mct.ok('partial fill: each touched chunk bumped exactly once, untouched chunks not',
              (select version = :vm1 + 1 from mc.chunk where cx = -1 and cz = 0) and (select version = :v0 + 1 from mc.chunk where cx = 0 and cz = 0)
              and (select version = 0 from mc.chunk where cx = 1 and cz = 1));

-- fill clipped to the generated world and to y in [-64, 319]: everything in the 3x3 chunk area becomes gravel
select coalesce(sum(n), 0) as ngravel from mc.count_states(-16, -16, 31, 31) where state = 14 \gset
select mc.fill(-40, -100, -40, 40, 400, 40, 14) as n \gset
select mct.ok('big clipped fill: n = 48*48*384 - blocks that were already gravel', :n = 48 * 48 * 384 - :ngravel);
select mct.ok('big fill: every section of the 9 chunks is [14] with bits 0, count 4096',
              (select count(*) = 9 * 24 and bool_and(palette = array[14] and bits = 0 and block_count = 4096 and data = '\x') from mc.chunk_section));
select mct.ok('big fill: events carry count = n in total, kind fill', (select sum(cnt) = :n and bool_and(kind = 'fill') from mc.drain_block_events()));
select mct.ok('count_states after the big fill', (select count(*) = 1 and bool_and(state = 14 and n = 48 * 48 * 384) from mc.count_states(-16, -16, 31, 31)) and (select count(*) = 1 and bool_and(n = 10 * 7 * 384) from mc.count_states(0, 0, 9, 6)));
select mc.fill(0, -64, 0, 15, -64, 15, 4) as n \gset
select mct.ok('single layer fill: n=256 partial section edit', :n = 256 and mc.get_block(3, -64, 3) = 4 and mc.get_block(3, -63, 3) = 14);

-- partial fill == set_blocks of the same positions (byte identical sections), incl. growth of the palette across 16 -> 17 (bits 4 -> 5) and from a single value
select mc.reset_world() \g /dev/null
select mc.gen_area(0, 0, 0, 0) \g /dev/null
create temp table snapA as select * from mc.chunk_section where cx = 0 and cz = 0;
select mc.fill(3, 20, 1, 12, 45, 14, 17) as nf \gset
create temp table snapF as select * from mc.chunk_section where cx = 0 and cz = 0;
select count(*) as ev_f from mc.drain_block_events() \gset
update mc.chunk_section s set block_count = o.block_count, palette = o.palette, bits = o.bits, data = o.data from snapA o where s.cx = o.cx and s.cz = o.cz and s.sy = o.sy;
select mc.set_blocks(array_agg(x order by x, z, y), array_agg(y order by x, z, y), array_agg(z order by x, z, y), array_agg(17 order by x, z, y)) as ns
  from generate_series(3, 12) x, generate_series(20, 45) y, generate_series(1, 14) z \gset
select mct.ok('partial fill n == set_blocks n, sections byte-identical (palette order, bits, data, count)',
              :nf = :ns and :nf > 0
              and (select count(*) = 24 and bool_and(a.palette = b.palette and a.bits = b.bits and a.data = b.data and a.block_count = b.block_count)
                     from mc.chunk_section a join snapF b on b.cx = a.cx and b.cz = a.cz and b.sy = a.sy where a.cx = 0 and a.cz = 0));
select mc.drain_block_events() \g /dev/null
select mc.set_blocks(array_agg(i order by i), array_fill(100, array[15]), array_fill(15, array[15]), array_agg(i + 1 order by i)) from generate_series(0, 14) i \g /dev/null
create temp table snapB as select * from mc.chunk_section where cx = 0 and cz = 0;
select mct.ok('section with 16 entries is 4 bits', (select cardinality(palette) = 16 and bits = 4 from snapB where sy = 6));
select mc.fill(0, 96, 0, 15, 100, 7, 20) as nf \gset
create temp table snapC as select * from mc.chunk_section where cx = 0 and cz = 0;
update mc.chunk_section s set block_count = o.block_count, palette = o.palette, bits = o.bits, data = o.data from snapB o where s.cx = o.cx and s.cz = o.cz and s.sy = o.sy;
select mc.set_blocks(array_agg(x order by x, z, y), array_agg(y order by x, z, y), array_agg(z order by x, z, y), array_agg(20 order by x, z, y)) as ns
  from generate_series(0, 15) x, generate_series(96, 100) y, generate_series(0, 7) z \gset
select mct.ok('fill growing the palette to 17 entries: bits 5, == set_blocks, entries intact',
              :nf = :ns and (select bits = 5 and cardinality(palette) = 17 and palette[17] = 20 and length(data) = 2736 from snapC where sy = 6)
              and (select a.palette = b.palette and a.bits = b.bits and a.data = b.data and a.block_count = b.block_count from mc.chunk_section a join snapC b using (cx, cz, sy) where sy = 6 and cx = 0 and cz = 0)
              and mc.get_block(3, 100, 15) = 4 and mc.get_block(14, 100, 15) = 15 and mc.get_block(2, 97, 3) = 20);
-- fill of a 5-bit section (bits 5, partial) and whole 5-bit section fill (generic unpack count)
select mc.fill(0, 101, 0, 5, 103, 5, 21) as n \gset
select mct.ok('partial fill of a 5-bit section', :n = 6 * 3 * 6 and (select bits = 5 and cardinality(palette) = 18 from mc.chunk_section where cx = 0 and cz = 0 and sy = 6));
select mc.fill(0, 96, 0, 15, 111, 15, 20) as n \gset
select count(*) as n20 from generate_series(0, 15) x, generate_series(96, 111) y, generate_series(0, 15) z where false \gset
select mct.ok('whole fill of a 5-bit section collapses to [20], bits 0', :n > 0 and (select palette = array[20] and bits = 0 and data = '\x' from mc.chunk_section where cx = 0 and cz = 0 and sy = 6));
select mc.drain_block_events() \g /dev/null
select mct.ok('chunk_packet = varint(len) || 0x2c || i32 cx || i32 cz || payload',
              mc.chunk_packet(0, 0) = mct.varint_ref(9 + length(mc.chunk_payload(0, 0))) || '\x2c'::bytea || '\x0000000000000000'::bytea || mc.chunk_payload(0, 0));
select mct.ok('chunk_packet cached with the chunk version', (select c.version = k.version and k.packet = mc.chunk_packet(0, 0) from mc.chunk c join mc.chunk_cache k using (cx, cz) where cx = 0 and cz = 0));
select mct.ok('chunk_packet of a missing chunk is null', mc.chunk_packet(77, 77) is null);
select mc.chunk_packet(0, 0) as pkt0 \gset
select mc.set_block(1, 5, 1, 0) as a \gset
select mct.ok('edit makes the cache stale (cached version < chunk version)', :'a'::boolean and (select k.version < c.version from mc.chunk c join mc.chunk_cache k using (cx, cz) where cx = 0 and cz = 0));
select mc.chunk_packet(0, 0) as pkt1 \gset
select mct.ok('stale packet is rebuilt and differs; cache row updated; framing still right',
              :'pkt1'::bytea <> :'pkt0'::bytea and (select k.version = c.version and k.packet = :'pkt1'::bytea from mc.chunk c join mc.chunk_cache k using (cx, cz) where cx = 0 and cz = 0)
              and :'pkt1'::bytea = mct.varint_ref(9 + length(mc.chunk_payload(0, 0))) || '\x2c0000000000000000'::bytea || mc.chunk_payload(0, 0));
select mct.ok('second call is a cache hit (same bytes, same cache version)', mc.chunk_packet(0, 0) = :'pkt1'::bytea);
select mc.gen_area(-3, -2, 2, 1) \g /dev/null
select mc.set_blocks(array[1, 17, -20, 40], array[70, 71, 72, 73], array[1, 2, 3, -30], array[5, 6, 7, 8]) \g /dev/null
select mct.ok('world_hash == sha256 of the independently concatenated (i32 cx, i32 cz, i16 sy, blob)',
              mc.world_hash() = sha256((select string_agg(int4send(cx) || int4send(cz) || int2send(sy::int2) || mct.blob_ref(block_count, bits, palette, data), '\x'::bytea order by cx, cz, sy) from mc.chunk_section)));
select mc.world_hash() as h0 \gset
select mc.set_block(0, 0, 0, 3) \g /dev/null
select mct.ok('world_hash changes with an edit', mc.world_hash() <> :'h0'::bytea);
select mct.ok('world_hash is 32 bytes and reproducible', length(mc.world_hash()) = 32 and mc.world_hash() = mc.world_hash());

------------------------------------------------------------------------------------------------ count_states / find_state vs brute force
select mc.reset_world() \g /dev/null
select mc.gen_area(0, 0, 2, 1) \g /dev/null
select mc.set_blocks(array_agg(i), array_fill(100, array[20]), array_fill(5, array[20]), array_agg(i + 1)) from generate_series(0, 19) i \g /dev/null
create temp table bf as select x, y, z, mc.get_block(x, y, z) as s from generate_series(0, 31) x, generate_series(-64, 319) y, generate_series(0, 31) z;
select mct.ok('chunk (0,0) has a 5-bit section (fallback path exercised)', (select bits = 5 from mc.chunk_section where cx = 0 and cz = 0 and sy = 6));
select mct.ok('count_states, whole chunks (hex fast path + 5-bit fallback + single value) == brute force',
              (select count(*) = 0 from ((select state, n from mc.count_states(0, 0, 31, 31)) except (select s, count(*) from bf group by 1)) q)
              and (select count(*) = 0 from ((select s, count(*) from bf group by 1) except (select state, n from mc.count_states(0, 0, 31, 31))) q));
select mct.ok('count_states, partial window across a chunk border (reversed corners) == brute force',
              (select count(*) = 0 from ((select state, n from mc.count_states(28, 20, 5, 3)) except (select s, count(*) from bf where x between 5 and 28 and z between 3 and 20 group by 1)) q)
              and (select sum(n) = 24 * 18 * 384 from mc.count_states(5, 3, 28, 20)));
select mct.ok('count_states ignores ungenerated chunks', (select sum(n) = 16 * 16 * 384 from mc.count_states(-100, -100, 15, 15)));
select mct.ok('find_state == brute force, ordered by (x,y,z): diamond, coal, a 5-bit-section state, none',
              (select coalesce(array_agg(array[x, y, z] order by x, y, z), '{}') from mc.find_state(17, 3, 2, 28, 29))
                = (select coalesce(array_agg(array[x, y, z] order by x, y, z), '{}') from bf where s = 17 and x between 3 and 28 and z between 2 and 29)
              and (select count(*) > 0 from mc.find_state(15, 3, 2, 28, 29))
              and (select coalesce(array_agg(array[x, y, z] order by x, y, z), '{}') from mc.find_state(15, 3, 2, 28, 29))
                = (select coalesce(array_agg(array[x, y, z] order by x, y, z), '{}') from bf where s = 15 and x between 3 and 28 and z between 2 and 29)
              and (select array_agg(array[x, y, z]) from mc.find_state(7, 0, 0, 15, 15)) = (select array_agg(array[x, y, z] order by x, y, z) from bf where s = 7 and x < 16 and z < 16)
              and (select count(*) = 0 from mc.find_state(3, 1000, 1000, 1010, 1010)));

------------------------------------------------------------------------------------------------ tick: hand-written expectations (bytes spelled out from SPEC 6)
create function mct.drain_hex() returns text[] language sql as $$
  select coalesce(array_agg(conn || ':' || encode(data, 'hex') order by conn || ':' || encode(data, 'hex')), '{}') from mc.outbox_drain() $$;
create function mct.srt(a text[]) returns text[] language sql immutable as $$ select array_agg(x order by x) from unnest(a) x $$;
create function mct.uuid_hex(e int) returns text language sql as $$ select md5('p' || e) $$;
create function mct.push1(conn int, x float8, y float8, z float8, yaw float4, pitch float4, og boolean) returns void language sql as $$
  select mc.inbox_push(array[conn], array[mc.move_payload(x, y, z, yaw, pitch, og)]) $$;

select mc.drain_block_events() \g /dev/null
select mc.reset_players() \g /dev/null
select mc.join_bulk(array[1, 2], array[0.0, 49.0], array[64.0, 64.0], array[0.0, 0.0]) \g /dev/null
select mc.vis_init() as vp \gset
select mct.ok('vis_init: 49 blocks apart is not visible, no packets', :vp = 0 and mc.visible_pairs() = 0 and (select count(*) = 0 from mc.outbox) and mc.game_time() = 0);
select mct.ok('join_bulk: uuid = md5("p"+eid) raw, sent_q = rint(pos*4096), chunk, yaw/pitch 0, on_ground',
              (select uuid = decode(md5('p2'), 'hex') and sent_qx = 49 * 4096 and sent_qy = 64 * 4096 and chunk_x = 3 and chunk_z = 0 and yaw = 0 and pitch = 0 and on_ground from mc.player where eid = 2));

-- tick 1: P2 moves into range -> enter, add_entity both ways at final positions (yaw 90 -> angle 64)
select mct.push1(2, 45, 64, 0, 90, 0, true) \g /dev/null
select mc.server_tick() as t \gset
select mct.ok('tick 1 returns game_time 1', :t = 1 and mc.game_time() = 1);
select mct.ok('enter: add_entity(2) -> conn 1, add_entity(1) -> conn 2 (exact bytes)',
              mct.drain_hex() = mct.srt(array['1:2c0102' || mct.uuid_hex(2) || '4046800000000000' || '4050000000000000' || '0000000000000000' || '4000',
                                      '2:2c0101' || mct.uuid_hex(1) || '0000000000000000' || '4050000000000000' || '0000000000000000' || '0000']));
select mct.ok('enter: visible pair stored', mc.visible_pairs() = 1 and (select count(*) = 2 from mc.visible));
-- tick 2: P2 steps out to 49.5 -> leave, remove_entities both ways
select mct.push1(2, 49.5, 64, 0, 90, 0, true) \g /dev/null
select mc.server_tick() \g /dev/null
select mct.ok('leave: remove_entities(2) -> conn 1, remove_entities(1) -> conn 2', mct.drain_hex() = mct.srt(array['1:03020102', '2:03020101']) and mc.visible_pairs() = 0);
-- tick 3: back in range (sent_q becomes 45*4096); tick 4: retained small move -> move_entity to the viewer only
select mct.push1(2, 45, 64, 0, 90, 0, true) \g /dev/null
select mc.server_tick() \g /dev/null
select count(*) as n from mc.outbox_drain() \gset
select mct.push1(2, 44, 64, 0, 180, -90, false) \g /dev/null
select mc.server_tick() \g /dev/null
select mct.ok('retained: move_entity(dx=-4096 i16, dy 0, dz 0, yaw 128, pitch 192, on_ground 0) -> conn 1 only',
              mct.drain_hex() = array['1:0b0302' || 'f000' || '0000' || '0000' || '80' || 'c0' || '00']);
-- tick 5: 9 blocks = 36864 quantised units > 32767 -> teleport_entity with the absolute position
select mct.push1(2, 35, 64, 0, 180, -90, false) \g /dev/null
select mc.server_tick() \g /dev/null
select mct.ok('retained, |dq| > 32767: teleport_entity (f64 x y z, angles, on_ground) -> conn 1',
              mct.drain_hex() = array['1:1d0402' || '4041800000000000' || '4050000000000000' || '0000000000000000' || '80' || 'c0' || '00']);
-- tick 6: a move of 10.5 blocks is rejected (no state change, no packets, consumed); 10.0 exactly is accepted (and is a teleport: 40960 units)
select mc.player_digest() as dg0 \gset
select mct.push1(2, 45.5, 64, 0, 0, 0, true) \g /dev/null
select mc.server_tick() \g /dev/null
select mct.ok('rejected move (> 10): nothing changes, nothing sent, inbox consumed',
              mc.player_digest() = :dg0 and (select count(*) = 0 from mc.outbox) and (select count(*) = 0 from mc.inbox) and (select x = 35 from mc.player where eid = 2));
select mct.push1(2, 45, 64, 0, 0, 0, true) \g /dev/null
select mc.server_tick() \g /dev/null
select mct.ok('move of exactly 10 blocks is accepted; dq = 40960 -> teleport_entity',
              mct.drain_hex() = array['1:1d0402' || '4046800000000000' || '4050000000000000' || '0000000000000000' || '00' || '00' || '01']);
-- tick 8: both players move in the same tick: the pair is handled once, each sees the other's move; distance exactly 48.0 stays visible (<= 2304.0)
select mc.inbox_push(array[1, 2], array[mc.move_payload(3, 64, 0, 0, 0, true), mc.move_payload(51, 64, 0, 0, 0, true)]) \g /dev/null
select mc.server_tick() \g /dev/null
select mct.ok('both moved: one retained pair, two packets (not four); distance exactly 48 is visible',
              mct.drain_hex() = mct.srt(array['1:0b0302' || '6000' || '0000' || '0000' || '0000' || '01',    -- about P2: (51-45)*4096 = 24576
                                      '2:0b0301' || '3000' || '0000' || '0000' || '0000' || '01']) and mc.visible_pairs() = 1);
-- tick 9: just beyond 48 -> leave
select mct.push1(2, 51.0001, 64, 0, 0, 0, true) \g /dev/null
select mc.server_tick() \g /dev/null
select mct.ok('48.0001 blocks apart: leave', mct.drain_hex() = mct.srt(array['1:03020102', '2:03020101']) and mc.visible_pairs() = 0);
-- several packets of one conn in a tick: the last valid one counts; unknown conn ignored; invalid last does not shadow a valid earlier one
select mc.inbox_push(array[2, 2, 99, 1, 1], array[mc.move_payload(53, 64, 0, 0, 0, true), mc.move_payload(54, 64, 0, 0, 0, true), mc.move_payload(1, 1, 1, 0, 0, true),
                                                   mc.move_payload(4, 64, 0, 0, 0, true), mc.move_payload(400, 64, 0, 0, 0, true)]) \g /dev/null
select mc.server_tick() \g /dev/null
select mct.ok('duplicate packets: last valid per conn wins, unknown conn skipped',
              (select x = 54 from mc.player where eid = 2) and (select x = 4 from mc.player where eid = 1) and (select count(*) = 0 from mc.player where eid = 99));
select mct.drain_hex() \g /dev/null
-- players in chunks (0,0) and (4,0)
select mc.reset_players() \g /dev/null
select mc.join_bulk(array[1, 2], array[1.0, 70.0], array[64.0, 64.0], array[1.0, 1.0]) \g /dev/null
truncate mc.block_event restart identity;
insert into mc.block_event (kind, x, y, z, old_state, new_state, cnt) values
  ('block', 5, 70, 5, 0, 20, 0),                    -- chunk (0,0): both players
  ('fill', 176, 10, 0, -1, 7, 300),                  -- chunk (11,0): |4-11| = 7 for P2, 11 for P1 -> P2 only
  ('block', -1, -64, -1, 1, 0, 0),                   -- chunk (-1,-1): both
  ('fill', 200, 10, 0, -1, 7, 1);                    -- chunk (12,0): |4-12| = 8 -> P2 only (boundary), P1 12 -> none
select mc.server_tick() \g /dev/null
select mct.ok('block events: exact packets (i64 pos, varint state / count), in event order, only to players within 8 chunks',
              mct.drain_hex() = mct.srt(array[
                '1:0a05' || '0000014000005046' || '14',
                '1:0a05' || 'ffffffffffffffc0' || '00',
                '2:0a05' || '0000014000005046' || '14',
                '2:' || '0c06' || encode(int8send(176::bigint * 274877906944 + 0 * 4096 + 10), 'hex') || '07' || 'ac02',
                '2:0a05' || 'ffffffffffffffc0' || '00',
                '2:' || '0b06' || encode(int8send(200::bigint * 274877906944 + 0 * 4096 + 10), 'hex') || '07' || '01']));
select mct.ok('events were consumed', (select count(*) = 0 from mc.block_event));
select mct.ok('pkt_move: teleport branch at |dq| = 32768 and move branch at 32767, negative side too',
              mc.pkt_move(5, 32767, -32767, 0, 1, 2, 3, 0, 0, true) = '\x0b03057fff80010000000001'::bytea and substring(mc.pkt_move(5, 32768, 0, 0, 1, 2, 3, 0, 0, true) from 2 for 1) = '\x04'
              and substring(mc.pkt_move(5, 0, -32768, 0, 1, 2, 3, 0, 0, true) from 2 for 1) = '\x04' and substring(mc.pkt_move(5, 0, 0, 32768, 1, 2, 3, 0, 0, false) from 2 for 1) = '\x04');
select mct.ok('pos64 of negative coordinates is two''s complement masked: (-1,-64,-1) -> ff..c0', mc.pos64(-1, -64, -1) = '\xffffffffffffffc0');
select mct.ok('angle(): floor(deg*256/360) & 255 on the float4 value', mc.angle(90) = 64 and mc.angle(-90) = 192 and mc.angle(360) = 0 and mc.angle(-0.5) = 255 and mc.angle(0.1::float4) = 0 and mc.angle(450) = 64);

------------------------------------------------------------------------------------------------ tick: differential test against a brute-force oracle (all pairs, plain loops, own packet builders)
create table mct.o_p (eid int primary key, x float8, y float8, z float8, yaw float4, pitch float4, og boolean, sqx bigint, sqy bigint, sqz bigint, moved boolean default false);
create table mct.o_v (a int, b int, primary key (a, b));
create table mct.o_exp (conn int, data bytea);
create function mct.o_frame(body bytea) returns bytea language sql immutable as $$ select mct.varint_ref(length(body)) || body $$;
create function mct.o_angle(d float4) returns bytea language sql immutable as $$ select set_byte('\x00'::bytea, 0, (floor(d::float8 * 256.0 / 360.0)::bigint & 255)::int) $$;
-- round half to even without round()
create function mct.o_quant(x float8) returns bigint language plpgsql immutable as $$
declare v float8 := x * 4096; f float8 := floor(x * 4096);
begin
    if v - f < 0.5 then return f::bigint; elsif v - f > 0.5 then return f::bigint + 1;
    else return case when (f::bigint) % 2 = 0 then f::bigint else f::bigint + 1 end; end if;
end $$;
create function mct.o_add(p mct.o_p) returns bytea language sql immutable as $$
  select mct.o_frame('\x01'::bytea || mct.varint_ref(p.eid) || decode(md5('p' || p.eid), 'hex') || float8send(p.x) || float8send(p.y) || float8send(p.z) || mct.o_angle(p.yaw) || mct.o_angle(p.pitch)) $$;
create function mct.o_move(p mct.o_p) returns bytea language plpgsql immutable as $$
declare dx bigint := mct.o_quant(p.x) - p.sqx; dy bigint := mct.o_quant(p.y) - p.sqy; dz bigint := mct.o_quant(p.z) - p.sqz; og bytea := case when p.og then '\x01' else '\x00' end;
begin
    if abs(dx) <= 32767 and abs(dy) <= 32767 and abs(dz) <= 32767 then
        return mct.o_frame('\x03'::bytea || mct.varint_ref(p.eid) || substring(int4send(dx::int) from 3) || substring(int4send(dy::int) from 3) || substring(int4send(dz::int) from 3)
                           || mct.o_angle(p.yaw) || mct.o_angle(p.pitch) || og);
    end if;
    return mct.o_frame('\x04'::bytea || mct.varint_ref(p.eid) || float8send(p.x) || float8send(p.y) || float8send(p.z) || mct.o_angle(p.yaw) || mct.o_angle(p.pitch) || og);
end $$;
create function mct.o_sync() returns void language sql as $$
  truncate mct.o_p, mct.o_v;
  insert into mct.o_p select eid, x, y, z, yaw, pitch, on_ground, sent_qx, sent_qy, sent_qz, false from mc.player;
  insert into mct.o_v select viewer_eid, target_eid from mc.visible where viewer_eid < target_eid $$;
create function mct.o_digest() returns bigint language sql as $$
  select sum(eid::bigint * 1000003 + sqx * 7 + sqy * 13 + sqz * 17 + floor(x / 16)::bigint * 31 + floor(z / 16)::bigint * 37)::bigint from mct.o_p $$;

create function mct.o_tick(conns int[], xs float8[], ys float8[], zs float8[], yaws float4[], pitches float4[], ogs boolean[],
                           ev_kind text[], ev_x int[], ev_y int[], ev_z int[], ev_new int[], ev_cnt int[]) returns void language plpgsql as $$
declare
    n int; c int; r mct.o_p; a mct.o_p; b mct.o_p; lastn int[] := array_fill(0, array[1000]); r2 record; was boolean; isnow boolean; e int; body bytea; pos bytea;
begin
    truncate mct.o_exp;
    update mct.o_p set moved = false;
    for n in 1 .. coalesce(cardinality(conns), 0) loop
        c := conns[n];
        select * into r from mct.o_p where eid = c;
        if not found then continue; end if;
        if abs(xs[n] - r.x) <= 10 and abs(zs[n] - r.z) <= 10 then lastn[c] := n; end if;
    end loop;
    for c in select eid from mct.o_p order by eid loop
        if lastn[c] > 0 then
            n := lastn[c];
            update mct.o_p set x = xs[n], y = ys[n], z = zs[n], yaw = yaws[n], pitch = pitches[n], og = ogs[n], moved = true where eid = c;
        end if;
    end loop;
    for r2 in select pa.eid as ea, pb.eid as eb from mct.o_p pa, mct.o_p pb where pa.eid < pb.eid and (pa.moved or pb.moved) order by pa.eid, pb.eid loop
        select * into a from mct.o_p where eid = r2.ea;
        select * into b from mct.o_p where eid = r2.eb;
        isnow := (a.x - b.x) * (a.x - b.x) + (a.z - b.z) * (a.z - b.z) <= 2304.0;
        was := exists (select 1 from mct.o_v where mct.o_v.a = a.eid and mct.o_v.b = b.eid);
        if isnow and not was then
            insert into mct.o_v values (a.eid, b.eid);
            insert into mct.o_exp values (a.eid, mct.o_add(b)), (b.eid, mct.o_add(a));
        elsif was and not isnow then
            delete from mct.o_v where mct.o_v.a = a.eid and mct.o_v.b = b.eid;
            insert into mct.o_exp values (a.eid, mct.o_frame('\x0201'::bytea || mct.varint_ref(b.eid))), (b.eid, mct.o_frame('\x0201'::bytea || mct.varint_ref(a.eid)));
        elsif isnow and was then
            if a.moved then insert into mct.o_exp values (b.eid, mct.o_move(a)); end if;
            if b.moved then insert into mct.o_exp values (a.eid, mct.o_move(b)); end if;
        end if;
    end loop;
    update mct.o_p set sqx = mct.o_quant(x), sqy = mct.o_quant(y), sqz = mct.o_quant(z) where moved;
    for e in 1 .. coalesce(cardinality(ev_kind), 0) loop
        pos := int8send(((ev_x[e]::bigint & 67108863) << 38) | ((ev_z[e]::bigint & 67108863) << 12) | (ev_y[e]::bigint & 4095));
        if ev_kind[e] = 'block' then body := '\x05'::bytea || pos || mct.varint_ref(ev_new[e]);
        else body := '\x06'::bytea || pos || mct.varint_ref(ev_new[e]) || mct.varint_ref(ev_cnt[e]); end if;
        insert into mct.o_exp select p.eid, mct.o_frame(body) from mct.o_p p
         where abs(floor(p.x / 16)::int - (ev_x[e] >> 4)) <= 8 and abs(floor(p.z / 16)::int - (ev_z[e] >> 4)) <= 8;
    end loop;
end $$;

create temp table difftick_stats (packets bigint default 0, enters bigint default 0, leaves bigint default 0, teleports bigint default 0, moves bigint default 0, rejected bigint default 0, evpk bigint default 0);
insert into difftick_stats default values;
do $$
declare
    nplayers constant int := 90;
    t int; i int; k int; conns int[]; xs float8[]; ys float8[]; zs float8[]; yaws float4[]; pitches float4[]; ogs boolean[];
    ek text[]; ex int[]; ey int[]; ez int[]; en int[]; ec int[];
    px float8[]; pz float8[]; dx float8; dz float8; nx float8; nz float8;
    exp_ text[]; got text[]; r record; nexp bigint; total bigint := 0;
begin
    perform setseed(0.31337);
    perform mc.drain_block_events();
    perform mc.reset_players();
    perform mc.join_bulk((select array_agg(g) from generate_series(1, nplayers) g),
                         (select array_agg(case when g % 7 = 0 then (floor(random() * 500000) + 0.5) / 4096 else random() * 140 end) from generate_series(1, nplayers) g),
                         (select array_agg(64 + random() * 6) from generate_series(1, nplayers) g),
                         (select array_agg(case when g % 5 = 0 then (floor(random() * 500000) + 0.5) / 4096 else random() * 140 end) from generate_series(1, nplayers) g));
    perform mc.vis_init();
    perform mct.o_sync();
    for t in 1 .. 60 loop
        conns := '{}'; xs := '{}'; ys := '{}'; zs := '{}'; yaws := '{}'; pitches := '{}'; ogs := '{}';
        for i in 1 .. nplayers loop
            if random() < 0.35 then
                for k in 1 .. (case when random() < 0.06 then 2 else 1 end) loop       -- sometimes two packets from one conn
                    select x, z into nx, nz from mct.o_p where eid = i;
                    dx := case when random() < 0.04 then 10 when random() < 0.04 then -10 when random() < 0.05 then 10.0000001 else (random() - 0.5) * 21.2 end;
                    dz := (random() - 0.5) * 21.2;
                    nx := greatest(least(nx + dx, 150), -10); nz := greatest(least(nz + dz, 150), -10);
                    if random() < 0.15 then nx := (floor(nx * 4096) + 0.5) / 4096; end if;
                    conns := conns || i; xs := xs || nx; ys := ys || (64 + random() * 6); zs := zs || nz;
                    yaws := yaws || ((random() * 1500 - 750)::float4); pitches := pitches || ((random() * 180 - 90)::float4); ogs := ogs || (random() < 0.5);
                end loop;
            end if;
        end loop;
        if t % 4 = 0 then conns := conns || 9999; xs := xs || 1.0; ys := ys || 1.0; zs := zs || 1.0; yaws := yaws || 0::float4; pitches := pitches || 0::float4; ogs := ogs || true; end if;
        if t % 3 = 0 then
            insert into mc.block_event (kind, x, y, z, old_state, new_state, cnt)
            select case when random() < 0.3 then 'fill' else 'block' end, (random() * 330 - 100)::int, (random() * 400 - 64)::int, (random() * 330 - 100)::int, 0, (random() * 20)::int, (random() * 5000)::int
              from generate_series(1, 6);
        end if;
        select coalesce(array_agg(kind order by id), '{}'), coalesce(array_agg(x order by id), '{}'), coalesce(array_agg(y order by id), '{}'), coalesce(array_agg(z order by id), '{}'),
               coalesce(array_agg(new_state order by id), '{}'), coalesce(array_agg(cnt order by id), '{}') into ek, ex, ey, ez, en, ec from mc.block_event;
        -- the oracle reads the arrays it was given; the implementation gets the same bytes through the inbox
        -- (oracle positions are the exact float8 values; float4 yaw/pitch are the values stored in the payload)
        perform mct.o_tick(conns, xs, ys, zs, yaws, pitches, ogs, ek, ex, ey, ez, en, ec);
        perform mc.inbox_push(conns, (select array_agg(mc.move_payload(xs[j], ys[j], zs[j], yaws[j], pitches[j], ogs[j]) order by j) from generate_series(1, coalesce(cardinality(conns), 0)) j));
        perform mc.server_tick();
        select coalesce(array_agg(conn || ':' || encode(data, 'hex') order by conn || ':' || encode(data, 'hex')), '{}') into got from mc.outbox_drain();
        select coalesce(array_agg(conn || ':' || encode(data, 'hex') order by conn || ':' || encode(data, 'hex')), '{}') into exp_ from mct.o_exp;
        if got is distinct from exp_ then
            raise exception 'FAIL: differential tick % packets differ: got % expected %', t, cardinality(got), cardinality(exp_);
        end if;
        if mc.player_digest() <> mct.o_digest() then raise exception 'FAIL: differential tick %: player_digest % vs oracle %', t, mc.player_digest(), mct.o_digest(); end if;
        if (select count(*) from mc.visible v where not exists (select 1 from mct.o_v o where (o.a, o.b) in ((v.viewer_eid, v.target_eid), (v.target_eid, v.viewer_eid)))) > 0
           or (select count(*) from mct.o_v) <> mc.visible_pairs() or (select count(*) from mc.visible) <> 2 * mc.visible_pairs() then
            raise exception 'FAIL: differential tick %: visible set differs', t;
        end if;
        if (select count(*) from mc.player p join mct.o_p o using (eid) where p.x <> o.x or p.y <> o.y or p.z <> o.z or p.yaw <> o.yaw or p.pitch <> o.pitch or p.on_ground <> o.og
                                                                          or p.sent_qx <> o.sqx or p.sent_qy <> o.sqy or p.sent_qz <> o.sqz) > 0 then
            raise exception 'FAIL: differential tick %: player rows differ', t;
        end if;
        update difftick_stats set packets = packets + cardinality(got),
               teleports = teleports + (select count(*) from unnest(got) g where g ~ '^[0-9]+:[0-9a-f]{2}04'),
               moves = moves + (select count(*) from unnest(got) g where g ~ '^[0-9]+:[0-9a-f]{2}03'),
               enters = enters + (select count(*) from unnest(got) g where g ~ '^[0-9]+:[0-9a-f]{2}01'),
               leaves = leaves + (select count(*) from unnest(got) g where g ~ '^[0-9]+:0302'),
               evpk = evpk + (select count(*) from unnest(got) g where g ~ '^[0-9]+:[0-9a-f]{2}0[56]');
    end loop;
end $$;
select mct.ok('differential tick (90 players, 60 ticks, dups, rejects, boundary distances, half-even quantisation, events): packets, digest, visible set, rows == oracle',
              (select packets > 5000 and enters > 200 and leaves > 200 and teleports > 50 and moves > 500 and evpk > 500 from difftick_stats));
select 'INFO differential totals: ' || packets || ' packets, ' || enters || ' enters, ' || leaves || ' leaves, ' || moves || ' moves, ' || teleports || ' teleports, ' || evpk || ' block/fill updates' from difftick_stats;

------------------------------------------------------------------------------------------------ dynamics (SPEC 7)
select mc.reset_world() \g /dev/null
select mc.gen_area(0, 0, 0, 0) \g /dev/null
select mc.fill(0, 64, 0, 15, 70, 15, 0) \g /dev/null
select mc.fill(0, 63, 0, 15, 63, 15, 20) \g /dev/null
select mc.drain_block_events() \g /dev/null
select mc.reset_sched() \g /dev/null
select mc.set_block(8, 64, 8, 6) \g /dev/null
select mc.sched_add(1, 8, 64, 8) \g /dev/null
select mc.dyn_step(0) as n \gset
select mct.ok('dyn_step before anything is due does nothing', :n = 0 and mc.sched_size() = 1);
select mc.dyn_step(1) as n1 \gset
select mct.ok('step 1: source spreads to its 4 neighbours at level 1 (state 7), rescheduled for now+5',
              :n1 = 4 and mc.get_block(9, 64, 8) = 7 and mc.get_block(7, 64, 8) = 7 and mc.get_block(8, 64, 9) = 7 and mc.get_block(8, 64, 7) = 7 and mc.get_block(9, 64, 9) = 0 and mc.sched_size() = 4);
select mc.dyn_step(2) as n \gset
select mct.ok('nothing due at tick 2', :n = 0);
select mc.dyn_step(6 + 5 * g) from generate_series(0, 5) g \g /dev/null
select mct.ok('after 7 steps the platform shows level = manhattan distance (<= 7), 113 water blocks, deterministic',
              (select count(*) = 113 and bool_and(mc.get_block(x, 64, z) = 6 + abs(x - 8) + abs(z - 8)) from generate_series(1, 15) x, generate_series(1, 15) z where abs(x - 8) + abs(z - 8) <= 7)
              and (select count(*) = 0 from generate_series(0, 15) x, generate_series(0, 15) z where abs(x - 8) + abs(z - 8) > 7 and mc.get_block(x, 64, z) <> 0));
select mc.world_hash() as wh1 \gset
-- same again from scratch: identical world
select mc.fill(0, 64, 0, 15, 64, 15, 0) \g /dev/null
select mc.reset_sched() \g /dev/null
select mc.set_block(8, 64, 8, 6) \g /dev/null
select mc.sched_add(1, 8, 64, 8) \g /dev/null
select mc.dyn_step(1 + 5 * g) from generate_series(0, 6) g \g /dev/null
select mct.ok('dyn_step is deterministic (world_hash equal on replay)', mc.world_hash() = :'wh1'::bytea);
-- minimum rule: a level-3 block next to a cell that a level-0 source above-neighbour also feeds by falling
select mc.fill(0, 64, 0, 15, 70, 15, 0) \g /dev/null
select mc.reset_sched() \g /dev/null
select mc.set_block(5, 64, 5, 9) \g /dev/null
select mc.set_block(6, 65, 5, 6) \g /dev/null
select mc.sched_add(10, 5, 64, 5) \g /dev/null
select mc.sched_add(10, 6, 65, 5) \g /dev/null
select mc.sched_add(10, 6, 65, 5) \g /dev/null
select mc.dyn_step(10) as n \gset
select mct.ok('min level wins (fall = 1 beats spread = 4); falls into air below; duplicates collapse',
              mc.get_block(6, 64, 5) = 7 and mc.get_block(6, 65, 6) = 7 and mc.get_block(5, 64, 6) = 10 and mc.get_block(5, 64, 5) = 9 and mc.get_block(6, 64, 5) = 7 and :n > 0);
-- random ticks against a brute-force oracle
select mc.fill(0, 64, 0, 15, 70, 15, 0) \g /dev/null
select (mc.hash2(10::bigint, 0::bigint, 15::bigint) & 4095) as pick_i \gset
select (:pick_i & 15) as px, (96 + (:pick_i >> 8)) as py, ((:pick_i >> 4) & 15) as pz \gset
select mc.set_block(:px, :py, :pz, 3), mc.set_block(case when :px < 15 then :px + 1 else :px - 1 end, :py, :pz, 2) \g /dev/null
select mc.drain_block_events() \g /dev/null
create temp table rt_before as select x, y, z, mc.get_block(x, y, z) as s from generate_series(0, 15) x, generate_series(-64, 111) y, generate_series(0, 15) z;
create temp table rt_expect as
  select distinct on (x, y, z) x, y, z from (
    select sy, k, (i & 15) as x, sy * 16 + (i >> 8) as y, ((i >> 4) & 15) as z
      from (select s.sy, k, mc.hash2((0 * 64 + s.sy + 4)::bigint, 0::bigint, (5 * 3 + k)::bigint) & 4095 as i
              from mc.chunk_section s, generate_series(0, 2) k where s.cx = 0 and s.cz = 0 and s.block_count > 0) h) p
   where (select s from rt_before b where (b.x, b.y, b.z) = (p.x, p.y, p.z)) = 3
     and coalesce((select s from rt_before b where (b.x, b.y, b.z) = (p.x, p.y + 1, p.z)), 0) = 0
     and exists (select 1 from rt_before b where b.y = p.y and b.s = 2 and abs(b.x - p.x) + abs(b.z - p.z) = 1)
   order by x, y, z;
select mc.random_ticks(5, 0, 0, 0, 0) as n \gset
select mct.ok('random_ticks turned the planted dirt (picked by hash2) into grass', :n >= 1 and mc.get_block(:px, :py, :pz) = 2);
select mct.ok('random_ticks: changed == oracle (dirt, air above, grass beside), and exactly those blocks became grass',
              :n = (select count(*) from rt_expect) and
              (select count(*) = 0 from rt_before b where (b.s = 3 and mc.get_block(b.x, b.y, b.z) = 2) <> exists (select 1 from rt_expect e where (e.x, e.y, e.z) = (b.x, b.y, b.z)))
              and (select count(*) = :n from mc.drain_block_events()));

------------------------------------------------------------------------------------------------ chat
select mc.reset_chat() \g /dev/null
select setseed(0.5) \g /dev/null
create temp table words as select w from unnest(array['alpha','beta','gamma','delta','x1','42','7up','zeta','omega','a']) w;
create temp table chat_in as
  select n, (n % 13) as sender, (select string_agg((select w from words offset (random() * 9)::int limit 1), ' ') from generate_series(1, 1 + (n % 6))) as msg
    from generate_series(1, 400) n;
select mc.chat_add_bulk(array_agg(sender order by n), array_agg(msg order by n), array_agg(n::bigint order by n)) as last_id from chat_in \gset
select mct.ok('chat_add_bulk returns the last id, ids 1.. in order', :last_id = 400 and (select bool_and(c.msg = i.msg and c.sender = i.sender) from mc.chat c join chat_in i on i.n = c.id));
select mc.chat_add(3, 'alpha omega', 401) as id \gset
select mct.ok('chat_add returns the next id', :id = 401);
select mct.ok('chat_search == brute force over whole space-separated tokens, newest first, limited (all words incl. numerics)',
              (select bool_and((select coalesce(array_agg(id), '{}') from mc.chat_search(w, 25))::bigint[] =
                               (select coalesce(array_agg(id order by id desc), '{}')::bigint[] from (select n::bigint as id from (select n, msg from chat_in union all select 401, 'alpha omega') m where w = any (string_to_array(msg, ' ')) order by n desc limit 25) q)) from words)
              and (select count(*) = 0 from mc.chat_search('alph', 10)) and (select count(*) = 0 from mc.chat_search('nothere', 10)));
select mct.ok('chat_recent / chat_count_by_sender', (select array_agg(id) from mc.chat_recent(3)) = array[401, 400, 399]::bigint[]
              and (select sum(n) = 401 and count(*) = 13 and bool_and(n = (select count(*) from (select sender from chat_in union all select 3) q where q.sender = s.sender)) from mc.chat_count_by_sender() s));

------------------------------------------------------------------------------------------------ inventory
select mc.reset_inv() \g /dev/null
select mc.inv_seed(6) \g /dev/null
select mct.ok('inv_seed: slots 5..44 only, 70% rule, item/count formulas, max_stack',
              (select count(*) = count(*) filter (where slot between 5 and 44 and item between 1 and 199 and count between 1 and mc.max_stack(item)) from mc.inv)
              and (select count(*) = (select count(*) from generate_series(1, 6) p, generate_series(5, 44) s where mc.hash2(p, s, 9) % 100 < 70) from mc.inv)
              and (select bool_and(item = 1 + mc.hash2(player, slot, 10) % 199 and count = 1 + mc.hash2(player, slot, 11) % (case when item < 100 then 64 when item < 180 then 16 else 1 end)) from mc.inv)
              and mc.max_stack(99) = 64 and mc.max_stack(100) = 16 and mc.max_stack(179) = 16 and mc.max_stack(180) = 1);
select mct.ok('inv_digest == formula over inv_load', mc.inv_digest() = (select sum(p::bigint * 1000003 + l.slot * 8191::bigint + l.item * 131::bigint + l.count * 7::bigint + p::bigint * l.slot * 3) from generate_series(1, 6) p, lateral mc.inv_load(p) l));
-- reference model: arrays of 46 (item,count), plain loops
create type mct.invst as (items int[], cnts int[]);
create function mct.inv_ref(st mct.invst, op text, a int, b int) returns mct.invst language plpgsql as $$
declare items int[] := st.items; cnts int[] := st.cnts; ms int; mv int; lo int; hi int; s int; rem int; ti int; tc int;
begin
    if op = 'swap' then
        if a <> b then ti := items[a + 1]; tc := cnts[a + 1]; items[a + 1] := items[b + 1]; cnts[a + 1] := cnts[b + 1]; items[b + 1] := ti; cnts[b + 1] := tc; end if;
    elsif op = 'merge' then
        if a <> b and items[a + 1] is not null then
            if items[b + 1] = items[a + 1] then
                ms := case when items[a+1] < 100 then 64 when items[a+1] < 180 then 16 else 1 end;
                mv := least(cnts[a + 1], ms - cnts[b + 1]);
                if mv > 0 then cnts[b + 1] := cnts[b + 1] + mv; cnts[a + 1] := cnts[a + 1] - mv; if cnts[a + 1] = 0 then items[a + 1] := null; cnts[a + 1] := null; end if; end if;
            else ti := items[a + 1]; tc := cnts[a + 1]; items[a + 1] := items[b + 1]; cnts[a + 1] := cnts[b + 1]; items[b + 1] := ti; cnts[b + 1] := tc; end if;
        end if;
    elsif op = 'quick' then
        if items[a + 1] is not null and (a between 9 and 44) then
            if a <= 35 then lo := 36; hi := 44; else lo := 9; hi := 35; end if;
            ms := case when items[a+1] < 100 then 64 when items[a+1] < 180 then 16 else 1 end; rem := cnts[a + 1];
            for s in lo .. hi loop
                exit when rem = 0;
                if items[s + 1] = items[a + 1] and cnts[s + 1] < ms then mv := least(rem, ms - cnts[s + 1]); cnts[s + 1] := cnts[s + 1] + mv; rem := rem - mv; end if;
            end loop;
            if rem > 0 then
                for s in lo .. hi loop
                    if items[s + 1] is null then mv := least(rem, ms); items[s + 1] := items[a + 1]; cnts[s + 1] := mv; rem := rem - mv; exit; end if;
                end loop;
            end if;
            if rem = 0 then items[a + 1] := null; cnts[a + 1] := null; else cnts[a + 1] := rem; end if;
        end if;
    elsif op = 'drop' then
        if items[a + 1] is not null then
            mv := least(b, cnts[a + 1]);
            if mv > 0 then cnts[a + 1] := cnts[a + 1] - mv; if cnts[a + 1] = 0 then items[a + 1] := null; cnts[a + 1] := null; end if; end if;
        end if;
    end if;
    return (items, cnts)::mct.invst;
end $$;
create temp table inv0 as select * from mc.inv;
create temp table clicks as
  select n, 1 + (random() * 5)::int as player, (array['swap','merge','quick','drop'])[1 + (random() * 3)::int] as op,
         0 as a, 0 as b from generate_series(1, 4000) n;
update clicks set a = case when op = 'quick' and random() < 0.7 then 9 + (random() * 35)::int else (random() * 45)::int end,
                  b = case when op = 'drop' then (random() * 70)::int else (random() * 45)::int end;
update clicks set b = (a + 1) % 46 where op in ('swap', 'merge') and a = b;
select mc.inv_clicks_bulk(array_agg(player order by n), array_agg(op order by n), array_agg(a order by n), array_agg(b order by n)) from clicks \g /dev/null
do $$
declare
    p int; c record; items int[]; cnts int[]; r mct.invst; got_i int[]; got_c int[];
begin
    for p in 1 .. 6 loop
        items := array_fill(null::int, array[46]); cnts := array_fill(null::int, array[46]);
        for c in select slot, item, count from inv0 where player = p loop items[c.slot + 1] := c.item; cnts[c.slot + 1] := c.count; end loop;
        for c in select op, a, b from clicks where player = p order by n loop
            r := mct.inv_ref((items, cnts)::mct.invst, c.op, c.a, c.b); items := r.items; cnts := r.cnts;
        end loop;
        got_i := array_fill(null::int, array[46]); got_c := array_fill(null::int, array[46]);
        for c in select slot, item, count from mc.inv_load(p) loop got_i[c.slot + 1] := c.item; got_c[c.slot + 1] := c.count; end loop;
        if got_i is distinct from items or got_c is distinct from cnts then raise exception 'FAIL: inventory of player % differs from the reference model', p; end if;
    end loop;
end $$;
select mct.ok('4000 random clicks (swap/merge/quick/drop) in one inv_clicks_bulk call == reference model, every player', (select count(*) = 4000 from clicks) and (select count(*) > 0 from mc.inv));

select 'ALL TESTS PASSED';
