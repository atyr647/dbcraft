-- Idle cost, part 1: a server with nothing to do does (almost) nothing.  See docs/PERF-IDLE.md for the measurements behind every line.
--
-- What an idle tick used to cost (PL/pgSQL gateway or Rust, 0 players): 123 statements per tick, about 1.9-2.5 ms in the tick plus 1.3 ms of the gateway's own statements.
-- What it costs now: one predicate (mc.tick_quiet), the clock, one log row.  With players that send nothing but client_tick_end, the phases that have nothing to do are skipped
-- too (mc.moves_idle, packet-kind flags in mc.tick_core and mc.server_tick_batched; the in-place edits are listed at the end of this header).
--
--   mc.tick_quiet()         true when the full tick would send nothing and change nothing but the clock: nobody is connected (net.conn and the players' conn_id are empty), every queue
--                           the tick reads is empty (inbox, auth results, claim queue, parked logins, kicks, play_out, wanted chunks, block events, acknowledgements, block actors,
--                           the connection layer's batch), the login gate is idle, entities are off (or inline with no entity row: the entity tick of sql/550 would be empty), and the hook mc.tick_extra_pending() says no.
--   mc.tick_quiet_step()    the whole tick in that case: game_time and day_time + 1, leftover claimed packets deleted, the once-a-second queue housekeeping, one mc.server_tick_log row.
--                           (No mc.tick_log row: that table holds the phase timings of the game's tick, and a quiet tick has no phases.)
--   mc.moves_idle()         true when mc.apply_player_moves / mc.moves_batched would do nothing: no movement-class packet in the work queue (position, rotation, status, teleport
--                           confirmation) and no online player whose stored position or rotation differs from what the viewers were last told (players moved by other code, /tp).
--                           client_tick_end alone changes nothing (it only separates two position packets of one tick).
--   mc.tick_extra_pending() HOOK, default false (constant-folded by the planner: free).  Another module that adds per-tick WORLD work (work that must happen with nobody online:
--                           fire, weather, scheduled functions ...) redefines it to return true when that work is due, so the quiet path is not taken.  Per-player work needs no hook:
--                           a quiet tick has no player.
--   net.handled_play_ids_c(), net.known_play_ids_c()   the two id arrays of the inbox classifier as plan-time constants (like mc.sid, sql/433: restart the gateway after reloading ref.packet).
--
-- Switch: `set dbcraft.quiet_tick = 'off'` (session, role or database) disables tick_quiet() and moves_idle(): the previous behaviour exactly (used by tests/sql/800 to compare).
--
-- In-place edits elsewhere (functions whose LAST definition lives in the edited file; no new override entries):
--   sql/430_tick_perf.sql  mc.server_tick (quiet guard), mc.tick_core (packet-kind flags, moves_idle), net.process_fast (constant id arrays)
--   sql/389_batch_tick.sql mc.server_tick_batched (quiet guard, moves_idle); sql/381_batch_ingest_vis.sql mc.ingest_batched (constant id arrays)
--   sql/340_game_input.sql mc.keepalive_due (returns at once when nothing is due)
--   sql/600_gateway.sql    net.gateway_ctl (PL/pgSQL: cached plan, one probe when nothing changed); sql/601_online_login.sql net.apply_auth_results (no verdict: return)
--   sql/780_queue_trim.sql net.drain_outbox (an empty outbox and no closing connection: nothing to do; the size check of the queues once a second then)
--   sql/430_chunk_queue.sql mc.run_generator (one EXISTS per poll, backs off when idle; same call syntax); sql/360_game_tick.sql mc.apply_chat (calls mc.chat_broadcast, sql/802)

create or replace function mc.tick_extra_pending() returns boolean language sql immutable parallel safe as $$ select false $$;

create or replace function net.handled_play_ids_c() returns int[] language plpgsql immutable parallel safe as $$
begin return net.handled_play_ids(); end $$;

create or replace function net.known_play_ids_c() returns int[] language plpgsql immutable parallel safe as $$
begin return (select coalesce(array_agg(protocol_id), '{}') from ref.packet where state = 'play' and direction = 'serverbound'); end $$;

-- The predicate is 17 probes of (mostly empty) queue tables: 0.13 ms of an idle tick that is otherwise 0.15 ms (docs/PERF-IDLE2.md).  A quiet tick therefore also records, in two session settings,
-- when nothing at all has changed since its probes: every one of those tables can only change by a transaction that has a transaction id, and a snapshot's xmax is
-- (the newest completed id) + 1.  The tick takes its own id M first (it writes the clock anyway) and then a snapshot; if that snapshot's xmax is M and its xmin is M too, then no
-- transaction with an id below M is running, and if the next tick's snapshot has xmax M + 1 then nothing with an id has completed since (a transaction with a higher id raises xmax when it commits or
-- aborts; one that has not completed is invisible anyway).  The mark `dbcraft.quiet_mark` = M + 1 is only written in that case, and the next tick, seeing xmax = mark, skips the probes.
-- Not applied when this transaction already has an id (it may have written to a probed table itself: tests and admin scripts that write and then tick in one transaction), when the
-- hook says no, or with the switch off.  An aborted transaction restores the old mark (a mark that is too old can only make a probe run).  Differences from the probes: none -- tests/sql/970.
--   dbcraft.quiet_xid = the id of the transaction of the last quiet tick: net.gateway_pending uses it (the outbox and the control rows are empty when nobody is connected and the outbox probe said so).
create or replace function mc.tick_quiet() returns boolean language plpgsql volatile as $$
declare m bigint; mx bigint; sn pg_snapshot; q boolean; fresh boolean;
begin
    if current_setting('dbcraft.quiet_tick', true) = 'off' then return false; end if;
    fresh := pg_current_xact_id_if_assigned() is null;
    m := pg_current_xact_id()::text::bigint;
    sn := pg_current_snapshot();
    mx := pg_snapshot_xmax(sn)::text::bigint;
    if fresh and current_setting('dbcraft.quiet_mark', true) = mx::text then
        q := true;
    else
        q := not exists (select 1 from net.conn)
         and not exists (select 1 from net.inbox)
         and not exists (select 1 from mc.player where conn_id is not null)
         and not exists (select 1 from mc.play_in)
         and not exists (select 1 from net.auth_result)
         and not exists (select 1 from net.join_parked)
         and not coalesce((select active from net.join_gate_state), false)
         and not exists (select 1 from mc.kick)
         and not exists (select 1 from mc.play_out)
         and not exists (select 1 from mc.chunk_wanted)
         and not exists (select 1 from mc.block_event)
         and not exists (select 1 from mc.pending_ack)
         and not exists (select 1 from mc.block_actor)
         and not exists (select 1 from net.batch)
         and not exists (select 1 from net.play_inbox)
         and not exists (select 1 from net.outbox)
         and not exists (select 1 from mc.chunk_request)
         and (mc.entity_mode() = 'off' or (mc.entity_mode() = 'inline' and not exists (select 1 from mc.entity)));     -- (inline with no entity and nobody connected: the entity tick is empty, sql/550)
    end if;
    if q and not mc.tick_extra_pending() then
        perform set_config('dbcraft.quiet_mark', case when fresh and mx = m and pg_snapshot_xmin(sn) = pg_snapshot_xmax(sn) then (m + 1)::text else '' end, false);
        perform set_config('dbcraft.quiet_xid', m::text, false);
        return true;
    end if;
    perform set_config('dbcraft.quiet_mark', '', false);
    return false;
end $$;

-- p_truncate: the default tick (mc.server_tick) empties its queues with TRUNCATE once a second when they were written; the batched tick only ever DELETEs
-- The log row is written once a second (the tick whose game_time is a multiple of 20), not every tick: a row costs 0.09 ms, more than the whole rest of an idle tick, and a quiet tick
-- has no phases to report.  ms_total is the time of the clock update and the leftover check (what every quiet tick costs: the housekeeping of this tick and the insert itself are not in it), as before.  (docs/PERF-IDLE2.md)
create or replace function mc.tick_quiet_step(p_truncate boolean) returns bigint language plpgsql volatile as $$
declare cur bigint; t0 timestamptz := clock_timestamp(); t1 timestamptz;
begin
    update mc.game_state set game_time = game_time + 1, day_time = day_time + 1 returning game_time into cur;
    if exists (select 1 from mc.play_in_work) then delete from mc.play_in_work; end if;               -- packets nobody handled in the previous tick (the full tick deletes them first thing)
    t1 := clock_timestamp();
    if cur % 20 = 0 then
        -- the full tick runs this at the start of the tick whose game_time is 19 mod 20 (play_in_work, net.batch) and at the end of the tick that makes it 0 mod 20 (play_out)
        if p_truncate then
            if pg_relation_size('mc.play_in_work') > 0 then truncate mc.play_in_work; end if;
            if pg_relation_size('net.batch') > 0 then truncate net.batch; end if;
            if pg_relation_size('mc.play_out') > 0 and mc.entity_mode() <> 'split' then truncate mc.play_out; end if;
        end if;
        delete from mc.server_tick_log where tick < cur - 6000;
        insert into mc.server_tick_log (tick, frames_in, players, frames_out, ms_total, ms_process, ms_game, ms_blocks, ms_chunks, ms_drain)
        values (cur, 0, 0, 0, extract(epoch from t1 - t0) * 1000, 0, 0, 0, 0, 0)
        on conflict (tick) do nothing;
    end if;
    return cur;
end $$;

create or replace function mc.moves_idle() returns boolean language plpgsql volatile as $$
declare i_pos int := mc.sid('move_player_pos'); i_pr int := mc.sid('move_player_pos_rot'); i_rot int := mc.sid('move_player_rot');
        i_st int := mc.sid('move_player_status_only'); i_tp int := mc.sid('accept_teleportation');
begin
    if current_setting('dbcraft.quiet_tick', true) = 'off' then return false; end if;
    -- the conditions are the ones of the `mv` set of mc.apply_player_moves / mc.moves_batched (their WHERE clause without the update-interval phase: conservative)
    return not exists (select 1 from mc.play_in_work where packet_id in (i_pos, i_pr, i_rot, i_st, i_tp))
       and (mc.vis_on()           -- (sql/907: with the vanilla tracker the broadcast of positions is mc.vis_move's, which keeps its own state; the classic step has nothing to send)
            or not exists (select 1 from mc.player p
                            where p.conn_id is not null
                              and (mc.quant(p.x) <> p.sent_qx or mc.quant(p.y) <> p.sent_qy or mc.quant(p.z) <> p.sent_qz or p.yaw <> p.sent_yaw or p.pitch <> p.sent_pitch)));
end $$;
