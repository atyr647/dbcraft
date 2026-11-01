-- Online mode, the SQL half (docs/GATEWAY.md has the sequence).  What SQL cannot do (RSA, AES, HTTPS) stays in the gateway; everything else is here.
--
--   hello (online_mode = true)  -> net.start_encryption: store a 4-byte challenge, mark the connection await_key, send encryption_request
--   [gateway: intercepts the key response, decrypts, switches to AES-128-CFB8, asks Mojang, writes net.auth_result]
--   net.apply_auth_results()    -> the offline path's second half with the VERIFIED profile: login check, compression, login_finished with the profile properties
-- 26.3 layouts (javap, not memory): encryption_request = serverId string (empty), publicKey byte[], challenge byte[], shouldAuthenticate bool;
-- key = keybytes byte[], encryptedChallenge byte[]; login_finished = uuid, name, properties (VarInt count, each name, value, nullable signature), session id uuid.

------------------------------------------------------------------------------------------------ skins in the tab list
-- Same bytes as sql/310 except the profile properties: the add-player entry carries the player's properties (none for offline players: VarInt 0).
create or replace function mc.pie_add(p_uuid uuid, p_name text, gamemode int, listed boolean default true, latency int default 0, list_order int default 0, hat boolean default false)
returns bytea language sql stable parallel safe as $$
  select proto.uuid(p_uuid) || proto.string(p_name) || mc.profile_props(p_uuid)    -- name, profile properties (textures)
      || proto.bool(false)                                                          -- chat session: none
      || proto.varint(gamemode) || proto.bool(listed) || proto.varint(latency)
      || proto.bool(false)                                                          -- display name: none
      || proto.varint(list_order) || proto.bool(hat) $$;

-- The cached constant head of a tab entry (sql/464) now includes the properties: they must be stored BEFORE uuid and name are assigned to the connection.
create or replace function net.conn_tab_sync() returns trigger language plpgsql as $$
begin
    if tg_op = 'DELETE' then
        delete from net.conn_tab where conn_id = old.conn_id;
    elsif new.uuid is null or new.name is null then
        delete from net.conn_tab where conn_id = new.conn_id;
    else
        insert into net.conn_tab (conn_id, head) values (new.conn_id, proto.uuid(new.uuid) || proto.string(new.name) || mc.profile_props(new.uuid) || '\x00'::bytea)
        on conflict (conn_id) do update set head = excluded.head;
    end if;
    return null;
end $$;
insert into net.conn_tab (conn_id, head)
select conn_id, proto.uuid(uuid) || proto.string(name) || mc.profile_props(uuid) || '\x00'::bytea from net.conn where uuid is not null and name is not null
on conflict (conn_id) do update set head = excluded.head;

------------------------------------------------------------------------------------------------ encryption request
create or replace function net.start_encryption(p_conn bigint, p_name text) returns void language plpgsql as $$
declare pub bytea; tok bytea;
begin
    select public_der into pub from net.server_key where id = 1;
    if pub is null then
        perform net.login_disconnect(p_conn, nbt.json_translate('disconnect.genericReason',
            array['Internal Exception: java.lang.IllegalStateException: The server has no encryption key (is the gateway running?)']));
        return;
    end if;
    tok := substring(decode(replace(gen_random_uuid()::text, '-', ''), 'hex') from 1 for 4);
    update net.conn set name = p_name, verify_token = tok, await_key = true where conn_id = p_conn;
    perform net.send(p_conn, net.pkt('login', 'clientbound', 'minecraft:hello'),
                     proto.string('') || proto.varint(octet_length(pub)) || pub || proto.varint(octet_length(tok)) || tok || proto.bool(true));
end $$;

------------------------------------------------------------------------------------------------ hello
-- COPY of net.h_login (sql/400_integration.sql) with ONE addition, marked "online": the branch that used to raise 'online mode is not implemented'.
-- A second hello while the key exchange is running is a protocol error (the connection is closed by the dispatcher).
create or replace function net.h_login(p_conn bigint, p_name text, body bytea) returns void language plpgsql as $$
declare nm text; o int; u uuid; sid uuid := gen_random_uuid(); thr int := net.setting('compression_threshold')::int; chk record; busy boolean;
begin
    if p_name = 'minecraft:hello' then
        select val, nxt into nm, o from proto.string_read(body, 0);
        perform net.need(body, o + 16);
        if char_length(nm) not between 1 and 16 or not net.valid_name(nm) then
            perform net.login_disconnect(p_conn, nbt.json_translate('disconnect.genericReason',
                array['Internal Exception: java.lang.IllegalStateException: Invalid characters in username']));
            return;
        end if;
        if net.setting('online_mode') = 'true' then                      -- online
            select (await_key or auth_pending) into busy from net.conn where conn_id = p_conn;
            if busy then raise exception 'unexpected hello packet'; end if;
            perform net.start_encryption(p_conn, nm);
            return;
        end if;
        u := net.offline_uuid(nm);
        select * into chk from net.hook_login_check(p_conn, nm, u);
        if not chk.allowed then perform net.login_disconnect(p_conn, chk.disconnect_json); return; end if;
        if thr >= 0 then
            perform net.send(p_conn, net.pkt('login', 'clientbound', 'minecraft:login_compression'), proto.varint(thr));
            update net.conn set compression = thr where conn_id = p_conn;
        end if;
        update net.conn set state = 'login_ack', name = nm, uuid = u, session_id = sid where conn_id = p_conn;
        perform net.send(p_conn, net.pkt('login', 'clientbound', 'minecraft:login_finished'),
                         proto.uuid(u) || proto.string(nm) || proto.varint(0) || proto.uuid(sid));
    else
        raise exception 'unexpected login packet %', p_name;
    end if;
end $$;

------------------------------------------------------------------------------------------------ verdicts
-- Applied once per tick, before the game tick.  One failing connection never affects the others (its own subtransaction, then closed).
create or replace function net.apply_auth_results() returns int language plpgsql as $$
declare r record; n int := 0; thr int := net.setting('compression_threshold')::int; chk record; sid uuid; c net.conn; prop jsonb; i int := 0;
begin
    for r in with q as (delete from net.auth_result returning *) select * from q order by seq loop
        select * into c from net.conn where conn_id = r.conn_id and auth_pending and not closing;
        if not found then continue; end if;
        begin
            update net.conn set auth_pending = false where conn_id = r.conn_id;
            if not r.ok then
                perform net.login_disconnect(r.conn_id, nbt.json_translate(
                    case r.reason when 'unavailable' then 'multiplayer.disconnect.authservers_down' else 'multiplayer.disconnect.unverified_username' end));
            elsif r.name is null or r.uuid is null or char_length(r.name) not between 1 and 16 or not net.valid_name(r.name) then
                perform net.login_disconnect(r.conn_id, nbt.json_translate('multiplayer.disconnect.unverified_username'));
            else
                select * into chk from net.hook_login_check(r.conn_id, r.name, r.uuid);          -- ban, whitelist, banned IP, server full: after authentication, as in vanilla
                if not chk.allowed then
                    perform net.login_disconnect(r.conn_id, chk.disconnect_json);
                else
                    sid := gen_random_uuid();
                    delete from mc.player_property where uuid = r.uuid;                         -- properties BEFORE uuid/name reach net.conn (the tab-entry head cache)
                    i := 0;
                    for prop in select * from jsonb_array_elements(r.properties) loop
                        exit when i >= 16;                                                       -- the codec's limit
                        insert into mc.player_property (uuid, ord, name, value, signature) values (r.uuid, i, prop->>'name', prop->>'value', nullif(prop->>'signature', ''));
                        i := i + 1;
                    end loop;
                    if thr >= 0 then
                        perform net.send(r.conn_id, net.pkt('login', 'clientbound', 'minecraft:login_compression'), proto.varint(thr));
                        update net.conn set compression = thr where conn_id = r.conn_id;
                    end if;
                    update net.conn set state = 'login_ack', name = r.name, uuid = r.uuid, session_id = sid, encrypted = true where conn_id = r.conn_id;
                    perform net.send(r.conn_id, net.pkt('login', 'clientbound', 'minecraft:login_finished'),
                                     proto.uuid(r.uuid) || proto.string(r.name) || mc.profile_props(r.uuid) || proto.uuid(sid));
                end if;
            end if;
            n := n + 1;
        exception when others then
            insert into mc.error_log (tick, step, message) values (0, 'auth_result', sqlerrm);
            update net.conn set closing = true where conn_id = r.conn_id;
        end;
    end loop;
    return n;
end $$;
