-- sql/800: an idle server does (almost) nothing.  What is proved here:
--   1. mc.tick_quiet() is true on an empty server and flips to false for every single thing the full tick would have to look at;
--   2. the quiet tick leaves the same state as the full tick (`set dbcraft.quiet_tick = 'off'` runs every phase as before): clock, queues, relation housekeeping, log rows;
--   3. mc.moves_idle() is only true when mc.apply_player_moves changes nothing (random states: packets of every movement kind, players moved by other code);
--   4. whole ticks with players, with the switch on and off, from the same state and the same input, send the same bytes to every connection and leave the same state:
--      the default tick and the batched tick, client_tick_end for everybody, positions, chat, keep-alive answers, two position packets in one tick (a kick), a malformed packet.
--   5. the small gateway-facing pieces: net.gateway_pending, net.gateway_ctl, net.apply_auth_results, net.drain_outbox on an empty server.
create or replace function t.idle_reset() returns void language plpgsql as $$
begin
  truncate net.conn_ctl, net.conn, net.inbox, net.outbox, net.play_inbox, net.batch, mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor,
           mc.block_event, mc.chunk_wanted, net.auth_result, net.join_parked, mc.server_tick_log, mc.tick_log, mc.error_log;
  delete from mc.player;
  update net.join_gate_state set active = false;
  update mc.game_state set game_time = 0, day_time = 0;
  perform set_config('dbcraft.quiet_tick', 'on', false);
end $$;

------------------------------------------------------------------------------------------------ 1. the predicate
select t.idle_reset();
select t.is_true('an empty server is quiet', mc.tick_quiet());
select t.is_true('...and the hook is false by default', not mc.tick_extra_pending());
create or replace function t.quiet_flip(p_name text, p_stmt text, p_clean text) returns void language plpgsql as $$
begin
  execute p_stmt;
  if mc.tick_quiet() then raise exception 'FAIL % : still quiet', p_name; end if;
  execute p_clean;
  if not mc.tick_quiet() then raise exception 'FAIL % : not quiet after clean-up', p_name; end if;
  raise notice 'ok   % makes the tick not quiet', p_name;
end $$;
select t.quiet_flip('a connection', 'insert into net.conn (conn_id, state, compression) values (1, ''status'', -1)', 'delete from net.conn');
select t.quiet_flip('a frame in the inbox', 'insert into net.inbox (conn_id, payload) values (1, ''\x00'')', 'truncate net.inbox');
select t.quiet_flip('an online player row', 'insert into mc.player (uuid, name, conn_id, entity_id) values (md5(''a'')::uuid, ''a'', 5, 5)', 'delete from mc.player');
select t.quiet_flip('a claimed packet', 'insert into mc.play_in (conn_id, packet_id, body) values (1, 1, ''\x'')', 'truncate mc.play_in');
select t.quiet_flip('a verdict', 'insert into net.auth_result (conn_id, ok) values (1, true)', 'truncate net.auth_result');
select t.quiet_flip('a parked login', 'insert into net.join_parked (seq, conn_id, payload, parked_ms) values (1, 1, ''\x00'', 0)', 'truncate net.join_parked');
select t.quiet_flip('an active login gate', 'update net.join_gate_state set active = true', 'update net.join_gate_state set active = false');
select t.quiet_flip('a kick', 'insert into mc.kick (conn_id, reason_nbt) values (1, ''\x00'')', 'truncate mc.kick');
select t.quiet_flip('a queued frame', 'insert into mc.play_out (conn_id, data) values (1, ''\x00'')', 'truncate mc.play_out');
select t.quiet_flip('a wanted chunk', 'insert into mc.chunk_wanted (conn_id, dimension, cx, cz, dist) values (1, ''minecraft:overworld'', 0, 0, 0)', 'truncate mc.chunk_wanted');
select t.quiet_flip('a block event', 'insert into mc.block_event (dimension, x, y, z, old_state, new_state) values (''minecraft:overworld'', 0, 0, 0, ''a'', ''b'')', 'truncate mc.block_event');
select t.quiet_flip('a pending acknowledgement', 'insert into mc.pending_ack (conn_id, sequence) values (1, 1)', 'truncate mc.pending_ack');
select t.quiet_flip('a block actor', 'insert into mc.block_actor (dimension, x, y, z, conn_id) values (''minecraft:overworld'', 0, 0, 0, 1)', 'truncate mc.block_actor');
select t.quiet_flip('a frame in the connection layer''s batch', 'insert into net.batch (conn_id, seq, payload) values (1, 1, ''\x00'')', 'truncate net.batch');
select t.quiet_flip('entities switched on', 'update mc.server_property set value = ''inline'' where key = ''dbcraft.entity-mode''', 'update mc.server_property set value = ''off'' where key = ''dbcraft.entity-mode''');
create or replace function mc.tick_extra_pending() returns boolean language sql immutable as $$ select true $$;
select t.is_true('the hook makes the tick not quiet', not mc.tick_quiet());
create or replace function mc.tick_extra_pending() returns boolean language sql immutable parallel safe as $$ select false $$;
select t.is_true('...and back', mc.tick_quiet());
set dbcraft.quiet_tick = 'off';
select t.is_true('the switch disables the quiet path', not mc.tick_quiet());
select t.is_true('...and moves_idle', not mc.moves_idle());
reset dbcraft.quiet_tick;

------------------------------------------------------------------------------------------------ 2. the quiet tick against the full tick
create or replace function t.idle_state() returns text language sql as $$
  select (select game_time || '/' || day_time from mc.game_state) || '|' || (select count(*) from mc.play_out) || '|' || (select count(*) from net.outbox) || '|' || (select count(*) from mc.play_in_work)
      || '|' || (select count(*) from net.batch) || '|' || (select count(*) from mc.error_log) || '|' || (select count(*) from net.conn) $$;
create or replace function t.idle_run(p_fn text, p_ticks int, p_off boolean) returns text language plpgsql as $$
declare i int; r text;
begin
  perform t.idle_reset();
  perform set_config('dbcraft.quiet_tick', case when p_off then 'off' else 'on' end, false);
  -- leftovers a previous busy tick may have left, and a file with a length (rows inserted and deleted)
  insert into mc.play_in_work (conn_id, packet_id, body) select 1, 1, '\x00' from generate_series(1, 50);
  update mc.game_state set game_time = 7;
  for i in 1 .. p_ticks loop
    execute 'select ' || p_fn;
    perform * from net.drain_outbox();
  end loop;
  r := t.idle_state() || '|' || (select count(*) from mc.server_tick_log);
  perform set_config('dbcraft.quiet_tick', 'on', false);
  return r;
end $$;
select t.eq('default tick, 45 ticks: quiet and full leave the same state', t.idle_run('mc.server_tick()', 45, false), t.idle_run('mc.server_tick()', 45, true));
select t.eq('batched tick, 45 ticks: quiet and full leave the same state', t.idle_run('mc.server_tick_batched()', 45, false), t.idle_run('mc.server_tick_batched()', 45, true));
select t.idle_run('mc.server_tick()', 45, false) as expect_state \gset
select t.eq('...which is: the clock at 52 (day time 45), nothing queued, a log row per tick', :'expect_state'::text, '52/45|0|0|0|0|0|0|45'::text);
select t.is_true('the quiet tick writes no game tick_log row', (select count(*) from mc.tick_log) = 0);
select t.idle_run('mc.server_tick()', 45, true) as full_state \gset
select t.is_true('the full tick does (that is the documented difference)', (select count(*) from mc.tick_log) = 45);
select t.is_true('the once-a-second housekeeping emptied the claimed-packet file in the quiet tick too',
  (select t.idle_run('mc.server_tick()', 20, false)) is not null and pg_relation_size('mc.play_in_work') = 0);
select t.is_true('the log keeps its last 6,001 ticks', (select count(*) from mc.server_tick_log) = 20);
create or replace function t.idle_log_trim() returns boolean language plpgsql as $$
begin
  perform t.idle_reset();
  insert into mc.server_tick_log (tick) select g from generate_series(-100, 6500) g;
  update mc.game_state set game_time = 6499;
  for i in 1 .. 25 loop perform mc.server_tick(); end loop;
  return (select count(*) from mc.server_tick_log) between 6001 and 6021 and (select min(tick) from mc.server_tick_log) >= 6524 - 6000 - 21;
end $$;
select t.is_true('the quiet tick trims the log (once a second)', t.idle_log_trim());

------------------------------------------------------------------------------------------------ 3. moves_idle
create or replace function t.mi_digest() returns text language sql as $$
  select coalesce(md5(string_agg(p::text, '|' order by conn_id)), '') from (select conn_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, sent_yaw, sent_pitch, last_sent_tick,
         vis_dirty, awaiting_teleport, teleport_id, on_ground from mc.player) p $$;
create or replace function t.mi_trial(p_seed int) returns text language plpgsql as $$
declare n int := 4 + p_seed % 5; i_pos int := mc.sid('move_player_pos'); i_rot int := mc.sid('move_player_rot'); i_te int := mc.sid('client_tick_end'); i_tp int := mc.sid('accept_teleportation');
        i_st int := mc.sid('move_player_status_only'); idle boolean; before text; changed boolean; kind int := p_seed % 8; dig text;
begin
  perform t.idle_reset();
  perform setseed(p_seed / 100.0);
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, sent_yaw, sent_pitch, vis_dirty, last_sent_tick, gamemode)
  select md5(g::text)::uuid, 'p' || g, g, g, px, 70, pz, (random() * 90)::real, 0, floor(px / 16)::int, floor(pz / 16)::int, mc.quant(px), mc.quant(70), mc.quant(pz), 0, 0, false, 0, 1
    from (select g, random() * 64 as px, random() * 64 as pz from generate_series(1, n) g) q;
  update mc.player set sent_yaw = yaw;
  -- players moved by other code (a /tp): position, or rotation, or nothing, according to the trial
  if kind in (1, 2) then update mc.player set x = x + 3 where conn_id = 1; end if;
  if kind = 3 then update mc.player set yaw = yaw + 10 where conn_id = 2; end if;
  if kind = 4 then update mc.player set y = y + 0.5 where conn_id = 1; end if;
  -- the input: nothing, client_tick_end only, or one of the movement kinds
  if kind in (0, 1, 3) then insert into mc.play_in_work (conn_id, packet_id, body) select conn_id, i_te, '\x' from mc.player; end if;
  if kind = 5 then insert into mc.play_in_work (conn_id, packet_id, body) select conn_id, i_pos, proto.f64(x) || proto.f64(y) || proto.f64(z) || '\x01' from mc.player where conn_id = 1; end if;
  if kind = 6 then
    insert into mc.play_in_work (conn_id, packet_id, body) values (2, i_rot, proto.f32(5) || proto.f32(1) || '\x00'), (3, i_st, '\x01'), (4, i_tp, '\x07'), (1, i_te, '\x');
  end if;
  idle := mc.moves_idle();
  before := t.mi_digest();
  perform * from mc.apply_player_moves(5);
  dig := t.mi_digest();
  changed := dig <> before or exists (select 1 from mc.play_out) or exists (select 1 from mc.play_in_work where packet_id <> i_te);
  if idle and changed then return 'moves_idle was true but apply_player_moves changed something (kind ' || kind || ')'; end if;
  return case when idle then 'idle' else 'busy' end;
end $$;
select t.eq('moves_idle: trial ' || s || ' is idle exactly when nothing can change', (select r from (select t.mi_trial(s) as r) q), case when s % 8 in (0, 7) then 'idle' else 'busy' end) from generate_series(0, 69) s;
select t.is_true('...both outcomes occurred', (select count(*) filter (where t.mi_trial(s) = 'idle') from generate_series(0, 15) s) = 4);

------------------------------------------------------------------------------------------------ 4. whole ticks, switch on against switch off
create or replace function t.wt_build(p_seed int, p_n int) returns void language plpgsql as $$
begin
  perform t.idle_reset();
  perform setseed(p_seed / 100.0);
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, sent_yaw, sent_pitch, vis_dirty, last_sent_tick, gamemode, keepalive_sent_tick)
  select md5(g::text)::uuid, 'bot' || g, g, g, px, 70, pz, 0, 0, floor(px / 16)::int, floor(pz / 16)::int, mc.quant(px), mc.quant(70), mc.quant(pz), 0, 0, true, 0, 1, 0
    from (select g, random() * 40 as px, random() * 40 as pz from generate_series(1, p_n) g) q;
  insert into net.conn (conn_id, state, name, uuid, compression, entity_id, view_cx, view_cz, gamemode)
  select conn_id, 'play', name, uuid, case when conn_id = 3 then 256 else -1 end, entity_id, chunk_x, chunk_z, gamemode from mc.player;
  perform mc.refresh_visibility();
  truncate mc.play_out;
  update mc.game_state set game_time = 0;
end $$;
-- the input of tick `tk` for connection `c`: a pure function of (seed, tick, connection), so the two runs see the same frames
create or replace function t.wt_input(p_seed int, p_n int, tk int) returns void language plpgsql as $$
declare c int; h int; i_pr int := net.pkt('play', 'serverbound', 'minecraft:move_player_pos_rot'); i_te int := net.pkt('play', 'serverbound', 'minecraft:client_tick_end');
        i_ch int := net.pkt('play', 'serverbound', 'minecraft:chat'); i_ka int := net.pkt('play', 'serverbound', 'minecraft:keep_alive'); i_pos int := net.pkt('play', 'serverbound', 'minecraft:move_player_pos');
        i_tp int := net.pkt('play', 'serverbound', 'minecraft:accept_teleportation');
begin
  for c in 1 .. p_n loop
    h := abs(hashint4(p_seed * 100000 + tk * 100 + c)) % 100;
    if h < 40 then insert into net.inbox (conn_id, payload) values (c, proto.varint(i_te));                                     -- the idle player
    elsif h < 62 then                                                                                                              -- one position and the tick end
      insert into net.inbox (conn_id, payload) values (c, proto.varint(i_pr) || proto.f64(20 + (h % 7) * 0.3) || proto.f64(70) || proto.f64(20 + (h % 5) * 0.2) || proto.f32((h % 30)::real) || proto.f32(0) || '\x01'),
                                                          (c, proto.varint(i_te));
    elsif h < 70 then insert into net.inbox (conn_id, payload) values (c, proto.varint(i_te)), (c, proto.varint(i_te));            -- two tick ends
    end if;
    if h between 78 and 83 then                                                                                                      -- chat (some of them illegal)
      insert into net.inbox (conn_id, payload) values (c, proto.varint(i_te)),
        (c, proto.varint(i_ch) || proto.string(case when h = 83 then 'bad' || chr(7) else 'hello ' || c || ' tick ' || tk end) || proto.i64(1000 + tk) || proto.i64(7) || '\x00' || proto.varint(0) || '\x000000' || '\x00');
    elsif h between 84 and 88 then                                                                                                   -- a keep-alive answer, a teleport confirmation
      insert into net.inbox (conn_id, payload) values (c, proto.varint(i_ka) || proto.i64(5 + h)), (c, proto.varint(i_tp) || '\x01'), (c, proto.varint(i_te));
    elsif h = 89 then                                                                                                                -- two position packets without a tick end between (a kick)
      insert into net.inbox (conn_id, payload) values (c, proto.varint(i_pos) || proto.f64(1) || proto.f64(70) || proto.f64(1) || '\x01'), (c, proto.varint(i_pos) || proto.f64(2) || proto.f64(70) || proto.f64(2) || '\x01');
    elsif h = 90 then                                                                                                                -- a malformed position packet
      insert into net.inbox (conn_id, payload) values (c, proto.varint(i_pos) || '\x0102');
    elsif h >= 96 then                                                                                                               -- two position packets WITH a tick end between them: legal, and the reason the tick end is queued then
      insert into net.inbox (conn_id, payload) values (c, proto.varint(i_pos) || proto.f64(21) || proto.f64(70) || proto.f64(21) || '\x01'), (c, proto.varint(i_te)),
                                                          (c, proto.varint(i_pos) || proto.f64(21.2) || proto.f64(70) || proto.f64(21.1) || '\x01'), (c, proto.varint(i_te));
    elsif h >= 91 then insert into net.inbox (conn_id, payload) values (c, proto.varint(i_te)), (c, proto.varint(i_pr) || proto.f64(30) || proto.f64(70) || proto.f64(30) || proto.f32(1::real) || proto.f32(0) || '\x00'), (c, proto.varint(i_te));
    end if;
  end loop;
end $$;
create or replace function t.wt_digest() returns text language sql as $$
  select md5(coalesce((select string_agg(p::text, '|' order by uuid) from (select uuid, conn_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, sent_yaw, sent_pitch, last_sent_tick, vis_dirty,
                   keepalive_id, keepalive_sent_tick, latency_ms, chat_sent, chat_recv, awaiting_teleport, teleport_id, on_ground from mc.player) p), '')
          || '#' || coalesce((select string_agg(conn_id || '/' || state || '/' || closing || '/' || coalesce(keepalive_id::text, '-') || '/' || teleport_ok, '|' order by conn_id) from net.conn), '')
          || '#' || (select game_time || '/' || day_time from mc.game_state) || '#' || (select count(*) from mc.visible) || '#' || (select count(*) from mc.kick) || '#' || (select count(*) from mc.error_log)) $$;
create or replace function t.wt_run(p_seed int, p_n int, p_ticks int, p_fn text, p_off boolean) returns text language plpgsql as $$
declare tk int; out_digest text := ''; r record;
begin
  perform t.wt_build(p_seed, p_n);
  perform set_config('dbcraft.quiet_tick', case when p_off then 'off' else 'on' end, false);
  for tk in 1 .. p_ticks loop
    perform t.wt_input(p_seed, p_n, tk);
    execute 'select ' || p_fn;
    -- what the gateway would write to each socket this tick (a connection the tick closed is deleted by the drain)
    select out_digest || coalesce(string_agg(conn_id || ':' || close || ':' || md5(data), ',' order by conn_id), '') into out_digest from net.drain_outbox();
    out_digest := out_digest || ';';
  end loop;
  perform set_config('dbcraft.quiet_tick', 'on', false);
  return md5(out_digest) || '/' || t.wt_digest();
end $$;
select t.eq('whole ticks with 8 players, default tick, seed ' || s || ': the switch changes nothing', t.wt_run(s, 8, 40, 'mc.server_tick()', false), t.wt_run(s, 8, 40, 'mc.server_tick()', true)) from generate_series(1, 6) s;
select t.eq('whole ticks with 8 players, batched tick, seed ' || s || ': the switch changes nothing', t.wt_run(s, 8, 40, 'mc.server_tick_batched()', false), t.wt_run(s, 8, 40, 'mc.server_tick_batched()', true)) from generate_series(1, 6) s;
select t.is_true('the scripts do something: positions, chat, kicks (not an empty comparison)',
  (select count(*) from mc.chat_log) > 0 and exists (select 1 from mc.server_tick_log where frames_out > 0) and (select count(*) from mc.error_log) = 0);

------------------------------------------------------------------------------------------------ 5. the gateway-facing pieces
select t.idle_reset();
select t.eq('gateway_pending: nothing to hand over', net.gateway_pending(0), 0);
insert into net.conn (conn_id, state, compression) values (77, 'play', -1);
select t.is_true('gateway_pending: a control row is bit 2', net.gateway_pending(0) = 2);
select t.eq('...and not after the gateway has seen it', net.gateway_pending((select max(ctl_seq) from net.conn_ctl)), 0);
insert into net.outbox (conn_id, data) values (77, '\x01');
select t.is_true('gateway_pending: bytes in the outbox are bit 1', net.gateway_pending((select max(ctl_seq) from net.conn_ctl)) = 1);
select t.eq('net.drain_outbox returns them', (select count(*)::int from net.drain_outbox() where conn_id = 77), 1);
select t.eq('...and then an empty set', (select count(*)::int from net.drain_outbox()), 0);
update net.conn set closing = true where conn_id = 77;
select t.is_true('a closing connection is bit 1', net.gateway_pending((select max(ctl_seq) from net.conn_ctl)) = 1);
create temp table drained_closing as select * from net.drain_outbox();
select t.is_true('...the drain returns it with close = true', (select close from drained_closing where conn_id = 77));
select t.is_true('...and deletes the row', not exists (select 1 from net.conn where conn_id = 77));
select t.eq('gateway_ctl: rows after the cursor', (select count(*)::int from net.gateway_ctl(0)), (select count(*)::int from net.conn c join net.conn_ctl k using (conn_id)));
select t.eq('gateway_ctl: none after the last', (select count(*)::int from net.gateway_ctl((select coalesce(max(ctl_seq), 0) from net.conn_ctl))), 0);
select t.eq('apply_auth_results with no verdict returns 0', net.apply_auth_results(), 0);
select t.idle_reset();
