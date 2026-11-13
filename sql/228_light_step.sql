-- Light engine, part 8: the tick step.  See docs/LIGHT.md.
--
-- Hook (the only one on other tracks' code): a statement trigger on mc.block_event copies every block change whose light properties differ (vanilla's
-- LightEngine.hasDifferentLightProperties: dampening or emission changed, or either state uses its occlusion shape) into mc.light_dirty; fills (kind 'cells' and 'section')
-- are copied whole.  mc.light_step(tick), called once per tick from mc.tick_core, empties the queue: the changes of one tick are brought into the stored light by
-- mc.light_update (a few cells) or mc.light_region (a fill), the version of every chunk whose light changed is bumped (its cached packet is rebuilt on the next send),
-- and the viewers of the chunks that sit on the border of their view get the light_update packet, which is what vanilla's ChunkHolder.broadcastChanges sends
-- (only to players for whom the chunk is on the border of the tracked square: the others compute the light of their own client).
create unlogged table if not exists mc.light_dirty (
    id        bigint generated always as identity primary key,
    dimension text not null,
    x         int  not null,
    y         int  not null,
    z         int  not null,
    kind      text not null default 'block',        -- block | cells | section (as mc.block_event)
    cells     bytea
);

create or replace function mc.light_differs(p_old text, p_new text) returns boolean language sql stable parallel safe as $$
  select coalesce(
      (select o.damp <> n.damp or o.emission <> n.emission or o.shaped or n.shaped
         from mc.light_state o, mc.light_state n where o.name = p_old and n.name = p_new), true) $$;

create or replace function mc.light_queue() returns trigger language plpgsql as $$
begin
    if not exists (select 1 from mc.light_state limit 1) then return null; end if;
    insert into mc.light_dirty (dimension, x, y, z, kind, cells)
    select n.dimension, n.x, n.y, n.z, n.kind, n.cells from new_events n where n.kind <> 'block' or mc.light_differs(n.old_state, n.new_state);
    return null;
end $$;
drop trigger if exists light_queue on mc.block_event;
create trigger light_queue after insert on mc.block_event referencing new table as new_events for each statement execute function mc.light_queue();

-- Mask of the cells whose level differs between two stored arrays (NULL = all zero).
create or replace function mc.light_diffmask(p_old bytea, p_new bytea) returns bit(4096) language plpgsql immutable parallel safe as $$
declare a record; b record;
begin
    select * into a from mc.light_planes(coalesce(p_old, decode(repeat('00', 2048), 'hex')));
    select * into b from mc.light_planes(coalesce(p_new, decode(repeat('00', 2048), 'hex')));
    return (a.c0 # b.c0) | (a.c1 # b.c1) | (a.c2 # b.c2) | (a.c3 # b.c3);
end $$;

-- lw_delta from lw_out (the layers about to be written) against the stored rows, with the cells that differ.
create or replace function mc.light_delta_from_out(p_dim text) returns void language plpgsql volatile as $$
begin
    insert into lw_delta
    select o.cx, o.cz, o.idx,
           (l.sky_kind, l.sky) is distinct from (o.sky_kind, o.sky), (l.block_kind, l.block) is distinct from (o.block_kind, o.block),
           case when (l.sky_kind, l.sky) is distinct from (o.sky_kind, o.sky) then mc.light_diffmask(l.sky, o.sky) end,
           case when (l.block_kind, l.block) is distinct from (o.block_kind, o.block) then mc.light_diffmask(l.block, o.block) end
      from lw_out o join mc.chunk_light l on l.dimension = p_dim and l.cx = o.cx and l.cz = o.cz and l.idx = o.idx
     where (l.sky_kind, l.sky, l.block_kind, l.block) is distinct from (o.sky_kind, o.sky, o.block_kind, o.block);
end $$;

-- The sections vanilla marks as changed (ChunkHolder.sectionLightChanged for every section of SectionPos.aroundAndAtBlockPos of a cell whose stored level was written):
-- a changed section, and every neighbouring section (also across edges and corners) that a changed cell touches at its border.  lw_mark (chunk, layer, sky, block).
create or replace function mc.light_marks(p_dim text) returns void language plpgsql volatile as $$
declare v_nsec int;
begin
    select d.height / 16 into v_nsec from mc.dimension d where d.name = p_dim;
    create temp table if not exists lw_mark (cx int not null, cz int not null, idx int not null, sky boolean not null, blk boolean not null) on commit delete rows;
    delete from lw_mark;
    insert into lw_mark
    select d.cx + o.dx, d.cz + o.dz, d.idx + o.dy,
           coalesce(bool_or(d.sky and bit_count(d.cs & m.m) > 0), false), coalesce(bool_or(d.blk and bit_count(d.cb & m.m) > 0), false)
      from lw_delta d
      cross join (select dx, dy, dz from generate_series(-1, 1) dx, generate_series(-1, 1) dy, generate_series(-1, 1) dz) o
      cross join lateral (select (case o.dx when -1 then mc.lk_x0() when 1 then mc.lk_x15() else mc.lk_ones() end
                                & case o.dy when -1 then mc.lk_y0() when 1 then mc.lk_y15() else mc.lk_ones() end
                                & case o.dz when -1 then mc.lk_z0() when 1 then mc.lk_z15() else mc.lk_ones() end) as m) m
     where d.idx + o.dy between 0 and v_nsec + 1
       and exists (select 1 from mc.chunk_light l where l.dimension = p_dim and l.cx = d.cx + o.dx and l.cz = d.cz + o.dz and l.idx = d.idx + o.dy)
     group by d.cx + o.dx, d.cz + o.dz, d.idx + o.dy
    having bool_or(d.sky and bit_count(d.cs & m.m) > 0) or bool_or(d.blk and bit_count(d.cb & m.m) > 0);
end $$;

-- The body of a light_update packet for one chunk from lw_mark: VarInt x, VarInt z, then the four bit sets and the two array lists of the chunk packet
-- (only the marked layers; sky and block are marked independently).
create or replace function mc.light_update_body(p_dim text, p_cx int, p_cz int) returns bytea language plpgsql stable as $$
declare r bytea;
begin
    select proto.varint(p_cx) || proto.varint(p_cz)
        || mc.mask_wire(coalesce(bit_or(1::bigint << m.idx) filter (where m.sky and l.sky_kind = 'data'), 0))
        || mc.mask_wire(coalesce(bit_or(1::bigint << m.idx) filter (where m.blk and l.block_kind = 'data'), 0))
        || mc.mask_wire(coalesce(bit_or(1::bigint << m.idx) filter (where m.sky and l.sky_kind = 'empty'), 0))
        || mc.mask_wire(coalesce(bit_or(1::bigint << m.idx) filter (where m.blk and l.block_kind = 'empty'), 0))
        || proto.varint(count(*) filter (where m.sky and l.sky_kind = 'data')::int)
        || coalesce(string_agg(proto.varint(octet_length(l.sky)) || l.sky, ''::bytea order by m.idx) filter (where m.sky and l.sky_kind = 'data'), '\x')
        || proto.varint(count(*) filter (where m.blk and l.block_kind = 'data')::int)
        || coalesce(string_agg(proto.varint(octet_length(l.block)) || l.block, ''::bytea order by m.idx) filter (where m.blk and l.block_kind = 'data'), '\x')
      into r
      from lw_mark m join mc.chunk_light l on l.dimension = p_dim and l.cx = m.cx and l.cz = m.cz and l.idx = m.idx
     where m.cx = p_cx and m.cz = p_cz;
    return r;
end $$;

-- One tick's changes.  Returns the number of light_update packets queued.
create or replace function mc.light_step(p_tick bigint default 0) returns int language plpgsql volatile set jit = off as $$
declare
    r        record;
    xs int[]; ys int[]; zs int[];
    big      boolean;
    cxs int[]; czs int[];
    n_pkt    int := 0;
    vd       int;
    k        int;
    res      int;
    pid      int;
begin
    if not exists (select 1 from mc.light_dirty) then return 0; end if;
    create temp table if not exists lw_all (cx int not null, cz int not null, idx int not null, sky boolean not null, blk boolean not null, cs bit(4096), cb bit(4096)) on commit delete rows;
    delete from lw_all;
    for r in select d.dimension from mc.light_dirty d group by d.dimension loop
        -- the changed cells: block events one by one; a fill or section event as its cells (up to 64) or, beyond that, the chunk columns around it are lit again
        with d as (delete from mc.light_dirty where dimension = r.dimension returning x, y, z, kind, cells),
        cells as (
            select d.x, d.y, d.z from d where d.kind = 'block'
            union
            select d.x + (b & 15), d.y + (b >> 8), d.z + ((b >> 4) & 15)
              from d, lateral generate_series(0, 4095) b
             where d.kind = 'cells' and d.cells is not null and bit_count(d.cells) <= 64 and ((get_byte(d.cells, b >> 3) >> (b & 7)) & 1) = 1),
        bigs as (select distinct (d.x >> 4) as cx, (d.z >> 4) as cz from d where d.kind = 'section' or (d.kind = 'cells' and (d.cells is null or bit_count(d.cells) > 64)))
        select coalesce(array_agg(c.x), '{}'), coalesce(array_agg(c.y), '{}'), coalesce(array_agg(c.z), '{}'),
               (select coalesce(array_agg(b.cx), '{}') from bigs b), (select coalesce(array_agg(b.cz), '{}') from bigs b)
          into xs, ys, zs, cxs, czs from cells c;
        res := 0;
        if cardinality(xs) > 0 then
            res := mc.light_update(r.dimension, xs, ys, zs);
            if res >= 0 then
                insert into lw_all select cx, cz, idx, sky, blk, cs, cb from lw_delta;
            else                                              -- the cube was too big, or a section turned empty / non-empty: the chunks around the cells are lit again
                select cxs || array_agg(distinct x >> 4), czs || array_agg(distinct z >> 4) into cxs, czs from unnest(xs, zs) u(x, z) cross join generate_series(-1, 1) dx;
            end if;
        end if;
        if cardinality(cxs) > 0 then
            -- (the chunks of the changed cells and their neighbours: the light of a chunk depends on the 14 cells around it)
            select array_agg(distinct a), array_agg(b) into cxs, czs
              from (select distinct c.cx + dx as a, c.cz + dz as b from unnest(cxs, czs) c(cx, cz), generate_series(-1, 1) dx, generate_series(-1, 1) dz) q;
            perform mc.light_region(r.dimension, cxs, czs);
            insert into lw_all select cx, cz, idx, sky, blk, cs, cb from lw_delta;
        end if;
    end loop;
    -- chunks whose light changed: new version (the cached packet), and the packets for the border viewers
    if exists (select 1 from lw_all) then
        update mc.chunk c set version = c.version + 1, dirty = false from (select distinct cx, cz from lw_all) a where c.dimension = 'minecraft:overworld' and c.cx = a.cx and c.cz = a.cz;
        vd := mc.prop_int('view-distance') + 1;
        pid := (select protocol_id from ref.packet where state = 'play' and direction = 'clientbound' and name = 'minecraft:light_update');
        delete from lw_delta; insert into lw_delta select cx, cz, idx, sky, blk, cs, cb from lw_all;
        perform mc.light_marks('minecraft:overworld');
        insert into mc.play_out (conn_id, data)
        select c.conn_id, proto.frame(pid, mc.light_update_body('minecraft:overworld', m.cx, m.cz))
          from (select distinct cx, cz from lw_mark) m
          join net.conn c on c.state = 'play' and not c.closing and c.view_cx is not null and greatest(abs(c.view_cx - m.cx), abs(c.view_cz - m.cz)) = vd
         order by m.cx, m.cz, c.conn_id;
        get diagnostics n_pkt = row_count;
    end if;
    return n_pkt;
end $$;
