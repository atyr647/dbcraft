-- Tick performance, part 1: fewer hops between queues.  See docs/PERF-TICK.md for the measurements behind every change.
-- Everything here REPLACES earlier definitions (create or replace) and keeps their contracts; the SQL suite is the guard.
--
--   net.process_fast()   net.inbox -> in ONE statement: hot play packets go straight into the game's work queue (mc.play_in_work); the answers the game also
--                        needs (keep-alive, teleport confirmation) go there AND stay for the connection layer; everything else goes to net.batch for the
--                        ordered per-connection handlers.  Replaces the hops inbox -> batch -> net.play_inbox -> mc.play_in -> mc.play_in_work (5 copies of every move
--                        packet) used by mc.server_tick.  net.process() is unchanged (its tests read net.play_inbox).
--   mc.tick_core()       the body of mc.tick() without the claim of mc.play_in; mc.tick() = claim + tick_core().
--   mc.server_tick()     uses both, and drains mc.play_out into net.outbox with one aggregate per connection (one row per connection instead of one per packet).

-- row type used to carry the frames of compressing connections through the drain (see mc.server_tick); created once
do $$ begin
    if not exists (select 1 from pg_type where typname = 'drain_row' and typnamespace = 'mc'::regnamespace) then
        create type mc.drain_row as (conn_id int, comp int, data bytea);
    end if;
end $$;

create or replace function net.process_fast() returns int language plpgsql as $$
declare r record; n int; handled int[] := net.handled_play_ids();
        known int[] := (select coalesce(array_agg(protocol_id), '{}') from ref.packet where state = 'play' and direction = 'serverbound');
        i_ka int := mc.sid('keep_alive'); i_tp int := mc.sid('accept_teleportation');
        both_ids int[] := array[i_ka, i_tp];
        ans_b bytea[] := array[set_byte('\x00'::bytea, 0, i_ka), set_byte('\x00'::bytea, 0, i_tp)];       -- first byte of their packets (both ids are below 128: one-byte VarInts)
begin
    delete from net.batch;
    -- Keep-alive answers and teleport confirmations (every connection sends one every 15 s, all within a few ticks of each other) go to the game AND are handled by the
    -- connection layer.  The per-packet handler (net.handle: a connection lookup, a packet-name lookup, a re-planned VarInt reader, net.h_play) cost 0.3 ms each:
    -- 500 answers in one tick made a 330 ms tick.  The well-formed ones are applied here in one UPDATE with the same effect as net.h_play (bulk); a malformed
    -- one (short keep-alive, multi-byte or missing teleport id) still goes to net.batch and fails exactly as before.  The bulk statement is only used in a tick whose
    -- inbox holds such answers (checked first, for 50 us): it is 1.3 ms dearer than the plain one, which handles every other tick.
    if exists (select 1 from net.inbox where substring(payload from 1 for 1) = any (ans_b)) then
        with t as (delete from net.inbox returning conn_id, seq, payload),
             c as (select t.conn_id, t.seq, t.payload, net.pid(t.payload) as pid, (n.state = 'play' and not n.closing) as live
                     from t left join net.conn n on n.conn_id = t.conn_id),
             k as (select c.*, (c.live and c.pid = any (known)) as known_play,
                          case when c.pid in (i_ka, i_tp) then substring(c.payload from net.pid_len(c.payload) + 1) end as body2
                     from c),
             -- a connection is handled in bulk only when each of its packets that the connection layer would see is such an answer: a connection with any other protocol-level
             -- packet in the same tick keeps the ordered per-packet path (a failing packet closes the connection and the packets after it are ignored)
             g1 as (select k.*, (k.known_play and not (k.pid = any (handled))) as game_only,
                           (k.known_play and ((k.pid = i_ka and length(k.body2) >= 8) or (k.pid = i_tp and length(k.body2) >= 1 and get_byte(k.body2, 0) < 128))) as answer_ok
                      from k),
             slow as (select distinct g1.conn_id from g1 where not g1.game_only and not g1.answer_ok and g1.conn_id in (select a.conn_id from g1 a where a.answer_ok)),     -- (usually empty)
             g as (select g1.*, (g1.answer_ok and g1.conn_id not in (select conn_id from slow)) as bulk_ok from g1),
             to_game as (
                 insert into mc.play_in_work (seq, conn_id, packet_id, body)
                 select seq, conn_id, pid, substring(payload from net.pid_len(payload) + 1)
                   from g where known_play and (not (pid = any (handled)) or pid = any (both_ids))
                 returning 1),
             to_batch as (
                 insert into net.batch (conn_id, seq, payload)
                 select conn_id, seq, payload from g where not game_only and not bulk_ok
                 returning 1),
             ev as (
                 select b.conn_id,
                        coalesce(bool_or(case when b.pid = i_ka then proto.i64_read(b.body2, 0) = n.keepalive_id end), false) as ka_hit,       -- CASE: no guarantee that AND stops early,
                        coalesce(bool_or(case when b.pid = i_tp then get_byte(b.body2, 0) = n.teleport_id end), false) as tp_hit               -- and the other kind's body may be too short
                   from g b join net.conn n on n.conn_id = b.conn_id where b.bulk_ok group by b.conn_id),
             bulk as (
                 update net.conn c set keepalive_id = case when ev.ka_hit then null else c.keepalive_id end,
                                       latency_ms = case when ev.ka_hit then greatest(0, (extract(epoch from now() - c.keepalive_sent) * 1000)::int) else c.latency_ms end,
                                       teleport_ok = c.teleport_ok or ev.tp_hit
                   from ev where c.conn_id = ev.conn_id and (ev.ka_hit or (ev.tp_hit and not c.teleport_ok))
                 returning 1)
        select (select count(*) from t) into n;
    else
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
    end if;
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

-- mc.tick() split: the claim of the gateway-facing queue (mc.play_in) stays in mc.tick(); everything after it moves to tick_core(), which works on whatever is in
-- mc.play_in_work.  tick_core() does not count its output rows unless `set mc.count_out = 'on'` (counting a queue of wide rows cost 1.2 ms per tick for a log column).
create or replace function mc.tick_core() returns bigint language plpgsql as $$
declare cur bigint; t0 timestamptz := clock_timestamp(); t1 timestamptz; t2 timestamptz; t3 timestamptz; t4 timestamptz; t5 timestamptz; t6 timestamptz;
        mv record; ch record; vis record; ka record; n_in int; n_players int; n_out int;
begin
  update mc.game_state set game_time = game_time + 1, day_time = day_time + 1 returning game_time into cur;
  select count(*)::int into n_in from mc.play_in_work;
  select count(*)::int into n_players from mc.player where conn_id is not null;
  select * into mv from mc.apply_player_moves(cur);                t1 := clock_timestamp();
  perform mc.apply_misc_input(cur);                                t2 := clock_timestamp();
  select * into ch from mc.apply_chat(cur);                        t3 := clock_timestamp();
  select * into vis from mc.refresh_visibility();                  t4 := clock_timestamp();
  select * into ka from mc.keepalive_due(cur);                     t5 := clock_timestamp();
  if cur % 20 = 0 then
    with p as materialized (select mc.pkt_set_time(cur) as d) insert into mc.play_out (conn_id, data) select conn_id, p.d from mc.player, p where conn_id is not null;
  end if;
  t6 := clock_timestamp();
  if current_setting('mc.count_out', true) = 'on' then select count(*)::int into n_out from mc.play_out; end if;
  insert into mc.tick_log values (cur, now(), n_players, n_in, n_out,
     extract(epoch from t6 - t0) * 1000, extract(epoch from t1 - t0) * 1000, extract(epoch from t2 - t1) * 1000, extract(epoch from t3 - t2) * 1000,
     extract(epoch from t4 - t3) * 1000, extract(epoch from t5 - t4) * 1000, extract(epoch from t6 - t5) * 1000, mv.moved, mv.corrected, mv.kicked);
  delete from mc.tick_log where tick < cur - 6000;       -- keep the last 5 minutes
  return cur;
end $$;

create or replace function mc.tick() returns bigint language plpgsql as $$
begin
  delete from mc.play_in_work;
  -- claim this tick's input atomically; anything inserted from now on waits for the next tick
  with c as (delete from mc.play_in returning seq, conn_id, packet_id, body) insert into mc.play_in_work (seq, conn_id, packet_id, body) select seq, conn_id, packet_id, body from c;
  return mc.tick_core();
end $$;

create or replace function mc.server_tick() returns bigint language plpgsql as $$
declare
    cur bigint; t0 timestamptz := clock_timestamp(); t1 timestamptz; t2 timestamptz; t3 timestamptz; t4 timestamptz; t5 timestamptz;
    n_in int; n_players int; n_out int; r record; framed_rows mc.drain_row[];
begin
    -- housekeeping, once a second: the queues only the tick uses are emptied with TRUNCATE (sql/435 says why; the others are emptied with DELETE every tick)
    -- (a queue that was never written since its last truncate has a zero-length file: nothing to empty, and truncating it anyway would create new files for nothing;
    -- an idle server therefore creates no relation file at all)
    if (select game_time from mc.game_state) % 20 = 19 then
        if pg_relation_size('mc.play_in_work') > 0 then truncate mc.play_in_work; end if;
        if pg_relation_size('net.batch') > 0 then truncate net.batch; end if;
    end if;
    -- 1, 2: consume net.inbox; the game's packets land in its work queue directly
    delete from mc.play_in_work;
    n_in := net.process_fast();
    -- a writer other than the connection layer (a test, a custom gateway) may still use the claim queue: append whatever it left
    with c as (delete from mc.play_in returning seq, conn_id, packet_id, body) insert into mc.play_in_work (seq, conn_id, packet_id, body) select seq, conn_id, packet_id, body from c;
    t1 := clock_timestamp();
    -- 3
    begin
        cur := mc.tick_core();
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
        delete from mc.kick;
        for r in select c.conn_id from net.conn c where c.closing and exists (select 1 from mc.player p where p.conn_id = c.conn_id) loop
            perform mc.on_leave(r.conn_id::int);
        end loop;
    exception when others then
        insert into mc.error_log (tick, step, message) values (cur, 'kicks', sqlerrm); raise warning 'kicks failed: %', sqlerrm;
    end;
    -- 8: mc.play_out -> net.outbox, row for row in generation order; net.drain_outbox() concatenates per connection when the gateway reads (concatenating here
    -- as well cost 24 ms instead of 9 ms per tick at 2,000 players: the same bytes were aggregated twice).  Connections without compression (the common case) are
    -- written straight to net.outbox by the same statement; the frames of connections with compression come back in an array (no scratch table: a temp table
    -- emptied with DELETE is never vacuumed and grows for as long as the session lives) and go through net.reframe, as before.
    with o as (delete from mc.play_out returning seq, conn_id, data),
         j as (select o.seq, o.conn_id, o.data, c.compression as comp from o join net.conn c on c.conn_id = o.conn_id and c.state = 'play'),
         plain as (insert into net.outbox (conn_id, data)
                   select conn_id, data from j where comp < 0 order by seq returning 1)
    select count(*)::int, coalesce(array_agg(row(j.conn_id, j.comp, j.data)::mc.drain_row order by j.seq) filter (where j.comp >= 0), '{}')
      into n_out, framed_rows from j;
    for r in select d.conn_id, d.comp, string_agg(d.data, ''::bytea order by d.ord) as data
               from unnest(framed_rows) with ordinality as d(conn_id, comp, data, ord) group by d.conn_id, d.comp loop
        begin
            insert into net.outbox (conn_id, data) values (r.conn_id, net.reframe(r.comp, r.data));
        exception when others then
            insert into mc.error_log (tick, step, message) values (cur, 'reframe', sqlerrm);
            perform net.close(r.conn_id);
        end;
    end loop;
    if cur % 20 = 0 and pg_relation_size('mc.play_out') > 0 then truncate mc.play_out; end if;          -- empty after the drain above; see the housekeeping note at the top
    t5 := clock_timestamp();
    select count(*)::int into n_players from mc.player where conn_id is not null;
    insert into mc.server_tick_log (tick, frames_in, players, frames_out, ms_total, ms_process, ms_game, ms_blocks, ms_chunks, ms_drain)
    values (cur, n_in, n_players, n_out, extract(epoch from t5 - t0) * 1000, extract(epoch from t1 - t0) * 1000, extract(epoch from t2 - t1) * 1000,
            extract(epoch from t3 - t2) * 1000, extract(epoch from t4 - t3) * 1000, extract(epoch from t5 - t4) * 1000)
    on conflict (tick) do nothing;
    delete from mc.server_tick_log where tick < cur - 6000;
    return cur;
end $$;

