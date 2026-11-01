-- Game module, part 7: chat intake, the time packet, and mc.tick().
-- Contract with the connection layer (see docs/GAME.md):  insert decoded play-state packets into mc.play_in_work (conn_id, packet_id, body) in arrival order,
-- call `select mc.tick()` once per 50 ms, then send every row of mc.play_out (ordered by seq) to its connection and delete them; close the
-- connections listed in mc.kick (after flushing their play_out rows).  jit stays off for the tick (docs/EVALUATION.md).

-- set_time: game time + the list of clock updates (id, total ticks, partial tick, rate).  Periodic updates carry no clocks (verified, every 20 ticks);
-- /time set sends one clock entry (layout verified against the real server's 23-byte packet).
create or replace function mc.pkt_set_time(game_time bigint, clock_ids int[] default '{}', clock_ticks bigint[] default '{}') returns bytea language sql stable parallel safe as $$
  select mc.cb('set_time', proto.i64(game_time) || proto.varint(coalesce(array_length(clock_ids, 1), 0))
       || coalesce((select string_agg(proto.varint(c) || proto.varlong(clock_ticks[i]) || proto.f32(0) || proto.f32(1), '\x'::bytea order by i)
                      from unnest(clock_ids) with ordinality u(c, i)), '\x'::bytea)) $$;

------------------------------------------------------------------------------------------------ chat intake
-- serverbound chat = String(256) | Instant (long ms) | salt long | Optional<signature 256 bytes> | lastSeen (VarInt offset, BitSet(20) = 3 bytes, checksum byte).
-- Offline mode: signatures are not checked.  The real server then relays an UNSIGNED player_chat (signature absent, logged "[Not Secure]"), which is
-- what we build (verified).  Characters below 0x20, 0x7f and the section sign are illegal (vanilla kicks).
create or replace function mc.apply_chat(cur_tick bigint) returns table(messages int, commands int) language plpgsql as $$
declare i_chat int := mc.sid('chat'); i_cmd int := mc.sid('chat_command'); i_cmds int := mc.sid('chat_command_signed');
        r record; s record; ts bigint; salt bigint; idx int; ctype int := mc.chat_type_id('minecraft:chat');
begin
  messages := 0; commands := 0;
  for r in select m.seq, m.packet_id, m.conn_id, m.body, p.uuid, p.name from mc.play_in_work m join mc.player p on p.conn_id = m.conn_id
            where m.packet_id in (i_chat, i_cmd, i_cmds) order by m.seq loop
    select * into s from proto.string_safe(r.body, 0);
    if s.val is null or length(s.val) > 256 or s.val ~ E'[\\x01-\\x1f\\x7f\\u00a7]' then
      perform mc.kick(r.conn_id, 'multiplayer.disconnect.illegal_characters'); continue;
    end if;
    continue when s.val = '';
    if r.packet_id = i_chat then
      continue when length(r.body) < s.nxt + 16;
      ts := proto.i64_read(r.body, s.nxt); salt := proto.i64_read(r.body, s.nxt + 8);
      update mc.player set chat_sent = chat_sent + 1 where uuid = r.uuid returning chat_sent - 1 into idx;
      insert into mc.chat_log (kind, sender, sender_name, message) values ('chat', r.uuid, r.name, s.val);
      with up as (update mc.player set chat_recv = chat_recv + 1 where conn_id is not null returning conn_id, entity_id, chat_recv - 1 as gidx)
      insert into mc.play_out (conn_id, data)
        select conn_id, mc.pkt_player_chat(gidx, r.uuid, idx, s.val, ts, salt, ctype, mc.tc_player(r.uuid, r.name)) from up order by entity_id;
      messages := messages + 1;
    else
      perform mc.run_command(r.conn_id, s.val); commands := commands + 1;
    end if;
  end loop;
  delete from mc.play_in_work where packet_id in (i_chat, i_cmd, i_cmds);
  return next;
end $$;

------------------------------------------------------------------------------------------------ the tick
create table if not exists mc.tick_log (
    tick bigint primary key, at timestamptz not null default now(), players int, in_rows int, out_rows int,
    ms_total float8, ms_moves float8, ms_misc float8, ms_chat float8, ms_visibility float8, ms_keepalive float8, ms_time float8,
    movers int, corrections int, kicks int);

-- Order of work per tick (each step set-based): advance the clocks; apply movement; apply keep-alive / held-slot / creative-slot input; chat and commands;
-- refresh who sees whom; keep-alives; broadcast the game time once a second.  Returns the tick number.
create or replace function mc.tick() returns bigint language plpgsql as $$
declare cur bigint; t0 timestamptz := clock_timestamp(); t1 timestamptz; t2 timestamptz; t3 timestamptz; t4 timestamptz; t5 timestamptz; t6 timestamptz;
        mv record; ch record; vis record; ka record; n_in int; n_players int; n_out int; gt bigint;
begin
  update mc.game_state set game_time = game_time + 1, day_time = day_time + 1 returning game_time into cur;
  -- claim this tick's input atomically; anything inserted from now on waits for the next tick
  truncate mc.play_in_work;
  with c as (delete from mc.play_in returning seq, conn_id, packet_id, body) insert into mc.play_in_work (seq, conn_id, packet_id, body) select seq, conn_id, packet_id, body from c;
  get diagnostics n_in = row_count;
  select count(*)::int into n_players from mc.player where conn_id is not null;
  select * into mv from mc.apply_player_moves(cur);                t1 := clock_timestamp();
  perform mc.apply_misc_input(cur);                                t2 := clock_timestamp();
  select * into ch from mc.apply_chat(cur);                        t3 := clock_timestamp();
  select * into vis from mc.refresh_visibility();                  t4 := clock_timestamp();
  select * into ka from mc.keepalive_due(cur);                     t5 := clock_timestamp();
  if cur % 20 = 0 then
    -- build the packet once, not once per player
    with p as materialized (select mc.pkt_set_time(cur) as d) insert into mc.play_out (conn_id, data) select conn_id, p.d from mc.player, p where conn_id is not null;
  end if;
  t6 := clock_timestamp();
  select count(*)::int into n_out from mc.play_out;
  insert into mc.tick_log values (cur, now(), n_players, n_in, n_out,
     extract(epoch from t6 - t0) * 1000, extract(epoch from t1 - t0) * 1000, extract(epoch from t2 - t1) * 1000, extract(epoch from t3 - t2) * 1000,
     extract(epoch from t4 - t3) * 1000, extract(epoch from t5 - t4) * 1000, extract(epoch from t6 - t5) * 1000, mv.moved, mv.corrected, mv.kicked);
  delete from mc.tick_log where tick < cur - 6000;       -- keep the last 5 minutes
  return cur;
end $$;
