-- Integration, part 3: the one entry point a gateway calls each tick, and the queue contract.
--
--   gateway --COPY--> net.inbox            frames of every connection (payload = packet id || body, without the length prefix)
--   select mc.server_tick();                one call per 50 ms
--   gateway <-------- net.drain_outbox()    (conn_id, bytes, close): write the bytes, close the socket when `close` is true
--   events:  select net.on_connect(conn_id [, ip]);   select net.on_disconnect(conn_id);
--
-- Queues.  The connection layer writes net.outbox directly (login, configuration, the join burst).  The game and the integration write mc.play_out
-- (uncompressed frames).  Once per tick, at the END, mc.play_out is moved into net.outbox in generation order, so for each connection net.outbox is:
-- what the connection layer wrote while processing input (login ... join burst), then what the game produced this tick.  net.drain_outbox() then
-- returns it in order.  For a connection with compression enabled the moved frames are re-framed (net.reframe); frames at or above the threshold would
-- need deflate, which SQL does not have, so such a connection is closed (documented limit; the dev server runs with compression off).
--
-- Order of work in one tick (each step set-based except where noted):
--   1 net.process()                 consume net.inbox: handshake, status, login, configuration, the join (per connection, in order), protocol-level play packets
--   2 feed the game's queue         play packets the connection layer forwards, plus keep-alive answers and teleport confirmations, in arrival order
--   3 mc.tick()                     game clock, movement, input, chat and commands, visibility (add/remove entities), keep-alive, periodic set_time
--   4 mc.apply_block_actions        player_action / use_item_on
--   5 mc.broadcast_block_events     block_update / level_event / chunk re-sends / block_changed_ack
--   6 net.stream_chunks             chunk updates for players that changed chunk
--   7 kicks and leavers             mc.kick -> close; closing connections with a player row -> mc.on_leave (messages to the others)
--   8 drain mc.play_out into net.outbox
-- Steps 3-7 each run in their own sub-transaction: an error in one is logged (mc.error_log) and the tick continues, so one bad packet cannot stop
-- every player's tick.

create table if not exists mc.error_log (id bigint generated always as identity primary key, at timestamptz not null default now(), tick bigint, step text, message text);
create table if not exists mc.server_tick_log (
    tick bigint primary key, at timestamptz not null default now(), frames_in int, players int, frames_out int,
    ms_total float8, ms_process float8, ms_game float8, ms_blocks float8, ms_chunks float8, ms_drain float8);

-- Re-frame concatenated uncompressed frames for a connection with compression threshold >= 0 (frames below it get a data length of 0).
create or replace function net.reframe(p_threshold int, p_frames bytea) returns bytea language plpgsql stable as $$
declare pos int := 0; ln int; nx int; payload bytea; out bytea := '\x';
begin
    while pos < length(p_frames) loop
        select val, nxt into ln, nx from proto.varint_read(p_frames, pos);
        payload := substring(p_frames from nx + 1 for ln);
        if ln < p_threshold then out := out || proto.varint(ln + 1) || '\x00'::bytea || payload;
        else perform net.deflate_frame(0, payload);       -- raises: no deflate in SQL
        end if;
        pos := nx + ln;
    end loop;
    return out;
end $$;

create or replace function mc.server_tick() returns bigint language plpgsql as $$
declare
    cur bigint; t0 timestamptz := clock_timestamp(); t1 timestamptz; t2 timestamptz; t3 timestamptz; t4 timestamptz; t5 timestamptz;
    n_in int; n_players int; n_out int; r record; stepname text;
begin
    -- 1
    n_in := net.process();
    t1 := clock_timestamp();
    -- 2: what the game owns, in arrival order (seq is shared by net.inbox, net.batch and net.play_inbox)
    insert into mc.play_in (conn_id, packet_id, body)
    select conn_id::int, packet_id, body from (
        select conn_id, seq, packet_id, body from net.play_inbox
        union all
        select b.conn_id, b.seq, net.pid(b.payload), substring(b.payload from net.pid_len(b.payload) + 1)
        from net.batch b join net.conn c on c.conn_id = b.conn_id and c.state = 'play' and not c.closing
        where net.pid(b.payload) = any (array[mc.sid('keep_alive'), mc.sid('accept_teleportation')])) u
    order by seq;
    truncate net.play_inbox;
    -- 3
    begin
        cur := mc.tick();
    exception when others then
        select game_time into cur from mc.game_state;
        truncate mc.play_in; truncate mc.play_in_work;       -- the packet that failed must not fail every tick again
        insert into mc.error_log (tick, step, message) values (cur, 'mc.tick', sqlerrm);
        raise warning 'mc.server_tick: mc.tick failed: %', sqlerrm;
    end;
    t2 := clock_timestamp();
    -- 4, 5
    begin perform mc.apply_block_actions(cur); exception when others then
        insert into mc.error_log (tick, step, message) values (cur, 'apply_block_actions', sqlerrm); raise warning 'apply_block_actions failed: %', sqlerrm; end;
    begin perform mc.broadcast_block_events(); exception when others then
        insert into mc.error_log (tick, step, message) values (cur, 'broadcast_block_events', sqlerrm); raise warning 'broadcast_block_events failed: %', sqlerrm; end;
    t3 := clock_timestamp();
    -- 6
    begin perform net.stream_chunks(); exception when others then
        insert into mc.error_log (tick, step, message) values (cur, 'stream_chunks', sqlerrm); raise warning 'stream_chunks failed: %', sqlerrm; end;
    t4 := clock_timestamp();
    -- 7
    begin
        update net.conn set closing = true where conn_id in (select conn_id from mc.kick);
        truncate mc.kick;
        for r in select c.conn_id from net.conn c where c.closing and exists (select 1 from mc.player p where p.conn_id = c.conn_id) loop
            perform mc.on_leave(r.conn_id::int);
        end loop;
    exception when others then
        insert into mc.error_log (tick, step, message) values (cur, 'kicks', sqlerrm); raise warning 'kicks failed: %', sqlerrm;
    end;
    -- 8
    create temp table if not exists _drain (seq bigint, conn_id int, data bytea, comp int) on commit delete rows;
    delete from _drain;
    with o as (delete from mc.play_out returning seq, conn_id, data)
    insert into _drain select o.seq, o.conn_id, o.data, c.compression from o join net.conn c on c.conn_id = o.conn_id and c.state = 'play';
    select count(*)::int into n_out from _drain;
    insert into net.outbox (conn_id, data) select conn_id, data from _drain where comp < 0 order by seq;
    for r in select conn_id, comp, string_agg(data, ''::bytea order by seq) as data from _drain where comp >= 0 group by conn_id, comp loop
        begin
            insert into net.outbox (conn_id, data) values (r.conn_id, net.reframe(r.comp, r.data));
        exception when others then
            insert into mc.error_log (tick, step, message) values (cur, 'reframe', sqlerrm);
            perform net.close(r.conn_id);
        end;
    end loop;
    t5 := clock_timestamp();
    select count(*)::int into n_players from mc.player where conn_id is not null;
    insert into mc.server_tick_log (tick, frames_in, players, frames_out, ms_total, ms_process, ms_game, ms_blocks, ms_chunks, ms_drain)
    values (cur, n_in, n_players, n_out, extract(epoch from t5 - t0) * 1000, extract(epoch from t1 - t0) * 1000, extract(epoch from t2 - t1) * 1000,
            extract(epoch from t3 - t2) * 1000, extract(epoch from t4 - t3) * 1000, extract(epoch from t5 - t4) * 1000)
    on conflict (tick) do nothing;
    delete from mc.server_tick_log where tick < cur - 6000;
    return cur;
end $$;
