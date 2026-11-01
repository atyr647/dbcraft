-- The play state as far as the connection layer goes: the entry sequence, keep-alive, and the protocol-level serverbound packets.
-- Everything else a client sends in play (movement, chat, digging, ...) is moved into net.play_inbox by net.process() for mc.tick().

create or replace function net.play_begin(p_conn bigint) returns void language plpgsql as $$
declare j net.join_info := net.hook_join_info(p_conn); o record;
begin
    update net.conn set entity_id = j.entity_id, gamemode = j.gamemode, teleport_id = j.teleport_id, teleport_ok = false where conn_id = p_conn;
    -- the entry sequence; the player-info packets sit at fixed places in it: the other players first, then this player (which everyone gets)
    insert into net.outbox (conn_id, data)
    select p_conn, net.frame(c.compression, net.pkt('play', 'clientbound', e.packet), e.body)
    from net.conn c,
         (select * from net.play_entry_packets(p_conn, j)
          union all select 120, 'minecraft:player_info_update', net.player_info_body(array(select conn_id from net.conn where state = 'play' and conn_id <> p_conn))
          union all select 130, 'minecraft:player_info_update', net.player_info_body(array[p_conn])) e
    where c.conn_id = p_conn
    order by e.ord;
    -- tell everyone already in the game about the new player
    for o in select conn_id from net.conn where state = 'play' and conn_id <> p_conn and not closing loop
        perform net.send(o.conn_id, net.pkt('play', 'clientbound', 'minecraft:player_info_update'), net.player_info_body(array[p_conn]));
    end loop;
    perform net.hook_on_join(p_conn);
    perform net.send_chunks(p_conn, j.chunk_x, j.chunk_z, j.view_distance);
end $$;

-- Chunks for a player, in one batch: batch start, the chunk packets, batch finished (with the count).  The packets come from the world layer.
create or replace function net.send_chunks(p_conn bigint, p_cx int, p_cz int, p_radius int) returns int language plpgsql as $$
declare bodies bytea[] := array(select b from net.hook_chunks(p_conn, p_cx, p_cz, p_radius) b); n int := coalesce(cardinality(bodies), 0);
begin
    if n > 0 then
        perform net.send(p_conn, net.pkt('play', 'clientbound', 'minecraft:chunk_batch_start'), '\x');
        insert into net.outbox (conn_id, data)
        select p_conn, net.frame(c.compression, net.pkt('play', 'clientbound', 'minecraft:level_chunk_with_light'), b.body)
        from net.conn c, unnest(bodies) with ordinality b(body, o) where c.conn_id = p_conn order by b.o;
        perform net.send(p_conn, net.pkt('play', 'clientbound', 'minecraft:chunk_batch_finished'), proto.varint(n));
    end if;
    return n;
end $$;

create or replace function net.h_play(p_conn bigint, pid int, p_name text, body bytea) returns void language plpgsql as $$
declare c net.conn; tid int; v real; ch text; o int; br text;
begin
    select * into c from net.conn where conn_id = p_conn;
    if p_name = 'minecraft:keep_alive' then
        perform net.need(body, 8);
        if c.keepalive_id is not null and proto.i64_read(body, 0) = c.keepalive_id then
            update net.conn set keepalive_id = null, latency_ms = greatest(0, (extract(epoch from now() - keepalive_sent) * 1000)::int) where conn_id = p_conn;
        end if;
    elsif p_name = 'minecraft:pong' then
        null;
    elsif p_name = 'minecraft:accept_teleportation' then
        -- 26.3 layout: id VarInt, then x y z (doubles) and yRot xRot (floats) as the client sees them
        select val into tid from proto.varint_read(body, 0);
        if tid = c.teleport_id then update net.conn set teleport_ok = true where conn_id = p_conn; end if;
    elsif p_name = 'minecraft:chunk_batch_received' then
        perform net.need(body, 4);
        v := proto.f32_read(body, 0);
        update net.conn set chunks_per_tick = case when v <> 'NaN'::real and v > 0.01 then least(v, 64) else 0.01 end where conn_id = p_conn;   -- Postgres: NaN = NaN and NaN > everything, so test it explicitly
    elsif p_name = 'minecraft:player_loaded' then
        update net.conn set loaded = true where conn_id = p_conn;
        perform net.hook_player_loaded(p_conn);
    elsif p_name = 'minecraft:client_information' then
        update net.conn set client_info = net.read_client_information(body) where conn_id = p_conn;
    elsif p_name = 'minecraft:custom_payload' then
        select val, nxt into ch, o from proto.string_read(body, 0);
        if ch = 'minecraft:brand' then select val into br from proto.string_read(body, o); update net.conn set brand = left(br, 64) where conn_id = p_conn; end if;
    elsif p_name = 'minecraft:configuration_acknowledged' then
        null;                                       -- re-entering configuration from play is not supported
    else
        -- a play packet for the game (reached here only when the connection entered play inside this batch)
        insert into net.play_inbox (conn_id, seq, packet_id, body) values (p_conn, nextval('net.inbox_seq'), pid, body);
    end if;
end $$;

-- Keep-alive: every 15 s each player gets a keep_alive with a random id; a player who has not answered within 30 s is dropped.
-- Called by the tick (once per second is plenty).
create or replace function net.keepalive_tick() returns int language plpgsql as $$
declare r record; n int := 0;
begin
    for r in select conn_id from net.conn where state = 'play' and not closing and keepalive_id is not null and keepalive_sent < now() - interval '30 seconds' loop
        perform net.send(r.conn_id, net.pkt('play', 'clientbound', 'minecraft:disconnect'), nbt.text_translate('disconnect.timeout'));
        perform net.close(r.conn_id);
    end loop;
    with due as (
        update net.conn set keepalive_id = (random() * 9007199254740991)::bigint, keepalive_sent = now()
        where state = 'play' and not closing and keepalive_id is null and (keepalive_sent is null or keepalive_sent < now() - interval '15 seconds')
        returning conn_id, keepalive_id)
    insert into net.outbox (conn_id, data)
    select d.conn_id, net.frame(c.compression, net.pkt('play', 'clientbound', 'minecraft:keep_alive'), proto.i64(d.keepalive_id))
    from due d join net.conn c using (conn_id);
    get diagnostics n = row_count;
    return n;
end $$;
