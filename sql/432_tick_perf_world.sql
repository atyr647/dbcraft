-- Tick performance, part 3: visibility, chunk streaming, idle block handling.  See docs/PERF-TICK.md.
--
-- The common cause of most of the cost removed here: PL/pgSQL caches the plan of every statement, but TRUNCATE (including the implicit one at the end of a
-- transaction for ON COMMIT DELETE ROWS temp tables) and ANALYZE of a temp table invalidate cached plans, so every statement touching those tables was planned
-- again on every tick: 12-14 ms of planning per tick in the baseline (pg_stat_statements.track_planning).  Here the per-tick sets live in PL/pgSQL arrays
-- (an ordinary table emptied with DELETE bloats until a vacuum: measured 450 pages for 278 live rows), nothing is analysed per tick, and plans stay cached.


------------------------------------------------------------------------------------------------ who sees whom
-- Same rule and same packets as sql/330's version (two players see each other when their chunk coordinates differ by at most min(view-distance, 32) in both
-- axes; only pairs involving a player that changed chunk can change).  Differences, all internal:
--   * no slim temp copy of the players, no scratch tables and no ANALYZE: the dirty players are looked up through the unique entity-id index (= any(array)),
--     the others are compared against by a plain scan of the 500-ish online players, and the wanted pairs are kept in arrays (a few hundred elements) that the
--     two later statements read with unnest();
--   * nothing to do (no dirty online player) returns immediately, apart from clearing stray flags;
--   * the pairs to delete are found through the primary key (viewer, target) and the target index, not by scanning every visible pair;
--   * remove_entities lists the ids in ascending order (it was unspecified).
create or replace function mc.refresh_visibility() returns table(added int, removed int) language plpgsql as $$
declare r int := least(mc.prop_int('view-distance'), 32); d int[]; wv int[]; wt int[]; wc int[];
begin
  added := 0; removed := 0;
  select coalesce(array_agg(entity_id), '{}') into d from mc.player where vis_dirty and conn_id is not null;
  if cardinality(d) > 0 then
    select coalesce(array_agg(q.v), '{}'), coalesce(array_agg(q.t), '{}'), coalesce(array_agg(q.c), '{}') into wv, wt, wc
      from (select a.entity_id as v, b.entity_id as t, a.conn_id as c
              from mc.player a join mc.player b on b.entity_id <> a.entity_id and abs(a.chunk_x - b.chunk_x) <= r and abs(a.chunk_z - b.chunk_z) <= r and b.conn_id is not null
             where a.entity_id = any (d) and a.conn_id is not null
            union
            select a.entity_id, b.entity_id, a.conn_id
              from mc.player b join mc.player a on a.entity_id <> b.entity_id and abs(a.chunk_x - b.chunk_x) <= r and abs(a.chunk_z - b.chunk_z) <= r and a.conn_id is not null
             where b.entity_id = any (d) and b.conn_id is not null) q;

    -- newly visible: add_entity at the position the other viewers were last told (shared delta base)
    with w as (select * from unnest(wv, wt, wc) as w(viewer_eid, target_eid, viewer_conn)),
    ins as (
      insert into mc.visible (viewer_eid, target_eid, viewer_conn)
      select w.viewer_eid, w.target_eid, w.viewer_conn from w
       where not exists (select 1 from mc.visible v where v.viewer_eid = w.viewer_eid and v.target_eid = w.target_eid)
      returning viewer_eid, target_eid, viewer_conn),
    q as (
      insert into mc.play_out (conn_id, data)
      select i.viewer_conn, string_agg(mc.pkt_add_player_entity(t.entity_id, t.uuid, t.sent_qx / 4096.0, t.sent_qy / 4096.0, t.sent_qz / 4096.0, t.sent_yaw, t.sent_pitch, t.sent_yaw), '\x'::bytea order by t.entity_id)
        from ins i join mc.player t on t.entity_id = i.target_eid group by i.viewer_conn
      returning 1)
    select (select count(*) from ins) into added;

    -- no longer visible (only pairs involving a dirty player can have changed)
    with w as (select * from unnest(wv, wt) as w(viewer_eid, target_eid)),
    del as (
      delete from mc.visible v
       where (v.viewer_eid = any (d) or v.target_eid = any (d))
         and not exists (select 1 from w where w.viewer_eid = v.viewer_eid and w.target_eid = v.target_eid)
      returning v.viewer_conn, v.target_eid),
    q as (
      insert into mc.play_out (conn_id, data)
      select viewer_conn, mc.pkt_remove_entities(array_agg(target_eid order by target_eid)) from del group by viewer_conn
      returning 1)
    select (select count(*) from del) into removed;
  end if;
  update mc.player set vis_dirty = false where vis_dirty;
  return next;
end $$;

------------------------------------------------------------------------------------------------ chunk streaming
-- Same packets, same order as sql/410's version.  Differences, all internal: the per-tick sets live in arrays instead of temp tables (no plan invalidation, no
-- bloat); flat-world generation only for chunks that do not exist yet (it was called, and found the chunk, for every chunk sent); a chunk whose cached packet is
-- current is read with one join instead of a function call per chunk (mc.chunk_packet: a row lock on the chunk, three lookups, 28 us each).  The cache counts
-- as current under exactly the condition under which mc.ensure_chunk_current() does nothing and mc.chunk_packet() returns the cached bytes: chunk not dirty,
-- heightmaps present and not dirty, cache version = chunk version; anything else goes through mc.chunk_packet() as before.
create or replace function net.stream_chunks() returns int language plpgsql as $$
declare r int := mc.prop_int('view-distance') + 1; dim text := 'minecraft:overworld'; n int;
        i_ctr int := mc.pid('set_chunk_cache_center'); i_fg int := mc.pid('forget_level_chunk'); i_bs int := mc.pid('chunk_batch_start'); i_bf int := mc.pid('chunk_batch_finished');
        sc int[]; sncx int[]; sncz int[]; socx int[]; socz int[];            -- the players whose chunk changed: connection, new chunk, chunk their client is centred on
        nc int[]; nx int[]; nz int[]; nd int[];                              -- the chunks they need: connection, x, z, squared distance
begin
    select array_agg(c.conn_id::int), array_agg(p.chunk_x), array_agg(p.chunk_z), array_agg(c.view_cx), array_agg(c.view_cz) into sc, sncx, sncz, socx, socz
    from net.conn c join mc.player p on p.conn_id = c.conn_id
    where c.state = 'play' and not c.closing and c.view_cx is not null and (p.chunk_x, p.chunk_z) <> (c.view_cx, c.view_cz);
    n := coalesce(cardinality(sc), 0);
    if n = 0 or not mc.world_ready() then return 0; end if;

    select coalesce(array_agg(q.conn_id), '{}'), coalesce(array_agg(q.x), '{}'), coalesce(array_agg(q.z), '{}'), coalesce(array_agg(q.d), '{}') into nc, nx, nz, nd
    from (select s.conn_id, s.ncx + dx as x, s.ncz + dz as z, dx * dx + dz * dz as d
            from unnest(sc, sncx, sncz, socx, socz) as s(conn_id, ncx, ncz, ocx, ocz), generate_series(-r, r) dx, generate_series(-r, r) dz
           where abs(s.ncx + dx - s.ocx) > r or abs(s.ncz + dz - s.ocz) > r) q;
    perform mc.generate_flat(dim, m.x, m.z)
       from (select distinct t.x, t.z from unnest(nx, nz) as t(x, z)
              where not exists (select 1 from mc.chunk c where c.dimension = dim and c.cx = t.x and c.cz = t.z)) m;

    insert into mc.play_out (conn_id, data)
    select s.conn_id, proto.frame(i_ctr, proto.varint(s.ncx) || proto.varint(s.ncz)) from unnest(sc, sncx, sncz) as s(conn_id, ncx, ncz) order by s.conn_id;
    -- chunks that left the client's square: z ascending, then x (the order of the one recorded case)
    insert into mc.play_out (conn_id, data)
    select s.conn_id, proto.frame(i_fg, proto.i32(s.ocz + dz) || proto.i32(s.ocx + dx))
    from unnest(sc, sncx, sncz, socx, socz) as s(conn_id, ncx, ncz, ocx, ocz), generate_series(-r, r) dx, generate_series(-r, r) dz
    where abs(s.ocx + dx - s.ncx) > r or abs(s.ocz + dz - s.ncz) > r
    order by s.conn_id, s.ocz + dz, s.ocx + dx;
    insert into mc.play_out (conn_id, data) select distinct t.conn_id, proto.frame(i_bs, '\x') from unnest(nc) as t(conn_id);
    insert into mc.play_out (conn_id, data)
    select s.conn_id, coalesce(k.packet, mc.chunk_packet(dim, s.x, s.z))
      from unnest(nc, nx, nz, nd) as s(conn_id, x, z, d)
      left join mc.chunk c on c.dimension = dim and c.cx = s.x and c.cz = s.z and not c.dirty and not c.hm_dirty and c.hm_world_surface is not null
      left join mc.chunk_cache k on k.dimension = c.dimension and k.cx = c.cx and k.cz = c.cz and k.version = c.version
     order by s.conn_id, s.d, s.x, s.z;
    insert into mc.play_out (conn_id, data) select t.conn_id, proto.frame(i_bf, proto.varint(count(*)::int)) from unnest(nc) as t(conn_id) group by t.conn_id;
    update net.conn c set view_cx = s.ncx, view_cz = s.ncz from unnest(sc, sncx, sncz) as s(conn_id, ncx, ncz) where c.conn_id = s.conn_id;
    return n;
end $$;

------------------------------------------------------------------------------------------------ idle block handling
-- Copies of sql/410's two block functions with one idle early return each (see the marked comment inside).  Ticks without block activity, the usual case,
-- used to plan and run six statements for nothing (1.6-3.2 ms per tick).
create or replace function mc.apply_block_actions(cur_tick bigint) returns table (breaks int, places int, refused int) language plpgsql as $$
declare
    i_act int := mc.sid('player_action'); i_use int := mc.sid('use_item_on'); dim text := 'minecraft:overworld';
    r record; act int; o int; f int; pos record; face int; sq int; hand int;
    cur text; clicked text; item text; cnt int; blk text; v_slot int; tx int; ty int; tz int; ok boolean;
begin
    breaks := 0; places := 0; refused := 0;
    -- (idle early return, the only change to this copy: no block packet this tick, nothing to do; saves planning and cursor setup every tick)
    if not exists (select 1 from mc.play_in_work m where m.packet_id in (i_act, i_use)) then return next; return; end if;
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

create or replace function mc.broadcast_block_events() returns int language plpgsql as $$
declare r int := mc.prop_int('view-distance') + 1; i_bu int := mc.pid('block_update'); i_le int := mc.pid('level_event'); n int;
begin
    -- (idle early return, the only change to this copy: no recorded block change, section change or pending acknowledgement)
    if not exists (select 1 from mc.block_event) and not exists (select 1 from mc.pending_ack) then return 0; end if;
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

------------------------------------------------------------------------------------------------ the originals, kept for the equivalence tests
-- mc.refresh_visibility_general(): exact copy of sql/330's version, with ONE change so that results can be compared: remove_entities lists its ids in ascending
-- order (the original order was unspecified).  net.stream_chunks_general(): exact copy of sql/410's version.  tests/sql/432_tick_perf_world.sql runs both on
-- the same random states and compares everything.  Nothing in the server calls them.
create or replace function mc.refresh_visibility_general() returns table(added int, removed int) language plpgsql as $$
declare r int := least(mc.prop_int('view-distance'), 32);
begin
  create temp table if not exists _vis_want (viewer_eid int, target_eid int, viewer_conn int, primary key (viewer_eid, target_eid)) on commit delete rows;
  delete from _vis_want;
  perform mc.prof('vis start');
  -- A slim, freshly analysed copy of the online players: the planner then knows how few are dirty (measured: comparing against the wide, never-analysed
  -- mc.player made it compare every pair, 90 ms for 20 dirty players among 500).
  create temp table if not exists _vis_on (eid int primary key, conn int, cx int, cz int, dirty boolean) on commit delete rows;
  delete from _vis_on;
  insert into _vis_on select entity_id, conn_id, chunk_x, chunk_z, vis_dirty from mc.player where conn_id is not null;
  analyze _vis_on;
  insert into _vis_want
  select a.eid, b.eid, a.conn from _vis_on a join _vis_on b on b.eid <> a.eid and abs(a.cx - b.cx) <= r and abs(a.cz - b.cz) <= r where a.dirty
  union
  select a.eid, b.eid, a.conn from _vis_on b join _vis_on a on a.eid <> b.eid and abs(a.cx - b.cx) <= r and abs(a.cz - b.cz) <= r where b.dirty;

  perform mc.prof('vis A compute wanted pairs');
  -- newly visible: add_entity at the position the other viewers were last told (shared delta base)
  with ins as (
    insert into mc.visible (viewer_eid, target_eid, viewer_conn)
    select w.viewer_eid, w.target_eid, w.viewer_conn from _vis_want w
     where not exists (select 1 from mc.visible v where v.viewer_eid = w.viewer_eid and v.target_eid = w.target_eid)
    returning viewer_eid, target_eid, viewer_conn),
  q as (
    insert into mc.play_out (conn_id, data)
    select i.viewer_conn, string_agg(mc.pkt_add_player_entity(t.entity_id, t.uuid, t.sent_qx / 4096.0, t.sent_qy / 4096.0, t.sent_qz / 4096.0, t.sent_yaw, t.sent_pitch, t.sent_yaw), '\x'::bytea order by t.entity_id)
      from ins i join mc.player t on t.entity_id = i.target_eid group by i.viewer_conn
    returning 1)
  select (select count(*) from ins) into added;

  perform mc.prof('vis B insert new pairs + add_entity packets');
  -- no longer visible (only pairs involving a dirty player can have changed)
  with del as (
    delete from mc.visible v
     where (v.viewer_eid in (select eid from _vis_on where dirty) or v.target_eid in (select eid from _vis_on where dirty))
       and not exists (select 1 from _vis_want w where w.viewer_eid = v.viewer_eid and w.target_eid = v.target_eid)
    returning v.viewer_conn, v.target_eid),
  q as (
    insert into mc.play_out (conn_id, data)
    select viewer_conn, mc.pkt_remove_entities(array_agg(target_eid order by target_eid)) from del group by viewer_conn
    returning 1)
  select (select count(*) from del) into removed;

  perform mc.prof('vis C delete old pairs + remove packets');
  update mc.player set vis_dirty = false where vis_dirty;
  perform mc.prof('vis D clear dirty flags');
  return next;
end $$;

create or replace function net.stream_chunks_general() returns int language plpgsql as $$
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
