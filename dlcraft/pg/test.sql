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
-- whole-section fill over a multi-entry 4-bit section: n = blocks that were not already the state
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
-- single-value air section -> 16 palette entries via set_blocks -> partial fill with a 17th state (repack to 5 bits)
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

------------------------------------------------------------------------------------------------ chunk_packet cache, world_hash
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
  select coalesce(array_agg(conn || ':' || encode(data, 'hex') order by conn, data), '{}') from mc.outbox_drain() $$;
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
              mct.drain_hex() = array['1:2c0102' || mct.uuid_hex(2) || '4046800000000000' || '4050000000000000' || '0000000000000000' || '4000',
                                      '2:2c0101' || mct.uuid_hex(1) || '0000000000000000' || '4050000000000000' || '0000000000000000' || '0000']);
select mct.ok('enter: visible pair stored', mc.visible_pairs() = 1 and (select count(*) = 2 from mc.visible));
-- tick 2: P2 steps out to 49.5 -> leave, remove_entities both ways
select mct.push1(2, 49.5, 64, 0, 90, 0, true) \g /dev/null
select mc.server_tick() \g /dev/null
select mct.ok('leave: remove_entities(2) -> conn 1, remove_entities(1) -> conn 2', mct.drain_hex() = array['1:03020102', '2:03020101'] and mc.visible_pairs() = 0);
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
              mct.drain_hex() = array['1:0b0302' || '6000' || '0000' || '0000' || '0000' || '01',    -- about P2: (51-45)*4096 = 24576
                                      '2:0b0301' || '3000' || '0000' || '0000' || '0000' || '01'] and mc.visible_pairs() = 1);
-- tick 9: just beyond 48 -> leave
select mct.push1(2, 51.0001, 64, 0, 0, 0, true) \g /dev/null
select mc.server_tick() \g /dev/null
select mct.ok('48.0001 blocks apart: leave', mct.drain_hex() = array['1:03020102', '2:03020101'] and mc.visible_pairs() = 0);
-- several packets of one conn in a tick: the last valid one counts; unknown conn ignored; invalid last does not shadow a valid earlier one
select mc.inbox_push(array[2, 2, 99, 1, 1], array[mc.move_payload(53, 64, 0, 0, 0, true), mc.move_payload(54, 64, 0, 0, 0, true), mc.move_payload(1, 1, 1, 0, 0, true),
                                                   mc.move_payload(4, 64, 0, 0, 0, true), mc.move_payload(400, 64, 0, 0, 0, true)]) \g /dev/null
select mc.server_tick() \g /dev/null
select mct.ok('duplicate packets: last valid per conn wins, unknown conn skipped',
              (select x = 54 from mc.player where eid = 2) and (select x = 4 from mc.player where eid = 1) and (select count(*) = 0 from mc.player where eid = 99));
select mct.drain_hex() \g /dev/null

-- block events: ids in order, to every player within 8 chunks (|dcx| <= 8 and |dcz| <= 8) of the event chunk; none elsewhere
select mc.reset_players() \g /dev/null
select mc.join_bulk(array[1, 2], array[1.0, 70.0], array[64.0, 64.0], array[1.0, 1.0]) \g /dev/null   -- chunks (0,0) and (4,0)
truncate mc.block_event restart identity;
insert into mc.block_event (kind, x, y, z, old_state, new_state, cnt) values
  ('block', 5, 70, 5, 0, 20, 0),                    -- chunk (0,0): both players
  ('fill', 176, 10, 0, -1, 7, 300),                  -- chunk (11,0): |4-11| = 7 for P2, 11 for P1 -> P2 only
  ('block', -1, -64, -1, 1, 0, 0),                   -- chunk (-1,-1): both
  ('fill', 200, 10, 0, -1, 7, 1);                    -- chunk (12,0): |4-12| = 8 -> P2 only (boundary), P1 12 -> none
select mc.server_tick() \g /dev/null
select mct.ok('block events: exact packets (i64 pos, varint state / count), in event order, only to players within 8 chunks',
              mct.drain_hex() = array[
                '1:0a05' || '0000014000005046' || '14',
                '1:0a05' || 'ffffffffffffffc0' || '00',
                '2:0a05' || '0000014000005046' || '14',
                '2:' || '0e06' || encode(int8send(176::bigint * 274877906944 + 0 * 4096 + 10), 'hex') || '07' || 'ac02',
                '2:0a05' || 'ffffffffffffffc0' || '00',
                '2:' || '0d06' || encode(int8send(200::bigint * 274877906944 + 0 * 4096 + 10), 'hex') || '07' || '01']);
select mct.ok('events were consumed', (select count(*) = 0 from mc.block_event));
select mct.ok('pkt_move: teleport branch at |dq| = 32768 and move branch at 32767, negative side too',
              mc.pkt_move(5, 32767, -32767, 0, 1, 2, 3, 0, 0, true) = '\x0b030500007fff8001000000'::bytea || '' and substring(mc.pkt_move(5, 32768, 0, 0, 1, 2, 3, 0, 0, true) from 2 for 1) = '\x04'
              and substring(mc.pkt_move(5, 0, -32768, 0, 1, 2, 3, 0, 0, true) from 2 for 1) = '\x04' and substring(mc.pkt_move(5, 0, 0, 32768, 1, 2, 3, 0, 0, false) from 2 for 1) = '\x04');
select mct.ok('pos64 of negative coordinates is two''s complement masked: (-1,-64,-1) -> ff..c0', mc.pos64(-1, -64, -1) = '\xffffffffffffffc0');
select mct.ok('angle(): floor(deg*256/360) & 255 on the float4 value', mc.angle(90) = 64 and mc.angle(-90) = 192 and mc.angle(360) = 0 and mc.angle(-0.5) = 255 and mc.angle(0.1::float4) = 0 and mc.angle(450) = 64);
