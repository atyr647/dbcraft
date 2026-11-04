-- The configuration phase, in the order vanilla 26.3 sends it (tests/sql/130_net_config.sql replays a capture and compares bytes):
--   on login_acknowledged:   custom_payload (brand), update_enabled_features, select_known_packs (what we have: minecraft:core)
--   on select_known_packs:   registry_data x32, update_tags (from ref.dp_* rows, cached per known-pack combination), finish_configuration
--   on finish_configuration: the client has confirmed -> state play -> net.play_begin()

create or replace function net.config_begin(p_conn bigint) returns void language plpgsql as $$
declare feats text[] := string_to_array(net.setting('enabled_features'), ',');
        ver text := net.setting('version_name');
begin
    -- brand: a custom payload on the channel minecraft:brand whose data is a string
    perform net.send(p_conn, net.pkt('configuration', 'clientbound', 'minecraft:custom_payload'),
                     proto.string('minecraft:brand') || proto.string(net.setting('brand')));
    perform net.send(p_conn, net.pkt('configuration', 'clientbound', 'minecraft:update_enabled_features'),
                     proto.varint(array_length(feats, 1)) || (select string_agg(proto.string(f), ''::bytea order by o) from unnest(feats) with ordinality t(f, o)));
    -- we offer the core pack of our own version: a client that has it will not need the registry contents
    perform net.send(p_conn, net.pkt('configuration', 'clientbound', 'minecraft:select_known_packs'),
                     proto.varint(1) || proto.string('minecraft') || proto.string('core') || proto.string(ver));
end $$;

-- "namespace:id:version" strings from a list of (namespace, id, version) in a select_known_packs packet.
create or replace function net.read_known_packs(body bytea) returns text[] language plpgsql immutable as $$
declare n int; o int; i int; ns text; id text; ver text; out text[] := '{}';
begin
    select val, nxt into n, o from proto.varint_read(body, 0);
    if n > 64 then raise exception 'too many known packs (%)', n; end if;
    for i in 1 .. n loop
        select val, nxt into ns, o from proto.string_read(body, o);
        select val, nxt into id, o from proto.string_read(body, o);
        select val, nxt into ver, o from proto.string_read(body, o);
        out := out || (ns || ':' || id || ':' || ver);
    end loop;
    return out;
end $$;

-- client_information (config and play): language, view distance, chat visibility, chat colors, skin parts, main hand, text filtering,
-- allow server listing, particle status.
create or replace function net.read_client_information(body bytea) returns jsonb language plpgsql immutable as $$
declare lang text; o int; vd int; chat int; cc boolean; skin int; hand int; filt boolean; listing boolean; part int; x int;
begin
    select val, nxt into lang, o from proto.string_read(body, 0);
    if o is null then perform proto.bad('truncated packet'); end if;       -- (an empty body: the string read found no length)
    perform net.need(body, o + 1);
    vd := proto.i8_read(body, o);
    select val, nxt into chat, o from proto.varint_read(body, o + 1);
    perform net.need(body, o + 3);
    cc := proto.bool_read(body, o); skin := proto.u8_read(body, o + 1);
    select val, nxt into hand, o from proto.varint_read(body, o + 2);
    perform net.need(body, o + 2);
    filt := proto.bool_read(body, o); listing := proto.bool_read(body, o + 1);
    select val into part from proto.varint_read(body, o + 2);
    return jsonb_build_object('language', lang, 'view_distance', vd, 'chat_visibility', chat, 'chat_colors', cc, 'skin_parts', skin,
                              'main_hand', hand, 'text_filtering', filt, 'allow_listing', listing, 'particles', part);
end $$;

create or replace function net.h_config(p_conn bigint, p_name text, body bytea) returns void language plpgsql as $$
declare c net.conn; ch text; o int; br text; known text[];
begin
    select * into c from net.conn where conn_id = p_conn;
    if p_name = 'minecraft:client_information' then
        update net.conn set client_info = net.read_client_information(body) where conn_id = p_conn;
    elsif p_name = 'minecraft:custom_payload' then
        select val, nxt into ch, o from proto.string_read(body, 0);
        if ch = 'minecraft:brand' then
            select val into br from proto.string_read(body, o);
            update net.conn set brand = left(br, 64) where conn_id = p_conn;
        end if;                                                            -- other channels: ignored
    elsif p_name = 'minecraft:select_known_packs' then
        if c.known_packs is not null then raise exception 'unexpected second select_known_packs'; end if;
        known := net.read_known_packs(body);
        update net.conn set known_packs = known where conn_id = p_conn;
        perform net.send_config_data(p_conn, known);
        perform net.send(p_conn, net.pkt('configuration', 'clientbound', 'minecraft:finish_configuration'), '\x');
    elsif p_name = 'minecraft:finish_configuration' then
        if c.known_packs is null then raise exception 'unexpected finish_configuration before select_known_packs'; end if;
        update net.conn set state = 'play', keepalive_id = null where conn_id = p_conn;
        perform net.play_begin(p_conn);
    elsif p_name = 'minecraft:keep_alive' then
        -- the answer to a keep-alive of the configuration state (net.config_keepalive, sql/980); an id that is not the pending one is ignored (a stray answer is not an error)
        if c.keepalive_id is not null and length(body) >= 8 and proto.i64_read(body, 0) = c.keepalive_id then
            update net.conn set keepalive_id = null where conn_id = p_conn;
        end if;
    elsif p_name in ('minecraft:pong', 'minecraft:resource_pack', 'minecraft:cookie_response',
                     'minecraft:custom_click_action', 'minecraft:accept_code_of_conduct') then
        null;                                                              -- nothing is pending on these in this server
    else
        raise exception 'unexpected configuration packet %', p_name;
    end if;
end $$;

create or replace function net.on_disconnect(p_conn bigint) returns void language plpgsql as $$
begin
    perform net.hook_disconnect(p_conn);
    delete from net.conn where conn_id = p_conn;
    delete from net.inbox where conn_id = p_conn;
    delete from net.outbox where conn_id = p_conn;
end $$;
