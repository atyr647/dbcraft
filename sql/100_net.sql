-- Connections: tables, queues, helpers.  The gateway only moves bytes in and out of these tables (docs/NET.md).
--
-- Contract with the gateway
--   in : COPY net.inbox (conn_id, payload) -- one row per frame, payload = frame WITHOUT its length prefix = VarInt packet id || body.
--        If compression is on for the connection the gateway has already inflated it (data length stripped).
--        Rows are processed in (conn_id, seq) order; seq is assigned on insert.
--   out: select * from net.drain_outbox() -> (conn_id, data, close): data is complete, framed (and, if enabled, compressed) wire bytes
--        in order, ready to be encrypted (online mode) and written; when close is true the gateway closes the socket after writing.
--   events: net.on_connect(conn_id) when a socket is accepted, net.on_disconnect(conn_id) when it closes.

------------------------------------------------------------------------------------------------ settings
-- Defaults only; the game layer may replace this table with a view over its own server properties (same columns).
create table if not exists net.setting (key text primary key, value text not null);
insert into net.setting(key, value) values
    ('motd',                   'A dbcraft server'),
    ('max_players',            '20'),
    ('version_name',           '26.3'),
    ('protocol_version',       '777'),
    ('brand',                  'dbcraft'),
    ('compression_threshold',  '-1'),      -- network-compression-threshold; -1 = off
    ('online_mode',            'false'),
    ('view_distance',          '10'),
    ('simulation_distance',    '10')
on conflict (key) do nothing;

create or replace function net.setting(k text) returns text language sql stable as $$ select value from net.setting where key = k $$;

------------------------------------------------------------------------------------------------ connection state
-- state: handshake | status | login | login_ack (waiting for login_acknowledged) | configuration | play
create unlogged table if not exists net.conn (
    conn_id        bigint primary key,
    state          text    not null default 'handshake',
    closing        boolean not null default false,   -- close after the pending output is flushed
    proto_version  int,
    address        text,
    port           int,
    name           text,
    uuid           uuid,
    session_id     uuid,
    compression    int     not null default -1,      -- threshold in effect for this connection; -1 = off
    encrypted      boolean not null default false,   -- online mode: set by the gateway/auth layer after the key exchange
    entity_id      int,
    teleport_id    int     not null default 0,       -- last teleport id sent / expected back
    teleport_ok    boolean not null default true,
    keepalive_id   bigint,                           -- id of the keep_alive we sent and have not seen answered
    loaded         boolean not null default false,   -- player_loaded received
    chunks_per_tick real,                            -- from chunk_batch_received
    client_info    jsonb,                            -- last client_information (language, view distance ...)
    brand          text,                             -- brand the client announced
    connected_at   timestamptz not null default now(),
    last_activity  timestamptz not null default now()
) with (fillfactor = 60);

create sequence if not exists net.inbox_seq  cache 1000;
create sequence if not exists net.outbox_seq cache 1000;
-- Play-state packets the connection layer does not handle itself, for the game tick (mc.tick) to consume set-based.
create unlogged table if not exists net.play_inbox (conn_id bigint not null, seq bigint not null, packet_id int not null, body bytea not null);
-- Scratch table for one net.process() batch (single writer: process() is called by the tick, never concurrently).
create unlogged table if not exists net.batch (conn_id bigint not null, seq bigint not null, payload bytea not null);

create unlogged table if not exists net.inbox  (conn_id bigint not null, seq bigint not null default nextval('net.inbox_seq'), payload bytea not null);
create unlogged table if not exists net.outbox (conn_id bigint not null, seq bigint not null default nextval('net.outbox_seq'), data bytea not null);

------------------------------------------------------------------------------------------------ helpers
-- Packet id by name, from the generated packet table (never hard-coded).
create or replace function net.pkt(st text, dir text, nm text) returns int language sql stable as $$
    select coalesce((select protocol_id from ref.packet where state = st and direction = dir and name = nm),
                    proto.bad('unknown packet ' || st || '/' || dir || '/' || nm)::int) $$;
-- Packet name by id (NULL when the id does not exist in that state/direction).
create or replace function net.pkt_name(st text, dir text, id int) returns text language sql stable as $$
    select name from ref.packet where state = st and direction = dir and protocol_id = id $$;

-- Lax packet id read: 1- or 2-byte VarInt (all packet ids fit); NULL for anything else. Never raises, so it is safe in set-based code.
create or replace function net.pid(payload bytea) returns int language sql immutable parallel safe as $$
    select case when length(payload) = 0 then null
                when get_byte(payload, 0) < 128 then get_byte(payload, 0)
                when length(payload) >= 2 and get_byte(payload, 1) between 1 and 127 then (get_byte(payload, 0) & 127) | (get_byte(payload, 1) << 7)
           end $$;
create or replace function net.pid_len(payload bytea) returns int language sql immutable parallel safe as $$
    select case when get_byte(payload, 0) < 128 then 1 else 2 end $$;

-- Offline-mode UUID: version 3 of the UTF-8 bytes of 'OfflinePlayer:' || name (what Java's UUID.nameUUIDFromBytes gives).
create or replace function net.offline_uuid(name text) returns uuid language sql immutable parallel safe as $$
    select encode(set_byte(set_byte(h, 6, (get_byte(h, 6) & 15) | 48), 8, (get_byte(h, 8) & 63) | 128), 'hex')::uuid
    from (select decode(md5('OfflinePlayer:' || name), 'hex') as h) s $$;

-- Valid player name: at most 16 characters, each between '!' and '~' (Minecraft's StringUtil.isValidPlayerName).
create or replace function net.valid_name(name text) returns boolean language sql immutable parallel safe as $$
    select char_length(name) <= 16 and name !~ '[^\x21-\x7e]' $$;

------------------------------------------------------------------------------------------------ framing and sending
-- zlib deflate is not available in SQL (docs/COMPRESSION.md): frames at or above the threshold need a native deflate.
-- Until one is installed this raises; packets below the threshold never reach it.
create or replace function net.deflate_frame(packet_id int, body bytea) returns bytea language plpgsql as $$
begin
    raise exception 'net.deflate_frame: compression threshold exceeded but no deflate implementation is installed (see docs/COMPRESSION.md)';
end $$;

-- A complete wire frame for a connection with the given compression threshold (-1 = off).
create or replace function net.frame(threshold int, packet_id int, body bytea) returns bytea language sql immutable as $$
    select case when threshold < 0 then proto.frame(packet_id, body)
                when octet_length(proto.varint(packet_id)) + octet_length(body) < threshold then proto.frame_small_compressed(packet_id, body)
                else net.deflate_frame(packet_id, body) end $$;

-- Queue one packet for a connection.
create or replace function net.send(p_conn bigint, p_packet_id int, p_body bytea default '\x') returns void language sql as $$
    insert into net.outbox(conn_id, data)
    select p_conn, net.frame(c.compression, p_packet_id, p_body) from net.conn c where c.conn_id = p_conn $$;
-- ... by packet name, in the connection's current state.
create or replace function net.send(p_conn bigint, p_name text, p_body bytea) returns void language sql as $$
    insert into net.outbox(conn_id, data)
    select p_conn, net.frame(c.compression, net.pkt(c.state_for_send, 'clientbound', p_name), p_body)
    from (select conn_id, compression, case state when 'login_ack' then 'login' else state end as state_for_send from net.conn where conn_id = p_conn) c $$;

-- Mark a connection to be closed once its output is flushed.
create or replace function net.close(p_conn bigint) returns void language sql as $$
    update net.conn set closing = true where conn_id = p_conn $$;

-- What the gateway asks for each tick: all pending bytes per connection, in order, and whether to close afterwards.
-- Closed connections are removed here (after their last bytes were handed over).
create or replace function net.drain_outbox() returns table(conn_id bigint, data bytea, close boolean) language plpgsql as $$
begin
    return query
    with out as (delete from net.outbox returning net.outbox.conn_id, net.outbox.seq, net.outbox.data),
         agg as (select o.conn_id, string_agg(o.data, ''::bytea order by o.seq) as data from out o group by o.conn_id),
         cl  as (select c.conn_id from net.conn c where c.closing)
    select coalesce(a.conn_id, cl.conn_id), coalesce(a.data, '\x'::bytea), (cl.conn_id is not null)
    from agg a full join cl on cl.conn_id = a.conn_id;
    delete from net.conn where closing;
end $$;

------------------------------------------------------------------------------------------------ lifecycle
create or replace function net.on_connect(p_conn bigint) returns void language sql as $$
    insert into net.conn(conn_id, compression) values (p_conn, -1) on conflict (conn_id) do nothing $$;
