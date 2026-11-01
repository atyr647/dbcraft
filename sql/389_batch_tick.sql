-- Batched pipeline, part 4: the entry point.  mc.server_tick_batched() is mc.server_tick() (sql/420) + mc.tick() (sql/360) in one function, with the same order of
-- work and the same bytes, and with each component switchable (mc.batch_flags(), sql/380).  Contract for the gateway is unchanged:
--   gateway -> net.inbox;  select mc.server_tick_batched();  net.drain_outbox() -> gateway.
-- Order of work: 1 ingest (cold per-connection loop for the rare frames) / 2 claim game input / 3 clock, movement, misc input, chat, visibility, keep-alive, time /
--                4 block actions / 5 block events / 6 chunk streaming / 7 kicks and leavers / 8 drain.
create or replace function mc.server_tick_batched() returns bigint language plpgsql as $$
declare
    fl text := mc.batch_flags();
    f_in boolean := fl like '%,all,%' or fl like '%,in,%';     f_mv boolean := fl like '%,all,%' or fl like '%,mv,%';
    f_vis boolean := fl like '%,all,%' or fl like '%,vis,%';   f_ch boolean := fl like '%,all,%' or fl like '%,ch,%';
    f_out boolean := fl like '%,all,%' or fl like '%,out,%';   f_skip boolean := fl like '%,all,%' or fl like '%,skip,%';
    cur bigint; t0 timestamptz := clock_timestamp(); t1 timestamptz; t2 timestamptz; t3 timestamptz; t4 timestamptz; t5 timestamptz;
    g0 timestamptz; g1 timestamptz; g2 timestamptz; g3 timestamptz; g4 timestamptz; g5 timestamptz; g6 timestamptz;
    n_in int; n_in_game int := 0; n_players int; n_out int; r record; mv record; ch record; vis record; ka record;
    i_ka int; i_held int; i_cs int; i_chat int; i_cmd int; i_cmds int; i_act int; i_use int;
    n_misc boolean := true; n_chat boolean := true; n_blocks boolean := true;
begin
    -- 1, 2: ingest
    if f_in then
        n_in := mc.ingest_batched();
    else
        n_in := net.process();
        insert into mc.play_in (conn_id, packet_id, body)
        select conn_id::int, packet_id, body from (
            select conn_id, seq, packet_id, body from net.play_inbox
            union all
            select b.conn_id, b.seq, net.pid(b.payload), substring(b.payload from net.pid_len(b.payload) + 1)
            from net.batch b join net.conn c on c.conn_id = b.conn_id and c.state = 'play' and not c.closing
            where net.pid(b.payload) = any (array[mc.sid('keep_alive'), mc.sid('accept_teleportation')])) u
        order by seq;
        truncate net.play_inbox;
    end if;
    t1 := clock_timestamp();
    -- 3: the game's tick (mc.tick() inlined, in its order of work)
    begin
        update mc.game_state set game_time = game_time + 1, day_time = day_time + 1 returning game_time into cur;
        if f_in then
            if exists (select 1 from mc.play_in) then
                with c as (delete from mc.play_in returning seq, conn_id, packet_id, body) insert into mc.play_in_work (seq, conn_id, packet_id, body) select seq, conn_id, packet_id, body from c;
            end if;
        else
            truncate mc.play_in_work;
            with c as (delete from mc.play_in returning seq, conn_id, packet_id, body) insert into mc.play_in_work (seq, conn_id, packet_id, body) select seq, conn_id, packet_id, body from c;
        end if;
        select count(*)::int into n_players from mc.player where conn_id is not null;
        g0 := clock_timestamp();
        if f_mv then select * into mv from mc.moves_batched(cur); else select * into mv from mc.apply_player_moves(cur); end if;
        g1 := clock_timestamp();
        -- which of the less frequent input kinds are present this tick (one query), so the others cost nothing
        i_ka := mc.sid('keep_alive'); i_held := mc.sid('set_carried_item'); i_cs := mc.sid('set_creative_mode_slot');
        i_chat := mc.sid('chat'); i_cmd := mc.sid('chat_command'); i_cmds := mc.sid('chat_command_signed'); i_act := mc.sid('player_action'); i_use := mc.sid('use_item_on');
        select coalesce(bool_or(packet_id in (i_ka, i_held, i_cs)), false), coalesce(bool_or(packet_id in (i_chat, i_cmd, i_cmds)), false),
               coalesce(bool_or(packet_id in (i_act, i_use)), false)
          into n_misc, n_chat, n_blocks from mc.play_in_work;
        if n_misc or not f_skip then perform mc.apply_misc_input(cur); end if;
        g2 := clock_timestamp();
        if n_chat or not f_skip then select * into ch from mc.apply_chat(cur); end if;
        g3 := clock_timestamp();
        if f_vis then select * into vis from mc.visibility_batched(); else select * into vis from mc.refresh_visibility(); end if;
        g4 := clock_timestamp();
        select * into ka from mc.keepalive_due(cur);
        g5 := clock_timestamp();
        if cur % 20 = 0 then
            with p as materialized (select mc.pkt_set_time(cur) as d) insert into mc.play_out (conn_id, data) select conn_id, p.d from mc.player, p where conn_id is not null;
        end if;
        g6 := clock_timestamp();
        select count(*)::int into n_out from mc.play_out;
        insert into mc.tick_log values (cur, now(), n_players, n_in, n_out,
           extract(epoch from g6 - g0) * 1000, extract(epoch from g1 - g0) * 1000, extract(epoch from g2 - g1) * 1000, extract(epoch from g3 - g2) * 1000,
           extract(epoch from g4 - g3) * 1000, extract(epoch from g5 - g4) * 1000, extract(epoch from g6 - g5) * 1000, mv.moved, mv.corrected, mv.kicked)
        on conflict (tick) do nothing;
        delete from mc.tick_log where tick < cur - 6000;
    exception when others then
        select game_time into cur from mc.game_state;
        delete from mc.play_in; delete from mc.play_in_work;
        insert into mc.error_log (tick, step, message) values (cur, 'mc.tick', sqlerrm);
        raise warning 'mc.server_tick_batched: tick failed: %', sqlerrm;
        n_blocks := true;
    end;
    t2 := clock_timestamp();
    -- 4, 5: block actions and their broadcast
    begin
        if n_blocks or not f_skip then perform mc.apply_block_actions(cur); end if;
        if not f_skip or exists (select 1 from mc.block_event) or exists (select 1 from mc.pending_ack) or exists (select 1 from mc.block_actor) then
            perform mc.broadcast_block_events();
        end if;
    exception when others then
        insert into mc.error_log (tick, step, message) values (cur, 'block events', sqlerrm); raise warning 'block events failed: %', sqlerrm;
    end;
    if f_in then delete from mc.play_in_work; end if;           -- packets nobody handled (the baseline truncates the work queue at the start of the next tick)
    t3 := clock_timestamp();
    -- 6: chunk streaming
    begin
        if f_ch then perform net.stream_chunks_batched(); else perform net.stream_chunks(); end if;
    exception when others then
        insert into mc.error_log (tick, step, message) values (cur, 'stream_chunks', sqlerrm); raise warning 'stream_chunks failed: %', sqlerrm;
    end;
    t4 := clock_timestamp();
    -- 7: kicks and leavers
    begin
        if not f_skip or exists (select 1 from mc.kick) or exists (select 1 from net.conn where closing) then
            update net.conn set closing = true where conn_id in (select conn_id from mc.kick);
            if f_skip then delete from mc.kick; else truncate mc.kick; end if;
            for r in select c.conn_id from net.conn c where c.closing and exists (select 1 from mc.player p where p.conn_id = c.conn_id) loop
                perform mc.on_leave(r.conn_id::int);
            end loop;
        end if;
    exception when others then
        insert into mc.error_log (tick, step, message) values (cur, 'kicks', sqlerrm); raise warning 'kicks failed: %', sqlerrm;
    end;
    -- 8: drain the game's queue into the connection layer's
    if f_out then
        n_out := mc.drain_batched(cur);
    else
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
    end if;
    t5 := clock_timestamp();
    insert into mc.server_tick_log (tick, frames_in, players, frames_out, ms_total, ms_process, ms_game, ms_blocks, ms_chunks, ms_drain)
    values (cur, n_in, n_players, n_out, extract(epoch from t5 - t0) * 1000, extract(epoch from t1 - t0) * 1000, extract(epoch from t2 - t1) * 1000,
            extract(epoch from t3 - t2) * 1000, extract(epoch from t4 - t3) * 1000, extract(epoch from t5 - t4) * 1000)
    on conflict (tick) do nothing;
    delete from mc.server_tick_log where tick < cur - 6000;
    return cur;
end $$;
