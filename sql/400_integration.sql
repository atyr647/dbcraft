-- Integration, part 1: the connection layer (net, sql/1xx) wired to the game (mc, sql/3xx) and the world (mc, sql/2xx).
-- Everything here is `create or replace` over functions the other modules own, or new; the decisions are written up in docs/ARCHITECTURE.md.
--
--   settings        mc.server_property is authoritative; a trigger copies mapped keys into net.setting (which the connection layer reads)
--   login           whitelist / bans / server full are checked before login_finished (net.hook_login_check -> mc.login_check)
--   join            the player row is created while the join record is built, so the entity id in the `login` packet is the id the game uses
--   keep-alive      the game owns scheduling and timeouts; mc.server_tick copies the client's answers (and teleport confirmations) to the game's queue
--   chunks          flat chunks are generated on demand and served from the world's packet cache
-- Overridden connection-layer functions (copies with one marked change each): net.h_login, net.play_begin.
-- Keep-alive answers and teleport confirmations reach the game by a pre-scan of net.inbox in mc.server_tick (sql/420), not by overriding net.h_play.

alter table net.conn add column if not exists ip      inet;
alter table net.conn add column if not exists view_cx int;     -- chunk the client's view is centred on (what it has loaded); null before the first chunk batch
alter table net.conn add column if not exists view_cz int;

------------------------------------------------------------------------------------------------ settings
create table if not exists net.setting_map (net_key text primary key, mc_key text not null);
insert into net.setting_map (net_key, mc_key) values
    ('motd', 'motd'), ('max_players', 'max-players'), ('view_distance', 'view-distance'), ('simulation_distance', 'simulation-distance'),
    ('gamemode', 'gamemode'), ('online_mode', 'online-mode'), ('compression_threshold', 'network-compression-threshold')
on conflict (net_key) do nothing;

create or replace function net.sync_settings() returns void language sql as $$
    insert into net.setting (key, value)
    select m.net_key, p.value from net.setting_map m join mc.server_property p on p.key = m.mc_key
    on conflict (key) do update set value = excluded.value $$;

create or replace function mc.server_property_sync() returns trigger language plpgsql as $$
begin
    insert into net.setting (key, value) select m.net_key, new.value from net.setting_map m where m.mc_key = new.key
    on conflict (key) do update set value = excluded.value;
    return null;
end $$;
drop trigger if exists server_property_sync on mc.server_property;
create trigger server_property_sync after insert or update of value on mc.server_property for each row execute function mc.server_property_sync();

-- Settings for the development server this repository can run today: offline mode (encryption is the real gateway's job and is not built) and no
-- compression (SQL has no deflate).  Spawn comes from the world.  Idempotent.  Not run by the migration, so the module tests keep vanilla's defaults.
create or replace function mc.configure_dev_server(p_motd text default 'dbcraft', p_gamemode text default 'creative') returns void language plpgsql as $$
declare d mc.dimension;
begin
    update mc.server_property set value = 'false' where key = 'online-mode';
    update mc.server_property set value = '-1'    where key = 'network-compression-threshold';
    update mc.server_property set value = 'false' where key = 'white-list';
    update mc.server_property set value = p_motd  where key = 'motd';
    update mc.server_property set value = p_gamemode where key = 'gamemode';
    update mc.server_property set value = 'minecraft:flat' where key = 'level-type';
    select * into d from mc.dimension where name = 'minecraft:overworld';
    update mc.game_state set spawn_x = d.spawn_x + 0.5, spawn_y = d.spawn_y, spawn_z = d.spawn_z + 0.5;
    perform net.sync_settings();
end $$;

------------------------------------------------------------------------------------------------ connection events
create or replace function net.on_connect(p_conn bigint, p_ip inet) returns void language sql as $$
    insert into net.conn (conn_id, compression, ip) values (p_conn, -1, p_ip) on conflict (conn_id) do nothing $$;

------------------------------------------------------------------------------------------------ login check
create or replace function net.hook_login_check(p_conn bigint, p_name text, p_uuid uuid, out allowed boolean, out disconnect_json text) language plpgsql stable as $$
declare r record; v_ip inet;
begin
    select ip into v_ip from net.conn where conn_id = p_conn;
    select * into r from mc.login_check(p_uuid, p_name, v_ip);
    allowed := r.allowed;
    if not r.allowed then disconnect_json := mc.disconnect_json(r.reason_key, r.reason_args, r.expiry_args); end if;
end $$;

-- COPY of net.h_login (sql/120_net_login.sql) with ONE addition, marked "integration": the login check.
create or replace function net.h_login(p_conn bigint, p_name text, body bytea) returns void language plpgsql as $$
declare nm text; o int; u uuid; sid uuid := gen_random_uuid(); thr int := net.setting('compression_threshold')::int; chk record;
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
        -- integration: banned profile, whitelist, banned IP, server full (vanilla's order), refused before compression is announced
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

------------------------------------------------------------------------------------------------ play entry
-- COPY of net.play_begin (sql/160_net_play.sql) with ONE change, marked "integration": the new player's tab-list entry is NOT broadcast here when the game handled the join.  mc.on_join
-- (called from net.hook_join_info) queues, for everyone else, the join message and then the tab-list entry, in vanilla's order (join message first,
-- verified against a two-client recording); sending it here too would duplicate it and put it before the message.
create or replace function net.play_begin(p_conn bigint) returns void language plpgsql as $$
declare j net.join_info := net.hook_join_info(p_conn);
begin
    update net.conn set entity_id = j.entity_id, gamemode = j.gamemode, teleport_id = j.teleport_id, teleport_ok = false where conn_id = p_conn;
    insert into net.outbox (conn_id, data)
    select p_conn, net.frame(c.compression, pk.protocol_id, e.body)
    from net.conn c,
         (select * from net.play_entry_packets(p_conn, j)
          union all select 120, 'minecraft:player_info_update', net.player_info_body(array(select conn_id from net.conn where state = 'play' and conn_id <> p_conn))
          union all select 130, 'minecraft:player_info_update', net.player_info_body(array[p_conn])) e
    join ref.packet pk on pk.state = 'play' and pk.direction = 'clientbound' and pk.name = e.packet
    where c.conn_id = p_conn
    order by e.ord;
    -- integration: when the game layer handled the join (a player row exists for this connection) it has already queued the join message and the tab-list
    -- entry for the others; broadcasting here too would duplicate it and put it before the message.  Without a game player (the connection layer alone, as in
    -- its own tests) the original broadcast is kept.
    if not exists (select 1 from mc.player where conn_id = p_conn::int) then
        insert into net.outbox (conn_id, data)
        select o.conn_id, net.frame(o.compression, net.pkt('play', 'clientbound', 'minecraft:player_info_update'), net.player_info_body(array[p_conn]))
        from net.conn o where o.state = 'play' and o.conn_id <> p_conn and not o.closing;
    end if;
    perform net.hook_on_join(p_conn);
    perform net.send_chunks(p_conn, j.chunk_x, j.chunk_z, j.view_distance);
end $$;

-- The join record from the real player row.  Creating the player here (not in hook_on_join) is deliberate: the entity id has to be known for the
-- `login` packet, and mc.on_join is what allocates it.  What mc.on_join queues for the joiner itself (its own join message and tab entries) is dropped:
-- vanilla does not send the joiner its own join message, and the entry burst already carries the tab list.
create or replace function net.hook_join_info(p_conn bigint) returns net.join_info language plpgsql volatile as $$
declare c net.conn; p mc.player; j net.join_info; gs mc.game_state; before bigint; w mc.world; s record; st int;
begin
    select * into c from net.conn where conn_id = p_conn;
    select * into gs from mc.game_state;
    select * into w from mc.world limit 1;
    before := coalesce((select max(seq) from mc.play_out), 0);
    p := mc.on_join(p_conn::int, c.uuid, c.name);
    delete from mc.play_out where seq > before and conn_id = p_conn::int;
    update mc.player set teleport_id = 1, awaiting_teleport = null where uuid = p.uuid;

    j := net.default_join_info(p_conn, p.gamemode);
    j.entity_id := p.entity_id;
    j.hardcore := mc.prop_bool('hardcore');
    j.max_players := mc.prop_int('max-players'); j.view_distance := mc.prop_int('view-distance'); j.simulation_distance := mc.prop_int('simulation-distance');
    j.seed := coalesce(w.seed, 0); j.is_flat := true; j.sea_level := -63;
    j.difficulty := case mc.prop('difficulty') when 'peaceful' then 0 when 'easy' then 1 when 'hard' then 3 else 2 end;
    j.held_slot := p.held_slot; j.op_level := mc.permission_level(p.uuid);
    j.x := p.x; j.y := p.y; j.z := p.z; j.yaw := p.yaw; j.pitch := p.pitch; j.teleport_id := 1;
    j.motd := mc.prop('motd');
    j.game_time := gs.game_time;
    j.clocks := jsonb_build_array(jsonb_build_object('id', 1, 'ticks', gs.day_time, 'partial', 0, 'rate', 1.0),
                                  jsonb_build_object('id', 0, 'ticks', gs.day_time, 'partial', 0, 'rate', 1.0));
    j.spawn_x := floor(gs.spawn_x)::int; j.spawn_y := floor(gs.spawn_y)::int; j.spawn_z := floor(gs.spawn_z)::int; j.spawn_yaw := gs.spawn_yaw;
    j.chunk_x := p.chunk_x; j.chunk_z := p.chunk_z;
    j.health := p.health; j.food := p.food; j.saturation := p.saturation; j.xp_level := p.xp_level;

    -- a returning player's inventory: the burst's container_set_content is empty, so send each stack as a slot update right after it
    st := 1;
    for s in select slot, item, count from mc.inventory_slot where player = p.uuid and components is null order by slot loop
        st := st + 1;
        insert into mc.play_out (conn_id, data) values (p_conn::int, mc.pkt_container_set_slot(st, s.slot, s.item, s.count));
    end loop;
    update mc.player set inv_state = st where uuid = p.uuid;
    return j;
end $$;

create or replace function net.hook_on_join(p_conn bigint) returns void language sql as $$ select 1 $$;      -- the join happens in net.hook_join_info
create or replace function net.hook_player_loaded(p_conn bigint) returns void language sql as $$ select 1 $$;
create or replace function net.hook_disconnect(p_conn bigint) returns void language sql as $$ select mc.on_leave(p_conn::int) $$;

------------------------------------------------------------------------------------------------ chunks
-- The chunk coordinates in a square, nearest first.
create or replace function net.chunk_square(p_cx int, p_cz int, p_r int) returns table (x int, z int) language sql immutable parallel safe as $$
    select p_cx + dx, p_cz + dz from generate_series(-p_r, p_r) dx, generate_series(-p_r, p_r) dz order by dx * dx + dz * dz, dx, dz $$;

-- The body of a chunk packet, from the world's packet cache (the cache holds the framed packet; the body starts after the length and id VarInts).
create or replace function mc.chunk_body_cached(p_dim text, p_cx int, p_cz int) returns bytea language plpgsql volatile as $$
declare pkt bytea := mc.chunk_packet(p_dim, p_cx, p_cz); o int;
begin
    select nxt into o from proto.varint_read(pkt, 0);
    select nxt into o from proto.varint_read(pkt, o);
    return substring(pkt from o + 1);
end $$;

-- level_chunk_with_light bodies for the square of radius view-distance + 1 around (cx, cz) (what vanilla sends: 49 chunks at view distance 2), nearest
-- first, generating flat chunks that do not exist yet.  Also records the chunk the client's view is now centred on (net.conn.view_cx/view_cz).
-- net.send_chunks (the connection layer's own, unchanged) frames them in a chunk batch.
create or replace function net.hook_chunks(p_conn bigint, p_cx int, p_cz int, p_radius int) returns setof bytea language plpgsql volatile as $$
declare r int := p_radius + 1; dim text := 'minecraft:overworld';
begin
    if not mc.world_ready() then
        raise notice 'net.hook_chunks: world reference data is not loaded (run tools/load_world_ref.py); no chunks sent to connection %', p_conn;
        return;
    end if;
    perform mc.generate_flat(dim, s.x, s.z) from net.chunk_square(p_cx, p_cz, r) s;
    update net.conn set view_cx = p_cx, view_cz = p_cz where conn_id = p_conn;
    return query select mc.chunk_body_cached(dim, s.x, s.z) from net.chunk_square(p_cx, p_cz, r) s;
end $$;
