-- Tick performance, part 6: no relation files created or deleted by the tick.  See docs/PERF-TICK.md ("Relation-file churn").
--
-- Where the churn came from and what replaced it (every change is in the file that defines the function; this file only holds the originals for the tests):
--   * mc.deliver_ready_chunks (sql/430_chunk_queue.sql): the scratch table _rdy (ON COMMIT DELETE ROWS) is a PL/pgSQL array set now.
--   * mc.broadcast_block_events (sql/432): the scratch tables _bchg and _bchunk are arrays; mc.pending_ack and mc.block_actor are consumed with DELETE instead of TRUNCATE.
--   * mc.server_tick (sql/430_tick_perf.sql): the once-a-second TRUNCATE of the three queues only the tick uses is skipped for a queue that was not written
--     since the last one (its file has zero length), so an idle server creates no relation file.
--   * mc.ensure_chunk_current (sql/220): takes its row lock only when the chunk is dirty.
--   * net.process_fast (sql/430_tick_perf.sql): keep-alive answers and teleport confirmations are applied in one UPDATE instead of one net.handle call each (0.3 ms
--     each: 500 answers made a 330 ms tick every 15 seconds).  Not file churn, but the other slow-tick cause found on the way.
--
-- Below: the previous bodies of the three rewritten functions, byte for byte except the name, so that tests/sql/437_tick_churn.sql can run both on the same state.
-- Nothing in the server calls them.  (They need the scratch tables, which they create themselves.)

create or replace function mc.deliver_ready_chunks_general() returns int language plpgsql volatile as $$
declare
    r     int := mc.prop_int('view-distance') + 1;
    cap   int := case when mc.chunk_generation_async() then coalesce(mc.prop_int('dbcraft.chunk-batch-max'), 64) else 2147483647 end;
    i_bs  int := mc.pid('chunk_batch_start');
    i_bf  int := mc.pid('chunk_batch_finished');
    n     int;
begin
    if not exists (select 1 from mc.chunk_wanted) then return 0; end if;
    delete from mc.chunk_wanted w
     where not exists (select 1 from net.conn c where c.conn_id = w.conn_id and c.state = 'play' and not c.closing and c.view_cx is not null
                          and abs(c.view_cx - w.cx) <= r and abs(c.view_cz - w.cz) <= r);
    create temp table if not exists _rdy (conn_id int, dimension text, cx int, cz int, dist int) on commit delete rows;
    delete from _rdy;
    insert into _rdy
    select q.conn_id, q.dimension, q.cx, q.cz, q.dist
      from (select w.conn_id, w.dimension, w.cx, w.cz, w.dist, row_number() over (partition by w.conn_id order by w.dist, w.cx, w.cz) rn
              from mc.chunk_wanted w join mc.chunk c on c.dimension = w.dimension and c.cx = w.cx and c.cz = w.cz) q
     where q.rn <= cap;
    get diagnostics n = row_count;
    if n = 0 then return 0; end if;
    delete from mc.chunk_wanted w using _rdy d where w.conn_id = d.conn_id and w.dimension = d.dimension and w.cx = d.cx and w.cz = d.cz;
    insert into mc.play_out (conn_id, data) select distinct conn_id, proto.frame(i_bs, '\x') from _rdy;
    insert into mc.play_out (conn_id, data) select conn_id, mc.chunk_packet(dimension, cx, cz) from _rdy order by conn_id, dist, cx, cz;
    insert into mc.play_out (conn_id, data) select conn_id, proto.frame(i_bf, proto.varint(count(*)::int)) from _rdy group by conn_id;
    return n;
end $$;

create or replace function mc.broadcast_block_events_general() returns int language plpgsql as $$
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

create or replace function net.process_fast_general() returns int language plpgsql as $$
declare r record; n int; handled int[] := net.handled_play_ids();
        known int[] := (select coalesce(array_agg(protocol_id), '{}') from ref.packet where state = 'play' and direction = 'serverbound');
        both_ids int[] := array[mc.sid('keep_alive'), mc.sid('accept_teleportation')];
begin
    delete from net.batch;
    with t as (delete from net.inbox returning conn_id, seq, payload),
         c as (select t.conn_id, t.seq, t.payload, net.pid(t.payload) as pid, (n.state = 'play' and not n.closing) as live
                 from t left join net.conn n on n.conn_id = t.conn_id),
         k as (select c.*, (c.live and c.pid = any (known)) as known_play from c),
         to_game as (
             insert into mc.play_in_work (seq, conn_id, packet_id, body)
             select seq, conn_id, pid, substring(payload from net.pid_len(payload) + 1)
               from k where known_play and (not (pid = any (handled)) or pid = any (both_ids))
             returning 1),
         to_batch as (
             insert into net.batch (conn_id, seq, payload)
             select conn_id, seq, payload from k where not (known_play and not (pid = any (handled)))
             returning 1)
    select (select count(*) from t) into n;
    if n = 0 then return 0; end if;
    -- idle bookkeeping: nothing reads it yet, one refresh per second per connection is plenty (it used to be a write of every connection every tick)
    update net.conn c set last_activity = now()
     where c.last_activity < now() - interval '1 second'
       and c.conn_id in (select conn_id from net.batch union select conn_id from mc.play_in_work);
    for r in select conn_id, payload from net.batch order by conn_id, seq loop
        begin
            perform net.handle(r.conn_id, r.payload);
        exception when others then
            perform net.fail(r.conn_id, sqlerrm);
        end;
    end loop;
    return n;
end $$;
