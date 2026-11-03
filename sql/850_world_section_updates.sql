-- Block change packets for many positions of one section: ClientboundSectionBlocksUpdatePacket (docs/WORLD.md "Block change packets").
--
-- What vanilla 26.3 does (read with javap from ChunkHolder.broadcastChanges and ClientboundSectionBlocksUpdatePacket, compared byte for byte against a real server in
-- tests/e2e/fill_probe.py + compare_fill.py):
--   * ChunkHolder.blockChanged(pos) adds the position's 12-bit section-relative index (x << 8 | z << 4 | y) to a ShortOpenHashSet of its section, once the block state
--     really changed (setBlockState with the same state does not get that far).  A position that changes and changes back stays in the set.
--   * At the end of the tick, per section, in section order: ONE position -> ClientboundBlockUpdatePacket(pos, the state NOW); TWO OR MORE ->
--     ClientboundSectionBlocksUpdatePacket(sectionPos, set, section).  There is no size threshold above two (a whole section of 4,096 positions is one packet).
--   * The packet is: the SectionPos as a long (x & 0x3FFFFF) << 42 | (y & 0xFFFFF) | (z & 0x3FFFFF) << 20, VarInt count, then per position a VarLong
--     (state id << 12 | index), in the iteration order of the set: fastutil 8.5.18 ShortOpenHashSet (open addressing, linear probing, HashCommon.mix, load factor 0.75,
--     initial size 32, doubling rehash) - the order is deterministic given the order of insertion, which mc.shortset_order reproduces exactly.
-- The server queues the positions as mc.block_event rows ('block': one position; 'cells': a bit map of one section written by mc.fill) and
-- mc.broadcast_block_events (sql/432) turns them into these packets.

-- The iteration order of a fastutil ShortOpenHashSet filled with p_pos in this order (values 0 .. 4095; duplicates are ignored, as add() ignores them).
-- Exact simulation of the class as read from the bytecode: key 0 is held in a separate flag and comes first; the other keys sit in a table of 32 slots that doubles
-- when the size before an insertion has reached maxFill (75% of the table), re-inserting the old table from its last slot down; iteration walks the table from the
-- last slot to the first.  Checked against the real class in tests/sql/850 (vectors produced by running fastutil 8.5.18) and over 100 random and structured sequences.
create or replace function mc.shortset_order(p_pos int[]) returns int[] language plpgsql immutable parallel safe as $$
declare
    n        int := 32;
    mask     int := 31;
    maxfill  int := 24;
    size     int := 0;
    tab      int[] := array_fill(0, array[32]);       -- slot s (0-based) holds position + 1, 0 = empty
    has_null boolean := false;
    k int; h bigint; p int; v int; dup boolean;
    nn int; nm int; nt int[]; i int;
    res      int[]; c int := 0;
begin
    foreach k in array p_pos loop
        if k = 0 then
            continue when has_null;
            has_null := true;
        else
            h := (k::bigint * 2654435769) & 4294967295;              -- HashCommon.mix: h = k * 0x9E3779B9 (32 bit), h ^ (h >>> 16)
            p := ((h # (h >> 16)) & mask)::int;
            dup := false;
            loop
                v := tab[p + 1];
                exit when v = 0;
                if v = k + 1 then dup := true; exit; end if;
                p := (p + 1) & mask;
            end loop;
            continue when dup;
            tab[p + 1] := k + 1;
        end if;
        size := size + 1;
        if size - 1 >= maxfill then                                       -- add(): if (size++ >= maxFill) rehash(arraySize(size + 1, f))
            nn := n * 2; nm := nn - 1; nt := array_fill(0, array[nn]);
            for i in reverse n .. 1 loop
                v := tab[i];
                continue when v = 0;
                h := ((v - 1)::bigint * 2654435769) & 4294967295;
                p := ((h # (h >> 16)) & nm)::int;
                while nt[p + 1] <> 0 loop p := (p + 1) & nm; end loop;
                nt[p + 1] := v;
            end loop;
            tab := nt; n := nn; mask := nm; maxfill := nn * 3 / 4;
        end if;
    end loop;
    res := array_fill(0, array[size]);
    if has_null then c := 1; res[1] := 0; end if;
    for i in reverse n .. 1 loop
        if tab[i] <> 0 then c := c + 1; res[c] := tab[i] - 1; end if;
    end loop;
    return res;
end $$;

-- The positions of a 'cells' bit map as vanilla indexes them (x << 8 | z << 4 | y), in the order a /fill visits them (x fastest, then y, then z).
create or replace function mc.cells_positions(c bytea) returns int[] language sql immutable parallel safe as $$
  select coalesce(array_agg((x << 8) | (z << 4) | y order by z, y, x), '{}')
    from generate_series(0, 15) z, generate_series(0, 15) y, generate_series(0, 15) x
   where get_bit(c, (y << 8) | (z << 4) | x) = 1 $$;

-- The two arrays every whole-section fill needs, computed once: the positions in /fill order and their set order.
create table if not exists mc.sbu_const (id int primary key, ins int[] not null, ord int[] not null);
insert into mc.sbu_const (id, ins, ord)
select 1, i.a, mc.shortset_order(i.a) from (select mc.cells_positions(decode(repeat('ff', 512), 'hex')) a) i
on conflict do nothing;

-- The block state ids at the given positions (vanilla indexes, x << 8 | z << 4 | y) of a section, as the section holds them now.  A missing section is air.
create or replace function mc.section_state_ids(p_dim text, p_cx int, p_sy int, p_cz int, p_pos int[]) returns int[] language plpgsql stable as $$
declare
    pal   text[]; bits int; data bytea; ids int[]; res int[] := '{}'; n int := cardinality(p_pos);
    vpl   int; msk bigint; words bigint[]; i int; e int; k int;
begin
    select s.palette, s.bits, s.data into pal, bits, data from mc.chunk_section s where s.dimension = p_dim and s.cx = p_cx and s.cz = p_cz and s.sy = p_sy;
    if not found then return array_fill(0, array[n]); end if;
    if bits = 0 then return array_fill((select s.state_id from ref.block_state s where s.name = pal[1]), array[n]); end if;
    if cardinality(pal) > 0 then ids := mc.palette_ids(pal); end if;
    vpl := 64 / bits; msk := (1::bigint << bits) - 1;
    res := array_fill(0, array[n]);
    if n >= 64 then
        words := array(select proto.i64_read(data, w * 8) from generate_series(0, (4096 + vpl - 1) / vpl - 1) w order by w);
    end if;
    for k in 1 .. n loop
        i := ((p_pos[k] >> 8) & 15) | (p_pos[k] & 240) | ((p_pos[k] & 15) << 8);              -- vanilla index -> storage index (y << 8 | z << 4 | x)
        if n >= 64 then e := ((words[i / vpl + 1] >> ((i % vpl) * bits)) & msk)::int;
        else e := ((proto.i64_read(data, (i / vpl) * 8) >> ((i % vpl) * bits)) & msk)::int; end if;
        res[k] := case when ids is null then e else ids[e + 1] end;
    end loop;
    return res;
end $$;

-- A VarInt (= VarLong for these values) of a non-negative number below 2^28, as one expression: proto.varint loops per byte and costs 14 us for the 4-byte values of
-- (state id << 12 | position), 4,096 of them 57 ms; this is 1 us.  Equal to proto.varint for every value in range (tests/sql/851).
create or replace function mc.varint_u28(v int) returns bytea language sql immutable parallel safe as $$
  select substring(int8send(((((v & 127) | (case when v >= 128 then 128 else 0 end)))::bigint << 24)
                          | ((((v >> 7) & 127) | (case when v >= 16384 then 128 else 0 end))::bigint << 16)
                          | ((((v >> 14) & 127) | (case when v >= 2097152 then 128 else 0 end))::bigint << 8)
                          | ((v >> 21) & 127)::bigint)
                   from 5 for (case when v < 128 then 1 when v < 16384 then 2 when v < 2097152 then 3 else 4 end)) $$;

-- The packet for one section whose set of changed positions p_ord is given in set order: block_update for one position, section_blocks_update for two or more.
create or replace function mc.section_update_packet(p_cx int, p_sy int, p_cz int, p_ord int[], p_ids int[]) returns bytea language plpgsql stable as $$
declare n int := cardinality(p_ord);
begin
    if n = 1 then
        return proto.frame(mc.pid('block_update'), proto.position(p_cx * 16 + (p_ord[1] >> 8), p_sy * 16 + (p_ord[1] & 15), p_cz * 16 + ((p_ord[1] >> 4) & 15)) || proto.varint(p_ids[1]));
    end if;
    return proto.frame(mc.pid('section_blocks_update'),
        int8send(((p_cx::bigint & 4194303) << 42) | (p_sy::bigint & 1048575) | ((p_cz::bigint & 4194303) << 20)) || proto.varint(n)
        || (select string_agg(mc.varint_u28((u.id << 12) | u.pos), ''::bytea order by u.o) from unnest(p_ord, p_ids) with ordinality u(pos, id, o)));
end $$;
