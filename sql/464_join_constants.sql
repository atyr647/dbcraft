-- Login-path speed, round 5: what is the same for every joiner (or changes once per login) is computed once.
--
-- 1. The tab-list entry of a player is uuid + name + two zero bytes + (game mode, listed, latency, three zero bytes).  The first part only changes when the name or uuid is
--    assigned (once per login).  A joiner is sent the entry of EVERY player online (vanilla does the same, so the bytes are inherent) and building each one from the uuid
--    text (uuid::text, replace, decode) and the UTF-8 name cost 7.4 us per entry, 4.5 ms for a joiner at 600 online.  net.conn_tab keeps the constant head per connection
--    (a cache: maintained by a trigger on net.conn, never the source of truth; kept out of net.conn itself because that row is updated every tick).
-- 2. net.player_info_body was a `language sql` function with a FROM clause, so Postgres re-planned it on every call; it is PL/pgSQL now.
-- 3. The three packets that start the configuration phase (brand, enabled features, known packs) are the same for every joiner at a given compression threshold:
--    one cached, framed row per (threshold, deflate implementation), emptied whenever net.setting changes.
-- Bytes are identical (tests/sql/464_join_constants.sql compares with the originals).

------------------------------------------------------------------------------------------------ 1. tab-list head cache
create unlogged table if not exists net.conn_tab (conn_id bigint primary key, head bytea not null);   -- uuid || name || varint(0) || false, as player_info_body wrote it

create or replace function net.conn_tab_sync() returns trigger language plpgsql as $$
begin
    if tg_op = 'DELETE' then
        delete from net.conn_tab where conn_id = old.conn_id;
    elsif new.uuid is null or new.name is null then
        delete from net.conn_tab where conn_id = new.conn_id;                    -- also clears a stale row when a connection id is reused
    else
        insert into net.conn_tab (conn_id, head) values (new.conn_id, proto.uuid(new.uuid) || proto.string(new.name) || '\x0000'::bytea)
        on conflict (conn_id) do update set head = excluded.head;
    end if;
    return null;
end $$;
drop trigger if exists conn_tab_sync on net.conn;
create trigger conn_tab_sync after insert or update of uuid, name on net.conn for each row execute function net.conn_tab_sync();
drop trigger if exists conn_tab_sync_delete on net.conn;
create trigger conn_tab_sync_delete after delete on net.conn for each row execute function net.conn_tab_sync();
-- connections that already exist when this file is applied
insert into net.conn_tab (conn_id, head)
select conn_id, proto.uuid(uuid) || proto.string(name) || '\x0000'::bytea from net.conn where uuid is not null and name is not null
on conflict (conn_id) do update set head = excluded.head;

------------------------------------------------------------------------------------------------ 2. player_info_body
-- Same bytes as sql/150_net_play_entry.sql: the full action set, the count, then each entry ordered by connection; an entry with a NULL part (no uuid, name or latency)
-- is dropped by string_agg but still counted, exactly as before.
create or replace function net.player_info_body(p_conns bigint[]) returns bytea language plpgsql stable as $$
begin
    return (select '\xff'::bytea || proto.varint(count(*)::int)
                   || coalesce(string_agg(coalesce(t.head, proto.uuid(c.uuid) || proto.string(c.name) || '\x0000'::bytea)
                                          || proto.varint(coalesce(c.gamemode, 0)) || '\x01'::bytea || proto.varint(c.latency_ms) || '\x000000'::bytea,
                                          ''::bytea order by c.conn_id), '\x'::bytea)
              from net.conn c left join net.conn_tab t on t.conn_id = c.conn_id
             where c.conn_id = any (p_conns));
end $$;

------------------------------------------------------------------------------------------------ 3. the start of the configuration phase
create unlogged table if not exists net.config_begin_cache (
    threshold int   not null,
    impl      text  not null,           -- md5 of the active mc.deflate_zlib body, as in net.config_burst
    burst     bytea not null,           -- brand, update_enabled_features, select_known_packs: framed
    primary key (threshold, impl)
);
create or replace function net.invalidate_config_begin() returns trigger language plpgsql as $$
begin delete from net.config_begin_cache; return null; end $$;
drop trigger if exists invalidate_config_begin on net.setting;
create trigger invalidate_config_begin after insert or update or delete on net.setting for each statement execute function net.invalidate_config_begin();
drop trigger if exists invalidate_config_begin_truncate on net.setting;
create trigger invalidate_config_begin_truncate after truncate on net.setting for each statement execute function net.invalidate_config_begin();

-- Same contract as sql/130_net_config.sql.
create or replace function net.config_begin(p_conn bigint) returns void language plpgsql as $$
declare thr int; v_impl text; b bytea; feats text[]; ver text;
begin
    select compression into thr from net.conn where conn_id = p_conn;
    if thr is null then return; end if;                                           -- the connection is gone: the original queued nothing either
    v_impl := coalesce((select md5(prosrc) from pg_proc where oid = 'mc.deflate_zlib(bytea)'::regprocedure), '');
    select burst into b from net.config_begin_cache where threshold = thr and impl = v_impl;
    if b is null then
        feats := string_to_array(net.setting('enabled_features'), ',');
        ver := net.setting('version_name');
        b := net.frame(thr, net.pkt('configuration', 'clientbound', 'minecraft:custom_payload'), proto.string('minecraft:brand') || proto.string(net.setting('brand')))
          || net.frame(thr, net.pkt('configuration', 'clientbound', 'minecraft:update_enabled_features'),
                       proto.varint(array_length(feats, 1)) || (select string_agg(proto.string(f), ''::bytea order by o) from unnest(feats) with ordinality t(f, o)))
          || net.frame(thr, net.pkt('configuration', 'clientbound', 'minecraft:select_known_packs'),
                       proto.varint(1) || proto.string('minecraft') || proto.string('core') || proto.string(ver));
        insert into net.config_begin_cache (threshold, impl, burst) values (thr, v_impl, b) on conflict do nothing;
    end if;
    insert into net.outbox (conn_id, data) values (p_conn, b);
end $$;
