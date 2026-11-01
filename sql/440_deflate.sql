-- Compression in SQL: a DEFLATE encoder (fixed Huffman codes, run-length matches), zlib framing with Adler-32, and the compressed chunk packet.
-- Postgres has no zlib, so large packets for connections with network-compression-threshold >= 0 used to raise in net.deflate_frame; this file implements it.
--
--   mc.adler32(data)                         the zlib checksum;  mc.adler32_combine(a1, a2, len2)  the checksum of a1's data followed by a2's data
--   mc.deflate_fixed(data, final)            one fixed-Huffman block with distance-1 matches (runs).  Not final: ends with an empty stored block (a "sync
--                                            flush"), so the output is byte aligned and blocks can simply be concatenated.
--   mc.deflate_zlib(data)                    a complete zlib stream
--   net.deflate_frame(packet_id, body)       the wire frame [packet length][data length][zlib stream] (replaces the stub in sql/100_net.sql)
--   mc.chunk_cache.packet_z                  the compressed frame of a cached chunk packet, valid for the cached version; filled at generation by splicing the
--                                            template (below) and on rebuilds by the general encoder.  net.deflate_frame uses it when the body matches exactly.
--
-- The encoder only finds runs of one repeated byte (distance 1).  On chunk data that reaches about 85-95% of zlib's ratio (docs/COMPRESSION.md); a flat chunk
-- (8 KB) becomes a few hundred bytes.  A smarter matcher is possible later; the format below already allows it.
--
-- Flat chunks are spliced, not compressed: the packet of every flat chunk of a dimension is the same except for its two coordinates, so the template's packet is
-- compressed ONCE as [stored block: packet id + coordinates (9 bytes)] [fixed block: the rest, final] and a chunk's frame is that with its own 9 bytes and an
-- Adler-32 obtained by mc.adler32_combine.  Generating a compressed flat chunk costs microseconds.

------------------------------------------------------------------------------------------------ tables of the fixed code (derived, rebuilt from the RFC 1951 rules below)
create or replace function mc.rev_bits(code int, len int) returns int language plpgsql immutable parallel safe as $$
declare r int := 0; i int;
begin for i in 0 .. len - 1 loop r := (r << 1) | ((code >> i) & 1); end loop; return r; end $$;

-- literal bytes: codes 0-143 are 8 bits (0x30 + b), 144-255 are 9 bits (0x190 + b - 144); written most significant bit first, so stored reversed
create table if not exists mc.deflate_lit (b int primary key, rcode int not null, len int not null);
insert into mc.deflate_lit (b, rcode, len)
select b, mc.rev_bits(case when b <= 143 then 48 + b else 400 + b - 144 end, case when b <= 143 then 8 else 9 end), case when b <= 143 then 8 else 9 end
  from generate_series(0, 255) b
on conflict (b) do nothing;

-- a run of l repeated bytes (l = 3 .. 258) is a match of length l at distance 1: length code (7 or 8 bits, reversed) + extra bits + the 5-bit distance code 0.
-- val is the whole element as one value to write least significant bit first, bits its width.
create table if not exists mc.deflate_len (l int primary key, val int not null, bits int not null);
insert into mc.deflate_len (l, val, bits)
select l, mc.rev_bits(case when sym <= 279 then sym - 256 else 192 + sym - 280 end, case when sym <= 279 then 7 else 8 end)
          | ((l - base) << (case when sym <= 279 then 7 else 8 end)),
       (case when sym <= 279 then 7 else 8 end) + ex + 5
  from (select l, sym, (array[3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258])[sym - 256] as base,
               (array[0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0])[sym - 256] as ex
          from (select l, 257 + (select max(i) - 1 from generate_subscripts(array[3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258], 1) i
                                  where (array[3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258])[i] <= l) as sym
                  from generate_series(3, 258) l) q) r
on conflict (l) do nothing;

------------------------------------------------------------------------------------------------ checksums
-- zlib's Adler-32 as an unsigned 32-bit value.  The sums are reduced once at the end: for inputs below a megabyte they stay far inside a bigint.
create or replace function mc.adler32(p_data bytea) returns bigint language plpgsql stable parallel safe as $$
declare d bytea := p_data || ''::bytea; n int := octet_length(d); a bigint := 1; b bigint := 0; i int;
begin
    for i in 0 .. n - 1 loop a := a + get_byte(d, i); b := b + a; end loop;
    return ((b % 65521) << 16) | (a % 65521);
end $$;

-- Checksum of (data1 || data2) from the checksums of the parts and the length of the second (zlib's adler32_combine).
create or replace function mc.adler32_combine(a1 bigint, a2 bigint, len2 bigint) returns bigint language sql immutable parallel safe as $$
  select ((case when s2 >= 131042 then s2 - 131042 else s2 end) % 65521 << 16) | (s1 % 65521)
  from (select ((len2 % 65521) * (a1 & 65535)) % 65521 + ((a1 >> 16) & 65535) + ((a2 >> 16) & 65535) + 65521 - (len2 % 65521) as s2,
               (a1 & 65535) + (a2 & 65535) + 65521 - 1 as s1) q $$;

------------------------------------------------------------------------------------------------ the encoder
-- One fixed-Huffman DEFLATE block holding p_data.  Bits are packed least significant first into bytes (RFC 1951).
create or replace function mc.deflate_fixed(p_data bytea, p_final boolean default true) returns bytea language plpgsql stable parallel safe as $$
declare
    d     bytea := p_data || ''::bytea;          -- an inline copy: get_byte on a toasted argument would detoast it on every call
    n     int := octet_length(d);
    lrev  int[]; llen int[]; mval int[]; mbits int[];
    out   int[] := '{}';
    cnt   int := 0;
    acc   bigint := 0;
    nb    int := 0;
    i     int := 0;
    k     int;
    cur   int;
begin
    select array_agg(rcode order by b), array_agg(len order by b) into lrev, llen from mc.deflate_lit;
    select array_agg(val order by l), array_agg(bits order by l) into mval, mbits from mc.deflate_len;
    acc := (case when p_final then 1 else 0 end) | (1 << 1);         -- BFINAL, then BTYPE = 01 (fixed Huffman), least significant bit first
    nb := 3;
    while i < n loop
        cur := get_byte(d, i);
        acc := acc | (lrev[cur + 1]::bigint << nb); nb := nb + llen[cur + 1];
        while nb >= 8 loop cnt := cnt + 1; out[cnt] := (acc & 255)::int; acc := acc >> 8; nb := nb - 8; end loop;
        i := i + 1;
        k := 0;                                                       -- how many of the following bytes repeat this one (a distance-1 match needs 3 or more)
        while k < 258 and i + k < n and get_byte(d, i + k) = cur loop k := k + 1; end loop;
        if k >= 3 then
            acc := acc | (mval[k - 2]::bigint << nb); nb := nb + mbits[k - 2];
            while nb >= 8 loop cnt := cnt + 1; out[cnt] := (acc & 255)::int; acc := acc >> 8; nb := nb - 8; end loop;
            i := i + k;
        end if;
    end loop;
    nb := nb + 7;                                                     -- end of block: symbol 256, seven zero bits
    if not p_final then nb := nb + 3; end if;                         -- sync flush: an empty stored block, three zero header bits, then pad to a byte ...
    while nb >= 8 loop cnt := cnt + 1; out[cnt] := (acc & 255)::int; acc := acc >> 8; nb := nb - 8; end loop;
    if nb > 0 then cnt := cnt + 1; out[cnt] := (acc & 255)::int; end if;
    return (select decode(string_agg(lpad(to_hex(v), 2, '0'), '' order by o), 'hex') from unnest(out) with ordinality t(v, o))
        || case when p_final then ''::bytea else '\x0000ffff'::bytea end;                   -- ... and LEN = 0, NLEN = 0xffff
end $$;

-- A complete zlib stream: header, one final block, Adler-32 (big endian).
create or replace function mc.deflate_zlib(p_data bytea) returns bytea language sql stable parallel safe as $$
  select '\x7801'::bytea || mc.deflate_fixed(p_data, true) || substring(int8send(mc.adler32(p_data)) from 5 for 4) $$;

------------------------------------------------------------------------------------------------ frames
create or replace function mc.compression_enabled() returns boolean language sql stable as $$
  select coalesce((select value::int from mc.server_property where key = 'network-compression-threshold'), -1) >= 0 $$;

-- The wire frame of a packet above the compression threshold: [VarInt packet length][VarInt data length][zlib stream of (packet id + body)].
create or replace function mc.z_frame(p_payload bytea) returns bytea language sql stable parallel safe as $$
  with q as materialized (select mc.deflate_zlib(p_payload) as z)       -- MATERIALIZED: compress once, not once per use of z
  select proto.varint(octet_length(proto.varint(octet_length(p_payload))) + octet_length(z)) || proto.varint(octet_length(p_payload)) || z from q $$;

alter table mc.chunk_cache add column if not exists packet_z bytea;
comment on column mc.chunk_cache.packet_z is 'Derived cache: the compressed wire frame of packet, valid for the same version. Filled when compression is enabled.';

-- net.deflate_frame is what net.frame calls for a packet at or above the threshold (sql/100_net.sql had a stub that raised).  A chunk packet is served from
-- mc.chunk_cache.packet_z when the cached packet's body is exactly the one asked for; everything else is compressed here.
create or replace function net.deflate_frame(packet_id int, body bytea) returns bytea language plpgsql stable as $$
declare z bytea;
begin
    if packet_id = mc.chunk_packet_id() and octet_length(body) > 8 then
        select k.packet_z into z
          from mc.chunk_cache k join mc.chunk c on c.dimension = k.dimension and c.cx = k.cx and c.cz = k.cz and c.version = k.version
         where k.cx = proto.i32_read(body, 0) and k.cz = proto.i32_read(body, 4) and k.packet_z is not null and mc.packet_body(k.packet) = body
         limit 1;
        if found then return z; end if;
    end if;
    return mc.z_frame(proto.varint(packet_id) || body);
end $$;

-- Fill packet_z for cached chunk packets that lack it (after compression was switched on, or for chunks cached before).  Returns how many it did.
create or replace function mc.backfill_chunk_z(p_max int default 100) returns int language plpgsql volatile as $$
declare n int;
begin
    with todo as (select k.ctid as id from mc.chunk_cache k where k.packet_z is null limit p_max for update skip locked)
    update mc.chunk_cache k set packet_z = mc.z_frame(substring(k.packet from (select nxt from proto.varint_read(k.packet, 0)) + 1))
      from todo where k.ctid = todo.id;
    get diagnostics n = row_count;
    return n;
end $$;
