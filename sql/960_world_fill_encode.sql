-- The packet of a fill, built from a cached template instead of per position (docs/PERF-WORLD2.md).
--
-- A section whose only event of the tick is ONE fill is announced as a section_blocks_update whose entries all carry the same block state: per position of the changed
-- set (in the iteration order of vanilla's ShortOpenHashSet) the VarLong  state << 12 | position.  Everything but the state is a function of the bit map of changed
-- positions alone (the order, the low two bytes of every entry), and the state adds the same trailing bytes to every entry.  So the work is split:
--   * per bit map (the shape of the box inside the section; the interior sections of a big fill share a handful of shapes and repeated fills share all of them) the order
--     is simulated ONCE (mc.shortset_order, about 1.5 us a position) and written as a hex template, cached in mc.sbu_tpl;
--   * per state one pass of translate() and one of replace() fills in the state's bits and trailing bytes (C speed, no loop over positions), and decode() makes the bytes.
-- The template for a state id of 1 or more has per entry:  b0 (two hex digits)  g|h  (the high digit of the second byte: g or h by bit 4 of position >> 7)  one hex digit  z
--   where the VarLong is  b0 b1 [b2 [b3]]  with b0 = 0x80 | pos & 127, b1 = (pos >> 7) | (state & 3) << 5 [| 0x80 when the value needs more bytes], and b2, b3 the state's bits
--   above the first two (a VarLong of a value below 2^28 is at most four bytes).  The air template (state 0) has one or two bytes per entry, so it is kept separately.
-- The result is byte-for-byte what mc.section_update_packet gives for the same positions and states (tests/sql/960).
--
-- The fill also builds the packets itself, when a connection can see the section (mc.fill in sql/210): the work then happens in the statement that changes the blocks, on the
-- connection that issued it, and the tick only copies bytes to the connections in range (mc.block_event.pkt).

-- the pre-built packet of one fill event, kept next to the event
alter table mc.block_event add column if not exists pkt bytea;
alter table mc.block_event alter column pkt set storage external;               -- (no compression: it would cost more CPU than the 12 kB are worth)

create unlogged table if not exists mc.sbu_tpl (
    id    bigint generated always as identity,
    key   text primary key,               -- md5 of the 512-byte bit map
    n     int  not null,                  -- positions in the set
    tpl   text not null,                  -- the template for a state id of 1 or more
    tpl0  text not null                   -- the finished entries for state id 0 (air)
);
alter table mc.sbu_tpl alter column tpl set storage external;
alter table mc.sbu_tpl alter column tpl0 set storage external;

-- Build (and cache) the template of a bit map.  The cache keeps the newest 800 shapes (a shape is up to 36 kB): when it holds more than 1,000 the oldest are dropped.
create or replace function mc.sbu_build(p_cells bytea) returns mc.sbu_tpl language plpgsql volatile as $$
declare ord int[]; r mc.sbu_tpl; k text := md5(p_cells);
begin
    ord := mc.shortset_order(mc.cells_positions(p_cells));
    select string_agg(to_hex(8 + ((p >> 4) & 7)) || to_hex(p & 15) || case when ((p >> 11) & 1) = 0 then 'g' else 'h' end || to_hex((p >> 7) & 15) || 'z', '' order by o),
           string_agg(case when p < 128 then lpad(to_hex(p), 2, '0') else to_hex(8 + ((p >> 4) & 7)) || to_hex(p & 15) || lpad(to_hex(p >> 7), 2, '0') end, '' order by o)
      into r.tpl, r.tpl0
      from unnest(ord) with ordinality t(p, o);
    r.key := k; r.n := cardinality(ord);
    insert into mc.sbu_tpl (key, n, tpl, tpl0) values (r.key, r.n, r.tpl, r.tpl0) on conflict do nothing;
    if (select count(*) from mc.sbu_tpl) > 1000 then
        delete from mc.sbu_tpl where id < (select min(i) from (select id as i from mc.sbu_tpl order by id desc limit 800) q);
    end if;
    return r;
end $$;

-- The framed packet of ONE fill event: a section whose positions p_cells (bit map as in mc.block_event.cells) all changed to the block state p_state.
-- Equal to mc.section_update_packet(cx, sy, cz, mc.shortset_order(mc.cells_positions(p_cells)), <p_state for every position>).
create or replace function mc.fill_packet(p_cx int, p_sy int, p_cz int, p_cells bytea, p_state int) returns bytea language plpgsql volatile as $$
declare n int := bit_count(p_cells); v_n int; v_t text; hx text; ord int[]; b mc.sbu_tpl;
begin
    if n = 0 then return null; end if;
    if n = 1 or p_state < 0 or p_state > 65535 then                              -- one position is a block_update; a state id of 2^16 or more would need five bytes: the general encoder
        ord := mc.shortset_order(mc.cells_positions(p_cells));
        return mc.section_update_packet(p_cx, p_sy, p_cz, ord, array_fill(p_state, array[cardinality(ord)]));
    end if;
    select s.n, case when p_state = 0 then s.tpl0 else s.tpl end into v_n, v_t from mc.sbu_tpl s where s.key = md5(p_cells);
    if not found then
        b := mc.sbu_build(p_cells); v_n := b.n; v_t := case when p_state = 0 then b.tpl0 else b.tpl end;
    end if;
    if p_state = 0 then hx := v_t;
    else
        -- three passes of replace() (translate() would do the first two in one, but it is five times slower: 0.3 ms against 0.05 ms for the 20 kB of a whole section)
        hx := replace(replace(replace(v_t,
                'g', case when p_state < 4 then to_hex(2 * p_state) else to_hex(8 + 2 * (p_state & 3)) end),                    -- the high digit of the second byte, bit 4 of the position clear / set
                'h', case when p_state < 4 then to_hex(2 * p_state + 1) else to_hex(9 + 2 * (p_state & 3)) end),
                'z', case when p_state < 4 then ''                                                                             -- two bytes per entry: nothing follows
                         when p_state < 512 then lpad(to_hex(p_state >> 2), 2, '0')                                          -- three bytes
                         else lpad(to_hex(128 | ((p_state >> 2) & 127)), 2, '0') || lpad(to_hex(p_state >> 9), 2, '0') end);  -- four bytes
    end if;
    return proto.frame(mc.pid('section_blocks_update'),
        int8send(((p_cx::bigint & 4194303) << 42) | (p_sy::bigint & 1048575) | ((p_cz::bigint & 4194303) << 20)) || proto.varint(v_n) || decode(hx, 'hex'));
end $$;

-- Can some connection see this chunk column (the rule of the tick's broadcast: a 'play' connection whose view centre is within view-distance + 1)?
create or replace function mc.chunk_watched(p_cx int, p_cz int) returns boolean language plpgsql stable as $$
declare r int := mc.prop_int('view-distance') + 1; w boolean;
begin
    select exists (select 1 from net.conn c where c.state = 'play' and not c.closing and c.view_cx is not null and abs(c.view_cx - p_cx) <= r and abs(c.view_cz - p_cz) <= r) into w;
    return w;
end $$;
