-- Shared by the net tests (\ir _net_helpers.sql).  Gives every test file a clean slate and one set of helpers.
-- Reset: connections, queues, caches, registry/tag rows, settings back to their defaults, hooks back to the no-op defaults, leftover t.* tables.
create or replace function t.reset_net() returns void language plpgsql as $$
declare r record;
begin
    truncate net.conn, net.inbox, net.outbox, net.play_inbox, net.batch, net.config_cache, net.static_packet;
    delete from ref.dp_tag_member; delete from ref.dp_tag; delete from ref.dp_tag_registry;
    delete from ref.dp_node; delete from ref.dp_entry; delete from ref.dp_registry;
    delete from net.setting;
    insert into net.setting (key, value) select key, value from net.default_settings();
    for r in select tablename from pg_tables where schemaname = 't' loop execute format('drop table t.%I', r.tablename); end loop;
end $$;
select t.reset_net();
\ir ../../sql/190_net_hooks.sql

-- feed a wire frame (with its length prefix) as the gateway hands it over: the prefix is stripped
create or replace function t.feed(p_conn bigint, p_hex text) returns void language sql as $$
    insert into net.inbox(conn_id, payload)
    select p_conn, substring(b from (proto.varint_read(b)).nxt + 1) from (select decode(p_hex, 'hex') as b) s $$;
-- ... a frame sent after compression started: it also has a data length (0 = not compressed), which the gateway strips too
create or replace function t.feed_c(p_conn bigint, p_hex text) returns void language sql as $$
    insert into net.inbox(conn_id, payload)
    select p_conn, substring(b from (proto.varint_read(b, (proto.varint_read(b)).nxt)).nxt + 1) from (select decode(p_hex, 'hex') as b) s $$;
-- feed a packet by name and body (payload = id || body)
create or replace function t.feed_pkt(p_conn bigint, p_state text, p_name text, p_body bytea default '\x') returns void language sql as $$
    insert into net.inbox(conn_id, payload) values (p_conn, proto.varint(net.pkt(p_state, 'serverbound', p_name)) || p_body) $$;
-- everything queued for a connection, removed from the outbox
create or replace function t.take(p_conn bigint) returns bytea language plpgsql as $$
declare h bytea;
begin
    select string_agg(data, ''::bytea order by seq) into h from net.outbox where conn_id = p_conn;
    delete from net.outbox where conn_id = p_conn;
    return coalesce(h, '\x');
end $$;
create or replace function t.take_hex(p_conn bigint) returns text language sql as $$ select encode(t.take(p_conn), 'hex') $$;
-- split concatenated wire frames
create or replace function t.frames(b bytea) returns table (idx int, frame bytea) language plpgsql as $$
declare o int := 0; v int; n int; i int := 0;
begin
    while o < length(b) loop
        select val, nxt into v, n from proto.varint_read(b, o);
        idx := i; frame := substring(b from o + 1 for (n - o) + v); o := n + v; i := i + 1; return next;
    end loop;
end $$;
-- the packet names in concatenated clientbound frames
create or replace function t.names(p_state text, b bytea) returns text[] language plpgsql as $$
declare o int := 0; v int; n int; id int; out text[] := '{}';
begin
    while o < length(b) loop
        select val, nxt into v, n from proto.varint_read(b, o);
        select val into id from proto.varint_read(b, n);
        out := out || coalesce(net.pkt_name(p_state, 'clientbound', id), '?');
        o := n + v;
    end loop;
    return out;
end $$;
create or replace function t.skip(why text) returns void language plpgsql as $$ begin raise notice 'SKIP %', why; end $$;
-- a player already in play state (the full login path is tested in 130)
create or replace function t.player(p_conn bigint, p_name text) returns void language plpgsql as $$
begin
    perform net.on_connect(p_conn);
    update net.conn set state = 'play', name = p_name, uuid = net.offline_uuid(p_name), gamemode = 1, entity_id = 100 + p_conn, teleport_id = 1, teleport_ok = false where conn_id = p_conn;
end $$;
