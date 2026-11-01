-- Integration, part 2: what a player does to the world and what the world tells players.
--
--   mc.apply_block_actions   serverbound player_action / use_item_on -> mc.set_block, with the checks listed below
--   mc.broadcast_block_events  block changes recorded by mc.set_block -> block_update / level_event / block_changed_ack
--   net.stream_chunks        a player entering another chunk -> set_chunk_cache_center, new chunks, forget_level_chunk
-- Everything is queued in mc.play_out (uncompressed frames); mc.server_tick drains it into net.outbox (sql/420).
--
-- Layouts (read from the 26.3 classes with tools/pkt_layout.py; the ones marked VERIFIED were also compared with the real server by tests/e2e/*_probe.py):
--   player_action  = VarInt action | block position (long) | face (unsigned byte) | VarInt sequence.   actions: 0 start destroy, 1 change destroy direction,
--                    2 abort, 3 stop destroy, 4 drop all, 5 drop item, 6 release use item, 7 swap with offhand, 8 stab.   VERIFIED (accepted and acted on)
--   use_item_on    = VarInt hand | block position | VarInt face | float x3 (cursor) | bool inside | bool world-border hit | VarInt sequence.   VERIFIED
--   block_update   = block position | VarInt state id.   VERIFIED
--   block_changed_ack = VarInt sequence (the latest one of the tick, sent after the tick's block updates).   VERIFIED
--   level_event    = int event | block position | int data | bool global.   Event 2001 (block broken) with the old state id as data goes to the OTHER
--                    players in range, before their block_update.   VERIFIED
--   set_chunk_cache_center = VarInt x | VarInt z.   forget_level_chunk = int z | int x (a ChunkPos long: z in the high half).   VERIFIED
-- NOT used: section_blocks_update (vanilla batches several changes in one section into it; one block_update per change is equally valid and was
-- what the real server sent for two changes in quick succession; the batched layout was not compared).
--
-- Rules implemented, and where they come from:
--   * creative breaks on start_destroy_block; survival on stop_destroy_block (the client's break time is trusted: no per-block hardness check)
--   * reach: the block's box must be within 5.5 (survival) / 6.0 (creative) of the eye (feet + 1.62): block interaction range 4.5 / 5.0 plus the
--     server's 1.0 slack (read from the 26.3 classes, not measured)
--   * survival cannot break bedrock, barriers, command blocks, structure blocks, jigsaws, end portal parts
--   * placing needs a block item (item name = block name), an empty or replaceable target next to the clicked face, no overlap with the placer's box;
--     the block is the item's DEFAULT state (no orientation: stairs, logs, doors are placed with their default properties)
--   * survival consumes one item and the server tells the client (container_set_slot); creative does not
--   * adventure and spectator players change nothing
--   * a refused action sends the client the authoritative block_update(s), then the ack: vanilla does the same so the client undoes its prediction

create unlogged table if not exists mc.pending_ack (seq bigint generated always as identity, conn_id int not null, sequence int not null);
create unlogged table if not exists mc.block_actor (dimension text not null, x int not null, y int not null, z int not null, conn_id int not null);

create or replace function mc.block_state_id(p_state text) returns int language sql stable parallel safe as $$
    select state_id from ref.block_state where name = p_state $$;

create or replace function mc.unbreakable(p_state text) returns boolean language sql immutable parallel safe as $$
    select split_part(p_state, '[', 1) in ('minecraft:bedrock', 'minecraft:barrier', 'minecraft:command_block', 'minecraft:repeating_command_block',
        'minecraft:chain_command_block', 'minecraft:structure_block', 'minecraft:jigsaw', 'minecraft:end_portal_frame', 'minecraft:end_portal',
        'minecraft:end_gateway', 'minecraft:nether_portal') $$;

create or replace function mc.replaceable(p_state text) returns boolean language sql immutable parallel safe as $$
    select mc.is_air(p_state) or split_part(p_state, '[', 1) in ('minecraft:water', 'minecraft:lava', 'minecraft:short_grass', 'minecraft:tall_grass',
        'minecraft:fern', 'minecraft:large_fern', 'minecraft:dead_bush', 'minecraft:seagrass', 'minecraft:tall_seagrass') $$;

-- Is the block (bx, by, bz) within the interaction range of a player standing at (px, py, pz)?
create or replace function mc.in_block_reach(px float8, py float8, pz float8, bx int, by int, bz int, gm int) returns boolean language sql immutable parallel safe as $$
    select (power(greatest(bx - px, 0, px - (bx + 1)), 2) + power(greatest(by - (py + 1.62), 0, (py + 1.62) - (by + 1)), 2) + power(greatest(bz - pz, 0, pz - (bz + 1)), 2))
           < power(case when gm = 1 then 6.0 else 5.5 end, 2) $$;

-- Does a player standing at (px, py, pz) (box 0.6 wide, 1.8 high) overlap the block cell (bx, by, bz)?
create or replace function mc.overlaps_player(px float8, py float8, pz float8, bx int, by int, bz int) returns boolean language sql immutable parallel safe as $$
    select px - 0.3 < bx + 1 and px + 0.3 > bx and py < by + 1 and py + 1.8 > by and pz - 0.3 < bz + 1 and pz + 0.3 > bz $$;

create or replace function mc.queue_block_update(p_conn int, x int, y int, z int, p_state text) returns void language sql as $$
    insert into mc.play_out (conn_id, data) select p_conn, proto.frame(mc.pid('block_update'), proto.position(x, y, z) || proto.varint(mc.block_state_id(p_state)))
    where p_state is not null $$;

------------------------------------------------------------------------------------------------ serverbound block actions
-- Reads the rows mc.tick() left in mc.play_in_work (it deletes only the kinds it handles itself).  Returns what happened.
create or replace function mc.apply_block_actions(cur_tick bigint) returns table (breaks int, places int, refused int) language plpgsql as $$
declare
    i_act int := mc.sid('player_action'); i_use int := mc.sid('use_item_on'); dim text := 'minecraft:overworld';
    r record; act int; o int; f int; pos record; face int; sq int; hand int;
    cur text; clicked text; item text; cnt int; blk text; v_slot int; tx int; ty int; tz int; ok boolean;
begin
    breaks := 0; places := 0; refused := 0;
    for r in select m.seq as mseq, m.packet_id, m.conn_id, m.body, p.uuid, p.gamemode, p.x, p.y, p.z, p.held_slot, p.inv_state
             from mc.play_in_work m join mc.player p on p.conn_id = m.conn_id
             where m.packet_id in (i_act, i_use) order by m.seq loop
        begin
            if r.packet_id = i_act then
                continue when length(r.body) < 11;
                select val, nxt into act, o from proto.varint_read(r.body, 0);
                select * into pos from proto.position_read(r.body, o);
                sq := (select val from proto.varint_read(r.body, o + 9));
                if act in (0, 2, 3) and sq is not null then insert into mc.pending_ack (conn_id, sequence) values (r.conn_id, sq); end if;
                continue when not ((act = 0 and r.gamemode = 1) or (act = 3 and r.gamemode = 0));
                cur := mc.get_block(dim, pos.x, pos.y, pos.z);
                continue when cur is null or mc.is_air(cur);
                if not mc.in_block_reach(r.x, r.y, r.z, pos.x, pos.y, pos.z, r.gamemode) or (r.gamemode = 0 and mc.unbreakable(cur)) then
                    perform mc.queue_block_update(r.conn_id, pos.x, pos.y, pos.z, cur);
                    refused := refused + 1;
                else
                    perform mc.set_block(dim, pos.x, pos.y, pos.z, 'minecraft:air');
                    insert into mc.block_actor values (dim, pos.x, pos.y, pos.z, r.conn_id);
                    breaks := breaks + 1;
                end if;
            else
                continue when length(r.body) < 19;
                hand := (select val from proto.varint_read(r.body, 0));
                select nxt into o from proto.varint_read(r.body, 0);
                select * into pos from proto.position_read(r.body, o);
                select val, nxt into face, f from proto.varint_read(r.body, o + 8);
                continue when face is null or f + 14 >= length(r.body) + 1;
                sq := (select val from proto.varint_read(r.body, f + 14));
                if sq is not null then insert into mc.pending_ack (conn_id, sequence) values (r.conn_id, sq); end if;
                v_slot := case hand when 0 then 36 + r.held_slot else 45 end;
                select i.item, i.count into item, cnt from mc.inventory_slot i where i.player = r.uuid and i.slot = v_slot;
                continue when item is null or cnt <= 0 or face not between 0 and 5;
                blk := (select b.name from ref.block b where b.name = item);
                continue when blk is null;
                tx := pos.x + case face when 4 then -1 when 5 then 1 else 0 end;
                ty := pos.y + case face when 0 then -1 when 1 then 1 else 0 end;
                tz := pos.z + case face when 2 then -1 when 3 then 1 else 0 end;
                clicked := mc.get_block(dim, pos.x, pos.y, pos.z);
                cur := mc.get_block(dim, tx, ty, tz);
                ok := r.gamemode in (0, 1) and clicked is not null and cur is not null and mc.replaceable(cur)
                      and mc.in_block_reach(r.x, r.y, r.z, pos.x, pos.y, pos.z, r.gamemode) and not mc.overlaps_player(r.x, r.y, r.z, tx, ty, tz);
                if not ok then
                    perform mc.queue_block_update(r.conn_id, tx, ty, tz, cur);
                    perform mc.queue_block_update(r.conn_id, pos.x, pos.y, pos.z, clicked);
                    refused := refused + 1;
                    continue;
                end if;
                perform mc.set_block(dim, tx, ty, tz, blk);
                insert into mc.block_actor values (dim, tx, ty, tz, r.conn_id);
                places := places + 1;
                -- vanilla (recorded): the placing player is sent the clicked block's state and the new block's state, then the broadcast sends the new
                -- block again, then the ack: [clicked, target, target, ack]
                perform mc.queue_block_update(r.conn_id, pos.x, pos.y, pos.z, clicked);
                perform mc.queue_block_update(r.conn_id, tx, ty, tz, mc.get_block(dim, tx, ty, tz));
                if r.gamemode = 0 then
                    perform mc.set_slot(r.uuid, v_slot, item, cnt - 1);
                    update mc.player set inv_state = inv_state + 1 where uuid = r.uuid;
                    insert into mc.play_out (conn_id, data) values (r.conn_id, mc.pkt_container_set_slot(r.inv_state + 1, v_slot, item, cnt - 1));
                end if;
            end if;
        exception when others then
            raise notice 'mc.apply_block_actions: packet from connection % ignored: %', r.conn_id, sqlerrm;
            refused := refused + 1;
        end;
    end loop;
    delete from mc.play_in_work where packet_id in (i_act, i_use);
    return next;
end $$;

------------------------------------------------------------------------------------------------ broadcast
-- Net change per position (a block changed twice in a tick is one update; changed and changed back is none), sent to every player whose client has
-- the chunk loaded (net.conn.view_cx/view_cz, radius view-distance + 1).  Whole-section changes (mc.fill) re-send the chunk.  The acks go out last.
create or replace function mc.broadcast_block_events() returns int language plpgsql as $$
declare r int := mc.prop_int('view-distance') + 1; i_bu int := mc.pid('block_update'); i_le int := mc.pid('level_event'); n int;
begin
    create temp table if not exists _bchg (dimension text, x int, y int, z int, old_state text, new_state text, old_id int, new_id int) on commit delete rows;
    create temp table if not exists _bchunk (dimension text, cx int, cz int) on commit delete rows;
    delete from _bchg; delete from _bchunk;

    with ev as (delete from mc.block_event where kind = 'block' returning id, dimension, x, y, z, old_state, new_state)
    insert into _bchg (dimension, x, y, z, old_state, new_state)
    select dimension, x, y, z, (array_agg(old_state order by id))[1], (array_agg(new_state order by id desc))[1]
    from ev group by dimension, x, y, z
    having (array_agg(old_state order by id))[1] <> (array_agg(new_state order by id desc))[1];
    get diagnostics n = row_count;
    update _bchg set old_id = mc.block_state_id(old_state), new_id = mc.block_state_id(new_state);

    with ev as (delete from mc.block_event where kind = 'section' returning dimension, x, z)
    insert into _bchunk (dimension, cx, cz)
    select distinct dimension, x >> 4, z >> 4 from ev;

    if n > 0 then
        -- the break effect for everybody except the player who did it
        insert into mc.play_out (conn_id, data)
        select c.conn_id, proto.frame(i_le, proto.i32(2001) || proto.position(b.x, b.y, b.z) || proto.i32(b.old_id) || '\x00'::bytea)
        from _bchg b
        join net.conn c on c.state = 'play' and not c.closing and c.view_cx is not null and abs(c.view_cx - (b.x >> 4)) <= r and abs(c.view_cz - (b.z >> 4)) <= r
        where b.new_id = 0 and b.old_id <> 0
          and not exists (select 1 from mc.block_actor a where a.dimension = b.dimension and a.x = b.x and a.y = b.y and a.z = b.z and a.conn_id = c.conn_id)
        order by b.x, b.y, b.z;
        insert into mc.play_out (conn_id, data)
        select c.conn_id, proto.frame(i_bu, proto.position(b.x, b.y, b.z) || proto.varint(b.new_id))
        from _bchg b
        join net.conn c on c.state = 'play' and not c.closing and c.view_cx is not null and abs(c.view_cx - (b.x >> 4)) <= r and abs(c.view_cz - (b.z >> 4)) <= r
        order by b.x, b.y, b.z;
    end if;

    insert into mc.play_out (conn_id, data)
    select c.conn_id, mc.chunk_packet(k.dimension, k.cx, k.cz)
    from _bchunk k join net.conn c on c.state = 'play' and not c.closing and c.view_cx is not null and abs(c.view_cx - k.cx) <= r and abs(c.view_cz - k.cz) <= r;

    -- the acknowledgement: only the latest sequence of each connection this tick, after its block updates
    insert into mc.play_out (conn_id, data)
    select conn_id, proto.frame(mc.pid('block_changed_ack'), proto.varint(max(sequence))) from mc.pending_ack group by conn_id;
    truncate mc.pending_ack;
    truncate mc.block_actor;
    return n;
end $$;

------------------------------------------------------------------------------------------------ chunk streaming
-- A player whose chunk differs from the one the client's view is centred on: set_chunk_cache_center, forget the chunks that left the square, send the
-- ones that entered it (nearest first), as vanilla does (verified order: centre, forgets, then the batch).  The square has radius view-distance + 1.
create or replace function net.stream_chunks() returns int language plpgsql as $$
declare r int := mc.prop_int('view-distance') + 1; dim text := 'minecraft:overworld'; n int;
        i_ctr int := mc.pid('set_chunk_cache_center'); i_fg int := mc.pid('forget_level_chunk'); i_bs int := mc.pid('chunk_batch_start'); i_bf int := mc.pid('chunk_batch_finished');
begin
    create temp table if not exists _st (conn_id int primary key, ncx int, ncz int, ocx int, ocz int) on commit delete rows;
    create temp table if not exists _stn (conn_id int, x int, z int, d int) on commit delete rows;
    delete from _st; delete from _stn;
    insert into _st
    select c.conn_id, p.chunk_x, p.chunk_z, c.view_cx, c.view_cz
    from net.conn c join mc.player p on p.conn_id = c.conn_id
    where c.state = 'play' and not c.closing and c.view_cx is not null and (p.chunk_x, p.chunk_z) <> (c.view_cx, c.view_cz);
    get diagnostics n = row_count;
    if n = 0 or not mc.world_ready() then return 0; end if;

    insert into _stn
    select s.conn_id, s.ncx + dx, s.ncz + dz, dx * dx + dz * dz
    from _st s, generate_series(-r, r) dx, generate_series(-r, r) dz
    where abs(s.ncx + dx - s.ocx) > r or abs(s.ncz + dz - s.ocz) > r;
    perform mc.generate_flat(dim, x, z) from (select distinct x, z from _stn) t;

    insert into mc.play_out (conn_id, data) select conn_id, proto.frame(i_ctr, proto.varint(ncx) || proto.varint(ncz)) from _st order by conn_id;
    -- chunks that left the client's square: z ascending, then x (the order of the one recorded case)
    insert into mc.play_out (conn_id, data)
    select s.conn_id, proto.frame(i_fg, proto.i32(s.ocz + dz) || proto.i32(s.ocx + dx))
    from _st s, generate_series(-r, r) dx, generate_series(-r, r) dz
    where abs(s.ocx + dx - s.ncx) > r or abs(s.ocz + dz - s.ncz) > r
    order by s.conn_id, s.ocz + dz, s.ocx + dx;
    insert into mc.play_out (conn_id, data) select distinct conn_id, proto.frame(i_bs, '\x') from _stn;
    insert into mc.play_out (conn_id, data) select conn_id, mc.chunk_packet(dim, x, z) from _stn order by conn_id, d, x, z;
    insert into mc.play_out (conn_id, data) select conn_id, proto.frame(i_bf, proto.varint(count(*)::int)) from _stn group by conn_id;
    update net.conn c set view_cx = s.ncx, view_cz = s.ncz from _st s where c.conn_id = s.conn_id;
    return n;
end $$;
