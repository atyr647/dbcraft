-- Paced login-storm harness.  Everything runs inside the database; each jbp.step(t) call is ONE statement = one transaction = one gateway tick.
-- Unlike tests/bench/join/storm.sql (all five login packets of a connection inserted at once), the simulated clients behave like real ones: each stage is sent only
-- after the server's answer to the previous stage has been seen (one tick of round trip), and a client that receives nothing for 30 s (vanilla's read timeout)
-- gives up.  TIME IS SIMULATED IN MILLISECONDS: a step advances the clock by the tick's real duration but at least 50 ms (a gateway sleeps to the next 50 ms boundary
-- and runs late ticks back to back), clients arrive at their clock times, and the server's join gate reads the same clock (dbcraft.sim_clock_ms).  A tick that
-- takes 460 ms therefore costs 460 ms of simulated time, during which more clients arrive: that is what makes a storm snowball.
-- Needs: tests/bench/integration/bench.sql (ibench: online walkers) and tests/bench/tick/cpu.sql (tickbench.sched: on-CPU time).
--
--   phase 0  not connected yet            phase 1  hello sent, waiting for login_finished      phase 2  waiting for the configuration select_known_packs
--   phase 3  waiting for finish_configuration (config)   phase 4  waiting for the play login packet   phase 5  in play, counting chunks   phase 6  done   phase 9  timed out
create schema if not exists jbp;
create or replace function jbp.byte1(i int) returns bytea language sql immutable as $f$ select set_byte('\x00'::bytea, 0, i) $f$;

drop table if exists jbp.client; drop table if exists jbp.ticks;
create table jbp.client (
    conn_id bigint primary key, name text not null, phase int not null default 0, arrive_ms bigint not null,
    last_rx_ms bigint, hello_ms bigint, login_ms bigint, play_ms bigint, done_ms bigint, chunks int not null default 0, timed_out_ms bigint
);
create table if not exists jbp.todo (conn_id bigint not null, step int not null, payload bytea not null);
create table jbp.ticks (t int primary key, clock_ms bigint, wall_ms float8, cpu_ms float8, parked int, released int, in_play int, waiting int, frames_out int, mb_out numeric);
create table if not exists jbp.cfg (k text primary key, v text not null);

-- frames of a drained buffer (no compression): packet id and frame length
create or replace function jbp.frames(p_data bytea) returns table (pid int, len int) language plpgsql immutable as $$
declare o int := 0; n int := length(p_data); v record;
begin
    while o < n loop
        select * into v from proto.varint_read(p_data, o);
        exit when v.val is null;
        pid := (proto.varint_read(p_data, v.nxt)).val;
        len := v.val;
        return next;
        o := v.nxt + v.val;
    end loop;
end $$;

-- p_online players already in play state (ibench.setup, spread over side x side chunks), p_n joiners arriving evenly over p_arrive_ms milliseconds
drop function if exists jbp.reset(integer, integer, integer, integer, integer, text);
create or replace function jbp.reset(p_online int, p_side int, p_vd int, p_n int, p_arrive_ms int, p_tick text default 'default') returns void language plpgsql as $$
begin
    if p_online > 0 then
        perform ibench.setup(p_online, p_side, p_vd);
    else
        truncate net.conn, net.inbox, net.outbox, net.play_inbox, net.batch, mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor,
                 mc.block_event, mc.tick_log, mc.server_tick_log, mc.error_log;
        delete from mc.player;
        update mc.game_state set game_time = 0;
        update mc.server_property set value = p_vd::text where key = 'view-distance';
    end if;
    truncate jbp.client, jbp.todo, jbp.ticks, net.join_parked;
    update net.join_gate_state set rate = 3, active = false, parked_total = 0, released_total = 0, forced_total = 0, max_queue = 0, last_release = 0;
    delete from jbp.cfg;
    insert into jbp.cfg values ('tick', p_tick), ('expected_chunks', ((2 * (p_vd + 1) + 1) ^ 2)::int::text), ('clock_ms', '0');
    update mc.server_property set value = '5000' where key = 'max-players';
    update mc.server_property set value = 'false' where key = 'white-list';
    update mc.server_property set value = '-1' where key = 'network-compression-threshold';
    update mc.server_property set value = 'inline' where key = 'dbcraft.chunk-generation';
    -- the world around the spawn and around the online players exists and is cached: the storm measures logins, not terrain generation
    perform mc.generate_flat('minecraft:overworld', cx, cz) from generate_series(-6, p_side + 6) cx, generate_series(-6, p_side + 6) cz
      where not exists (select 1 from mc.chunk c where c.dimension = 'minecraft:overworld' and c.cx = cx and c.cz = cz);
    perform mc.chunk_packet('minecraft:overworld', cx, cz) from generate_series(-6, p_side + 6) cx, generate_series(-6, p_side + 6) cz;
    perform setval('mc.entity_id_seq', coalesce((select max(entity_id) from mc.player), 0) + 1, false);
    insert into jbp.client (conn_id, name, arrive_ms)
    select 100000 + i, 'J' || lpad(i::text, 6, '0'), 1500 + ((i - 1)::bigint * p_arrive_ms) / greatest(p_n, 1) from generate_series(1, p_n) i;      -- 1.5 s of ordinary ticks first: the gate needs a baseline
end $$;

-- what the online players (conn ids below 100000) send every tick; the joiners stay still (their walking would turn a join storm into a crowd benchmark)
create or replace function jbp.gen(frac float8) returns void language plpgsql as $$
declare i_pr int := net.pkt('play', 'serverbound', 'minecraft:move_player_pos_rot'); i_te int := net.pkt('play', 'serverbound', 'minecraft:client_tick_end');
begin
  insert into net.inbox (conn_id, payload)
  select conn_id, proto.varint(i_pr) || proto.f64(x + (random() - 0.5) * 0.4) || proto.f64(y) || proto.f64(z + (random() - 0.5) * 0.4) || proto.f32((yaw + 1)::real) || proto.f32(pitch) || '\x01'::bytea
    from mc.player where conn_id is not null and conn_id < 100000 and random() < frac;
  insert into net.inbox (conn_id, payload) select conn_id, proto.varint(i_te) from mc.player where conn_id is not null and conn_id < 100000;
end $$;

create or replace function jbp.step(p_t int, p_walk float8 default 0) returns void language plpgsql as $$
declare
    i_hs int := net.pkt('handshake', 'serverbound', 'minecraft:intention'); i_hello int := net.pkt('login', 'serverbound', 'minecraft:hello');
    i_ack int := net.pkt('login', 'serverbound', 'minecraft:login_acknowledged');
    i_skp int := net.pkt('configuration', 'serverbound', 'minecraft:select_known_packs'); i_sfc int := net.pkt('configuration', 'serverbound', 'minecraft:finish_configuration');
    c_lf int := net.pkt('login', 'clientbound', 'minecraft:login_finished'); c_kp int := net.pkt('configuration', 'clientbound', 'minecraft:select_known_packs');
    c_fc int := net.pkt('configuration', 'clientbound', 'minecraft:finish_configuration'); c_login int := net.pkt('play', 'clientbound', 'minecraft:login');
    c_chunk int := net.pkt('play', 'clientbound', 'minecraft:level_chunk_with_light');
    expected int := (select v::int from jbp.cfg where k = 'expected_chunks');
    batched boolean := coalesce((select v = 'batched' from jbp.cfg where k = 'tick'), false);
    clk bigint := (select v::bigint from jbp.cfg where k = 'clock_ms'); clk_end bigint;
    a bigint[]; b bigint[]; t0 timestamptz; wall float8; cpu float8; r record; f record; cl jbp.client; ph int; ch int; got boolean; n_out int := 0; b_out bigint := 0;
begin
    -- clients that arrive now: connect, handshake and hello back to back (as a real client does)
    perform net.on_connect(conn_id) from jbp.client where phase = 0 and arrive_ms <= clk;
    insert into net.inbox (conn_id, payload)
    select k.conn_id, x.payload
      from jbp.client k, lateral (values
             (1, proto.varint(i_hs) || proto.varint(777) || proto.string('localhost') || proto.i16(25565) || proto.varint(2)),
             (2, proto.varint(i_hello) || proto.string(k.name) || proto.uuid(net.offline_uuid(k.name)))) x(step, payload)
     where k.phase = 0 and k.arrive_ms <= clk
     order by k.conn_id, x.step;
    update jbp.client set phase = 1, hello_ms = clk, last_rx_ms = clk where phase = 0 and arrive_ms <= clk;
    -- the replies decided by what the clients saw last tick
    insert into net.inbox (conn_id, payload) select conn_id, payload from jbp.todo order by conn_id, step;
    delete from jbp.todo;
    if p_walk > 0 then perform jbp.gen(p_walk); end if;

    perform set_config('dbcraft.sim_clock_ms', clk::text, true);          -- the server's join gate reads this clock (transaction-local)
    a := tickbench.sched(); t0 := clock_timestamp();
    if batched then perform mc.server_tick_batched(); else perform mc.server_tick(); end if;
    b := tickbench.sched(); wall := extract(epoch from clock_timestamp() - t0) * 1000; cpu := (b[1] - a[1]) / 1e6;
    clk_end := clk + greatest(50, wall)::bigint;

    -- what the clients see
    for r in select d.conn_id, d.data from net.drain_outbox() d loop
        n_out := n_out + 1; b_out := b_out + length(r.data);
        select * into cl from jbp.client where conn_id = r.conn_id and phase between 1 and 5;
        continue when not found;
        ph := cl.phase; ch := cl.chunks; got := false;
        for f in select * from jbp.frames(r.data) loop
            got := true;
            if ph = 1 and f.pid = c_lf then
                ph := 2; update jbp.client set login_ms = clk_end where conn_id = cl.conn_id;
                insert into jbp.todo values (cl.conn_id, 1, proto.varint(i_ack));
                -- a real client (tools/scoreboard/loadgen.py) announces its view distance right after: without it the server serves the default radius 3 (49 chunks) and the harness never sees the 529 it expects
                insert into jbp.todo values (cl.conn_id, 2, proto.varint(net.pkt('configuration', 'serverbound', 'minecraft:client_information')) || proto.string('en_us')
                    || jbp.byte1(((select value from mc.server_property where key = 'view-distance')::int)) || proto.varint(0) || '\x01'::bytea || '\x7f'::bytea || proto.varint(1) || '\x00'::bytea || '\x01'::bytea || proto.varint(0));
            elsif ph = 2 and f.pid = c_kp then
                ph := 3; insert into jbp.todo values (cl.conn_id, 2, proto.varint(i_skp) || proto.varint(0));
            elsif ph = 3 and f.pid = c_fc then
                ph := 4; insert into jbp.todo values (cl.conn_id, 3, proto.varint(i_sfc));
            elsif ph = 4 and f.pid = c_login then
                ph := 5; update jbp.client set play_ms = clk_end where conn_id = cl.conn_id;
            elsif ph = 5 and f.pid = c_chunk then
                ch := ch + 1;
            end if;
        end loop;
        if ph = 5 and ch >= expected then ph := 6; update jbp.client set done_ms = clk_end where conn_id = cl.conn_id; end if;
        update jbp.client set phase = ph, chunks = ch, last_rx_ms = case when got then clk_end else last_rx_ms end where conn_id = cl.conn_id;
    end loop;
    update jbp.client set phase = 9, timed_out_ms = clk_end where phase between 1 and 5 and clk_end - last_rx_ms > 30000;
    update jbp.cfg set v = clk_end::text where k = 'clock_ms';
    insert into jbp.ticks
    select p_t, clk_end, wall, cpu, (select count(*)::int from net.join_parked), (select last_release from net.join_gate_state), (select count(*)::int from jbp.client where phase >= 5 and phase < 9),
           (select count(*)::int from jbp.client where phase between 1 and 4), n_out, round(b_out / 1048576.0, 2);
end $$;
