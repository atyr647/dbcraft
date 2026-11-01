-- sql/464: the tab-list entries, the head cache that feeds them, and the cached start of the configuration phase must produce exactly what the originals (sql/150, sql/130)
-- produced.  The originals are copied below as t.*_ref.
\ir _net_helpers.sql
\ir ../../sql/460_join_codec.sql
\ir ../../sql/464_join_constants.sql

create or replace function t.player_info_body_ref(p_conns bigint[]) returns bytea language sql stable as $$
    select '\xff'::bytea || proto.varint(count(*)::int)
           || coalesce(string_agg(proto.uuid(c.uuid) || proto.string(c.name) || proto.varint(0) || proto.bool(false)
                                  || proto.varint(coalesce(c.gamemode, 0)) || proto.bool(true) || proto.varint(c.latency_ms)
                                  || proto.bool(false) || proto.varint(0) || proto.bool(false), ''::bytea order by c.conn_id), '\x'::bytea)
    from net.conn c where c.conn_id = any (p_conns) $$;

create or replace function t.config_begin_ref(p_conn bigint) returns void language plpgsql as $$
declare feats text[] := string_to_array(net.setting('enabled_features'), ',');
        ver text := net.setting('version_name');
begin
    perform net.send(p_conn, net.pkt('configuration', 'clientbound', 'minecraft:custom_payload'),
                     proto.string('minecraft:brand') || proto.string(net.setting('brand')));
    perform net.send(p_conn, net.pkt('configuration', 'clientbound', 'minecraft:update_enabled_features'),
                     proto.varint(array_length(feats, 1)) || (select string_agg(proto.string(f), ''::bytea order by o) from unnest(feats) with ordinality t(f, o)));
    perform net.send(p_conn, net.pkt('configuration', 'clientbound', 'minecraft:select_known_packs'),
                     proto.varint(1) || proto.string('minecraft') || proto.string('core') || proto.string(ver));
end $$;

------------------------------------------------------------------------------------------------ the head cache is maintained
select t.reset_net();
select net.on_connect(1, null);
select t.eq('a connection without uuid and name has no head', (select count(*)::int from net.conn_tab where conn_id = 1), 0);
update net.conn set state = 'login' where conn_id = 1;
select t.eq('...an update of other columns does not create one', (select count(*)::int from net.conn_tab where conn_id = 1), 0);
update net.conn set name = 'Alice', uuid = '00000000-0000-0000-0000-000000046401' where conn_id = 1;
select t.eq('assigning name and uuid creates the head: uuid || name || 00 00', (select head from net.conn_tab where conn_id = 1),
            proto.uuid('00000000-0000-0000-0000-000000046401') || proto.string('Alice') || '\x0000'::bytea);
update net.conn set name = 'Älice' where conn_id = 1;
select t.eq('renaming updates the head (UTF-8 length byte-wise)', (select head from net.conn_tab where conn_id = 1),
            proto.uuid('00000000-0000-0000-0000-000000046401') || proto.string('Älice') || '\x0000'::bytea);
update net.conn set uuid = null where conn_id = 1;
select t.eq('a NULL uuid removes the head', (select count(*)::int from net.conn_tab where conn_id = 1), 0);
update net.conn set uuid = '00000000-0000-0000-0000-000000046401' where conn_id = 1;
delete from net.conn where conn_id = 1;
select t.eq('deleting the connection removes the head', (select count(*)::int from net.conn_tab where conn_id = 1), 0);
insert into net.conn_tab values (7, '\xdead');                                     -- a stale row from a truncated table
select net.on_connect(7, null);
select t.eq('a reused connection id clears a stale head', (select count(*)::int from net.conn_tab where conn_id = 7), 0);

------------------------------------------------------------------------------------------------ player_info_body = the original, on random connections
select t.reset_net();
-- 300 connections: most complete, some without uuid / name or game mode, varied game modes and latencies; 60 of them inserted while the trigger is off (no head: the fallback)
insert into net.conn (conn_id, state, uuid, name, gamemode, latency_ms)
select g, 'play',
       case when g % 37 = 0 then null else ('00000000-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid end,
       case when g % 41 = 0 then null else 'Player' || g || (array['', 'é', '日本', '_x'])[1 + g % 4] end,
       case when g % 29 = 0 then null else g % 4 end,
       (g * 7) % 500                                                        -- latency_ms is NOT NULL
from generate_series(1, 240) g;
alter table net.conn disable trigger conn_tab_sync;
insert into net.conn (conn_id, state, uuid, name, gamemode, latency_ms)
select g, 'play', ('00000000-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid, 'NoHead' || g, g % 4, (g * 3) % 300 from generate_series(241, 300) g;
alter table net.conn enable trigger conn_tab_sync;
select t.eq('240 heads exist, the 60 trigger-less connections have none', (select count(*)::int from net.conn_tab where conn_id between 1 and 300), 240 - 240 / 37 - 240 / 41 + 240 / (37 * 41));
select t.eq('player_info_body of all connections equals the original', net.player_info_body((select array_agg(conn_id) from net.conn)), t.player_info_body_ref((select array_agg(conn_id) from net.conn)));
select t.eq('...of a single connection', net.player_info_body(array[5::bigint]), t.player_info_body_ref(array[5::bigint]));
select t.eq('...of no connection (the count is zero)', net.player_info_body('{}'::bigint[]), t.player_info_body_ref('{}'::bigint[]));
select t.eq('...of ids that do not exist', net.player_info_body(array[9999::bigint, 10000]), t.player_info_body_ref(array[9999::bigint, 10000]));
select t.eq('...of a connection without a head (fallback)', net.player_info_body(array[250::bigint, 260]), t.player_info_body_ref(array[250::bigint, 260]));
select t.eq('...of connections with a missing uuid or name (the entry is dropped but counted)', net.player_info_body(array[37::bigint, 41, 74, 78]), t.player_info_body_ref(array[37::bigint, 41, 74, 78]));
select t.eq('...of 200 random subsets (sizes 1 to 120)', (select count(*)::int from (
              select s.i, (select array_agg(conn_id) from (select conn_id from net.conn order by random() limit 1 + (s.i * 7) % 120) q) a from generate_series(1, 200) s(i)) z
              where net.player_info_body(z.a) is distinct from t.player_info_body_ref(z.a)), 0);
select t.is_true('...and a joiner sees every player but itself', length(net.player_info_body((select array_agg(conn_id) from net.conn where conn_id <> 1))) > 5000);
-- the same after gamemode / latency changes (they are not cached)
update net.conn set gamemode = 3, latency_ms = 123 where conn_id between 10 and 20;
select t.eq('a changed game mode and latency show up (only the head is cached)', net.player_info_body((select array_agg(conn_id) from net.conn)), t.player_info_body_ref((select array_agg(conn_id) from net.conn)));

------------------------------------------------------------------------------------------------ the start of the configuration phase
select t.reset_net();
select net.on_connect(1, null); select net.on_connect(2, null); select net.on_connect(3, null);
update net.conn set compression = 256 where conn_id = 2;
update net.conn set compression = 1 where conn_id = 3;                              -- every packet is at or above the threshold: deflated
-- what the original sends, per threshold (one captured byte string each)
select t.config_begin_ref(1); create table t.ref1 as select string_agg(data, ''::bytea order by seq) as d, count(*) as n from net.outbox where conn_id = 1; delete from net.outbox;
select t.config_begin_ref(2); create table t.ref2 as select string_agg(data, ''::bytea order by seq) as d from net.outbox where conn_id = 2; delete from net.outbox;
select t.config_begin_ref(3); create table t.ref3 as select string_agg(data, ''::bytea order by seq) as d from net.outbox where conn_id = 3; delete from net.outbox;
select t.eq('the original sent three packets (three rows)', (select n::int from t.ref1), 3);
select net.config_begin(1);
select t.eq('threshold off: brand + features + known packs are the original three sends, byte for byte', (select string_agg(data, ''::bytea order by seq) from net.outbox where conn_id = 1), (select d from t.ref1));
select t.eq('...in one row instead of three', (select count(*)::int from net.outbox where conn_id = 1), 1);
delete from net.outbox;
select net.config_begin(1);
select t.eq('...and again, now from the cache', (select string_agg(data, ''::bytea order by seq) from net.outbox where conn_id = 1), (select d from t.ref1));
delete from net.outbox;
select net.config_begin(2);
select t.eq('threshold 256: the same bytes as the original', (select string_agg(data, ''::bytea order by seq) from net.outbox where conn_id = 2), (select d from t.ref2));
delete from net.outbox;
select net.config_begin(3);
select t.eq('threshold 1 (every packet deflated): the same bytes as the original', (select string_agg(data, ''::bytea order by seq) from net.outbox where conn_id = 3), (select d from t.ref3));
select t.is_true('...and the thresholds really give different bytes', (select count(distinct d) from (select d from t.ref1 union all select d from t.ref2 union all select d from t.ref3) x) >= 2);
delete from net.outbox;
select t.eq('one cached row per threshold', (select count(*)::int from net.config_begin_cache), 3);
-- a settings change empties the cache and the next joiner sees the new brand
update net.setting set value = 'otherbrand' where key = 'brand';
select t.eq('a changed setting empties the cache', (select count(*)::int from net.config_begin_cache), 0);
select t.config_begin_ref(1); create table t.ref1b as select string_agg(data, ''::bytea order by seq) as d from net.outbox where conn_id = 1; delete from net.outbox;
select net.config_begin(1);
select t.eq('the next joiner gets the new brand, exactly as the original would send it', (select string_agg(data, ''::bytea order by seq) from net.outbox where conn_id = 1), (select d from t.ref1b));
select t.is_true('...and that differs from what was sent before the change', (select d from t.ref1b) is distinct from (select d from t.ref1));
select t.is_true('...and contains the new brand string', position(convert_to('otherbrand', 'UTF8') in (select d from t.ref1b)) > 0);
delete from net.outbox;
select net.config_begin(404);
select t.eq('a connection that does not exist gets nothing', (select count(*)::int from net.outbox where conn_id = 404), 0);
