-- Handshake, status and login (offline mode).  Texts and layouts match what vanilla 26.3 sends (tests/sql/120_net_login.sql compares bytes).

-- Raise when the buffer is shorter than a field needs (truncated packet).
create or replace function net.need(body bytea, upto int) returns void language sql as $$
    select case when upto > length(body) then proto.bad('truncated packet')::int end $$;

-- A login_disconnect (login state carries the reason as JSON text in a string).
create or replace function net.login_disconnect(p_conn bigint, p_json text) returns void language sql as $$
    select net.send(p_conn, net.pkt('login', 'clientbound', 'minecraft:login_disconnect'), proto.string(p_json));
    select net.close(p_conn) $$;

------------------------------------------------------------------------------------------------ handshake
create or replace function net.h_handshake(p_conn bigint, body bytea) returns void language plpgsql as $$
declare v_ver int; v_o int; v_addr text; v_o2 int; v_port int; v_intent int;
begin
    select val, nxt into v_ver, v_o from proto.varint_read(body, 0);
    select val, nxt into v_addr, v_o2 from proto.string_read(body, v_o);
    perform net.need(body, v_o2 + 2);
    v_port := proto.u16_read(body, v_o2);
    select val into v_intent from proto.varint_read(body, v_o2 + 2);
    if v_intent is null then raise exception 'truncated handshake'; end if;
    if v_intent = 1 then
        update net.conn set state = 'status', proto_version = v_ver, address = v_addr, port = v_port where conn_id = p_conn;
    elsif v_intent = 2 then
        update net.conn set state = 'login', proto_version = v_ver, address = v_addr, port = v_port where conn_id = p_conn;
        if v_ver <> net.setting('protocol_version')::int then
            -- vanilla refuses an incompatible client straight away (observed with protocol 776 and 778)
            perform net.login_disconnect(p_conn, nbt.json_translate('multiplayer.disconnect.incompatible', array[net.setting('version_name')]));
        end if;
    else
        raise exception 'unexpected handshake intent %', v_intent;       -- intent 3 (transfer) is not supported: silent close
    end if;
end $$;

------------------------------------------------------------------------------------------------ status
-- Compact JSON in vanilla's key order: description, players, version (no favicon).
create or replace function net.status_json() returns text language sql stable as $$
    select '{"description":' || to_json(net.setting('motd'))::text
        || ',"players":{"max":' || net.setting('max_players')
        || ',"online":' || (select count(*) from net.conn where state = 'play')
        || '},"version":{"name":' || to_json(net.setting('version_name'))::text
        || ',"protocol":' || net.setting('protocol_version') || '}}' $$;

create or replace function net.h_status(p_conn bigint, p_name text, body bytea) returns void language plpgsql as $$
begin
    if p_name = 'minecraft:status_request' then
        perform net.send(p_conn, net.pkt('status', 'clientbound', 'minecraft:status_response'), proto.string(net.status_json()));
    elsif p_name = 'minecraft:ping_request' then
        perform net.need(body, 8);
        perform net.send(p_conn, net.pkt('status', 'clientbound', 'minecraft:pong_response'), substring(body from 1 for 8));
        perform net.close(p_conn);                                      -- vanilla closes after the pong
    else
        raise exception 'unexpected status packet %', p_name;
    end if;
end $$;

------------------------------------------------------------------------------------------------ login
-- Online-mode hook: the gateway holds the RSA key, so the exchange is: SQL sends encryption_request (public key from the gateway),
-- the gateway decrypts the reply, enables AES, checks Mojang's session server and then calls net.login_authenticated().
-- Not implemented yet (docs/NET.md); offline mode is complete.
create or replace function net.h_login(p_conn bigint, p_name text, body bytea) returns void language plpgsql as $$
declare nm text; o int; u uuid; sid uuid := gen_random_uuid(); thr int := net.setting('compression_threshold')::int;
begin
    if p_name = 'minecraft:hello' then
        select val, nxt into nm, o from proto.string_read(body, 0);
        perform net.need(body, o + 16);
        if char_length(nm) not between 1 and 16 or not net.valid_name(nm) then
            perform net.login_disconnect(p_conn, nbt.json_translate('disconnect.genericReason',
                array['Internal Exception: java.lang.IllegalStateException: Invalid characters in username']));
            return;
        end if;
        if net.setting('online_mode') = 'true' then
            raise exception 'online mode is not implemented in the SQL layer yet';
        end if;
        u := net.offline_uuid(nm);                                      -- the uuid the client sent is ignored, as in vanilla offline mode
        if thr >= 0 then
            perform net.send(p_conn, net.pkt('login', 'clientbound', 'minecraft:login_compression'), proto.varint(thr));
            update net.conn set compression = thr where conn_id = p_conn;
        end if;
        update net.conn set state = 'login_ack', name = nm, uuid = u, session_id = sid where conn_id = p_conn;
        -- GameProfile (uuid, name, 0 properties) followed by the session id (new in 26.x: random per login)
        perform net.send(p_conn, net.pkt('login', 'clientbound', 'minecraft:login_finished'),
                         proto.uuid(u) || proto.string(nm) || proto.varint(0) || proto.uuid(sid));
    else
        raise exception 'unexpected login packet %', p_name;
    end if;
end $$;

create or replace function net.h_login_ack(p_conn bigint, p_name text, body bytea) returns void language plpgsql as $$
begin
    if p_name = 'minecraft:login_acknowledged' then
        update net.conn set state = 'configuration' where conn_id = p_conn;
        perform net.config_begin(p_conn);
    else
        raise exception 'unexpected login packet % after login_finished', p_name;
    end if;
end $$;
