-- The dispatcher.  net.process() is called by the tick (and by tests): it consumes net.inbox and fills net.outbox.
--
--   * Play-state packets that the connection layer does not handle itself (movement, chat, digging, ...) are moved set-based into
--     net.play_inbox for mc.tick(); no per-row work.
--   * Everything else (handshake, status, login, configuration, and the protocol-level play packets) is handled per connection in order,
--     because each packet can change the state that decides how the next one is read.  These are rare events, not the hot path.
--   * A packet that fails (malformed, unexpected) closes that connection only, inside its own subtransaction.

-- Serverbound play packets handled here rather than forwarded.
create or replace function net.handled_play_ids() returns int[] language sql stable as $$
    select coalesce(array_agg(protocol_id), '{}') from ref.packet
    where state = 'play' and direction = 'serverbound'
      and name in ('minecraft:keep_alive', 'minecraft:pong', 'minecraft:accept_teleportation', 'minecraft:chunk_batch_received',
                   'minecraft:player_loaded', 'minecraft:client_information', 'minecraft:custom_payload', 'minecraft:configuration_acknowledged') $$;

create or replace function net.fail(p_conn bigint, p_msg text) returns void language plpgsql as $$
declare st text;
begin
    select state into st from net.conn where conn_id = p_conn;
    if not found then return; end if;
    raise notice 'net: closing connection % in state %: %', p_conn, st, p_msg;
    if p_msg like 'unexpected%' or st in ('handshake', 'status', 'login_ack') then
        perform net.close(p_conn);                                       -- silent close, as adacraft's corpus requires
    elsif st = 'login' then
        perform net.login_disconnect(p_conn, nbt.json_translate('disconnect.genericReason', array['Internal Exception: ' || p_msg]));
    elsif st in ('configuration', 'play') then
        perform net.send(p_conn, net.pkt(st, 'clientbound', 'minecraft:disconnect'),
                         nbt.text_translate('disconnect.genericReason', array['Internal Exception: ' || p_msg]));
        perform net.close(p_conn);
    else
        perform net.close(p_conn);
    end if;
end $$;

create or replace function net.handle(p_conn bigint, p_payload bytea) returns void language plpgsql as $$
declare c net.conn; pid int; off int; nm text; body bytea; st text;
begin
    select * into c from net.conn where conn_id = p_conn;
    if not found or c.closing then return; end if;
    select val, nxt into pid, off from proto.varint_read(p_payload, 0);
    if pid is null then raise exception 'truncated packet id'; end if;
    body := substring(p_payload from off + 1);
    st := case c.state when 'login_ack' then 'login' else c.state end;
    nm := net.pkt_name(st, 'serverbound', pid);
    if nm is null then raise exception 'unexpected packet id % in state %', pid, c.state; end if;
    case c.state
        when 'handshake' then
            if nm <> 'minecraft:intention' then raise exception 'unexpected packet %', nm; end if;
            perform net.h_handshake(p_conn, body);
        when 'status'        then perform net.h_status(p_conn, nm, body);
        when 'login'         then perform net.h_login(p_conn, nm, body);
        when 'login_ack'     then perform net.h_login_ack(p_conn, nm, body);
        when 'configuration' then perform net.h_config(p_conn, nm, body);
        when 'play'          then perform net.h_play(p_conn, pid, nm, body);
        else raise exception 'unexpected state %', c.state;
    end case;
end $$;

create or replace function net.process() returns int language plpgsql as $$
declare r record; n int; handled int[] := net.handled_play_ids();
begin
    perform net.join_gate();                          -- sql/790: admission gate for logins (parks/releases hello packets; a no-op when nothing is queued or the budget is off)
    truncate net.batch;
    with t as (delete from net.inbox returning conn_id, seq, payload) insert into net.batch select conn_id, seq, payload from t;
    get diagnostics n = row_count;
    if n = 0 then return 0; end if;
    update net.conn c set last_activity = now() from (select distinct conn_id from net.batch) b where c.conn_id = b.conn_id;
    -- hot path: forward unhandled play packets in bulk
    with fwd as (
        delete from net.batch b using net.conn c, ref.packet pk
        where c.conn_id = b.conn_id and c.state = 'play' and not c.closing
          and pk.state = 'play' and pk.direction = 'serverbound' and pk.protocol_id = net.pid(b.payload)    -- the id exists; unknown ids take the slow path and get the sender disconnected
          and not (net.pid(b.payload) = any (handled))
        returning b.conn_id, b.seq, b.payload)
    insert into net.play_inbox (conn_id, seq, packet_id, body)
    select conn_id, seq, net.pid(payload), substring(payload from net.pid_len(payload) + 1) from fwd;
    -- everything else, in order, one connection failure at a time
    for r in select conn_id, payload from net.batch order by conn_id, seq loop
        begin
            perform net.handle(r.conn_id, r.payload);
        exception when others then
            perform net.fail(r.conn_id, sqlerrm);
        end;
    end loop;
    return n;
end $$;
