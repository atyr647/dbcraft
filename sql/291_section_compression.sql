-- Compression of section rows (docs/PERF-SCALE.md, docs/PERF-DISK.md).
--
-- Until sql/950 this was opt-in: sql/200 set toast_tuple_target = 8160 on mc.chunk_section, so a section row was compressed only when the whole row exceeded 8,160 bytes: almost
-- none did, and sections were stored raw.  Measured on 5,105 real terrain chunks (122,520 sections): the section table shrinks from 345 MB to 143 MB with no measurable change in
-- get_block, set_block, chunk rebuild or join latency (re-measured for sql/950 in docs/PERF-DISK.md: set_block +4 to 10%).  sql/950 now makes compression the DEFAULT (the "compact"
-- storage profile) and this switch selects the profile:
--
--   select mc.set_section_compression(true);      -- the compact profile (compressed sections, fillfactor 90-100); rows written from now on
--   select mc.rewrite_sections();                 -- compress the rows already stored (rewrites the table: heavy WAL; follow with VACUUM FULL mc.chunk_section)
--   select mc.set_section_compression(false);     -- the legacy profile: raw sections, fillfactor 70 (the original behaviour)
-- (mc.compact_world_storage() in sql/950 rewrites all four world tables.)  Any function that reads a palette or data value many times per section pays a decompression per read; the one
-- place that did that, mc.section_blocks (below), reads them once now.
create or replace function mc.set_section_compression(p_on boolean) returns void language plpgsql volatile as $$
begin
    perform mc.set_world_storage(case when p_on then 'compact' else 'legacy' end);      -- sql/950; late-bound, so this file may run first
end $$;

create or replace function mc.rewrite_sections() returns bigint language plpgsql volatile as $$
declare n bigint;
begin
  update mc.chunk_section set block_count = block_count;     -- every row is re-formed, so rows above the table's current target are compressed on the way in
  get diagnostics n = row_count;
  return n;
end $$;

-- mc.section_blocks as in sql/210, except that the palette is read ONCE per section.  With compressed rows each palette[...] subscript of the original decompressed the whole
-- array again: 4,096 times per section (blocks_in went from 5 ms to 20 ms on compressed rows).  array_cat(palette, '{}') is the value itself, decompressed once.
create or replace function mc.section_blocks(s mc.chunk_section, include_air boolean default false)
returns table (x int, y int, z int, block text) language sql stable as $$
  with a as materialized (select array_cat(s.palette, '{}'::text[]) as pal,
                                 array(select mc.is_air(p) from unnest(s.palette) with ordinality q(p, o) order by o) as air)
  select s.cx * 16 + (u.i & 15), s.sy * 16 + (u.i >> 8), s.cz * 16 + ((u.i >> 4) & 15),
         case when cardinality(a.pal) = 0 then mc.state_name(u.e) else a.pal[u.e + 1] end
  from a, lateral (select o - 1 as i, e from unnest(mc.unpack_longs(s.data, s.bits, 4096)) with ordinality t(e, o)) u
  where include_air
     or not (case when cardinality(a.pal) = 0 then mc.is_air(mc.state_name(u.e)) else a.air[u.e + 1] end) $$;

-- mc.unpack_longs as in sql/200, except that the data is bound ONCE per call.  The original calls get_byte(d, ...) three times per entry (about 12,000 times for a section);
-- on a compressed value every call decompresses the whole value again, which made blocks_in 4x slower on compressed rows.  d || '' is the value itself, decompressed once.
-- (This, not the palette, was the cost: measured in docs/PERF-SCALE.md.)  Same result for every input: tests/sql/291 compares it with the original.
create or replace function mc.unpack_longs(d bytea, bits int, n int) returns int[] language sql immutable parallel safe as $$
  select case when bits = 0 then array_fill(0, array[n]) else
    (with src as materialized (select d || ''::bytea as dd)
     select array(
       select ((((get_byte(src.dd, k))
               | ((case when k - 1 >= base then get_byte(src.dd, k - 1) else 0 end) << 8)
               | ((case when k - 2 >= base then get_byte(src.dd, k - 2) else 0 end) << 16)) >> (p % 8))
               & ((1 << bits) - 1))
       from src, (select i, base, p, base + 7 - p / 8 as k
                  from (select i, (i / (64 / bits)) * 8 as base, (i % (64 / bits)) * bits as p from generate_series(0, n - 1) i) q) r
       order by i))
  end $$;

-- Opt-in storage mode of the chunk packet cache (docs/PERF-SCALE.md).  The cache is derived data: a miss rebuilds the packet (4-15 ms), a hit costs ~20 us, so the mode is a
-- pure trade of disk for CPU on the join path (net.hook_chunks cuts every cached packet to its body, which decompresses it).  Measured on 5,056 real terrain chunks
-- (50 KB packets), 441-chunk join, warm:   pglz (the default) 104 ms, 65 MB   |   lz4 36 ms, 80 MB   |   external (stored uncompressed) 13 ms, 261 MB.
-- Only rows written afterwards change; `truncate mc.chunk_cache` (it refills on demand) converts the lot.  lz4 needs a server built with it (the Ubuntu and Docker images are).
create or replace function mc.set_cache_storage(p_mode text) returns void language plpgsql volatile as $$
begin
  case p_mode
    when 'pglz'     then execute 'alter table mc.chunk_cache alter column packet set storage extended, alter column packet set compression pglz';
    when 'lz4'      then execute 'alter table mc.chunk_cache alter column packet set storage extended, alter column packet set compression lz4';
    when 'external' then execute 'alter table mc.chunk_cache alter column packet set storage external';
    else raise exception 'mc.set_cache_storage: unknown mode "%" (use pglz, lz4 or external)', p_mode;
  end case;
end $$;
