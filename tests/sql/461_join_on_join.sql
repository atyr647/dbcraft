-- sql/461: mc.on_join builds each broadcast packet once and, when asked (p_to_joiner = false), builds nothing for the joiner itself.  What the OTHER players
-- are sent must be byte-for-byte what the original queued, in the same order, for a plain join and for a duplicate login.
\ir ../../sql/461_join_on_join.sql

create or replace function t.setup_players() returns void language plpgsql as $$
begin
    truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick;
    delete from mc.player;
    perform setval('mc.entity_id_seq', 1, false);
    update mc.game_state set spawn_x = 0.5, spawn_y = 64, spawn_z = 0.5, spawn_yaw = 0;
    perform mc.on_join(1, '00000000-0000-0000-0000-000000046101', 'P1');
    perform mc.on_join(2, '00000000-0000-0000-0000-000000046102', 'P2');
    perform mc.on_join(3, '00000000-0000-0000-0000-000000046103', 'P3');
    perform mc.on_join(4, '00000000-0000-0000-0000-000000046104', 'P4');
    update mc.player set gamemode = 1 where name = 'P2';                     -- not every tab entry the same
    truncate mc.play_out, mc.kick;
end $$;
-- everything queued per connection, concatenated in queue order
create or replace function t.out_by_conn() returns table (conn_id int, d bytea) language sql as $$
    select conn_id, string_agg(data, ''::bytea order by seq) from mc.play_out group by conn_id order by conn_id $$;

-- 1. a new player joins four online players
select t.setup_players();
select mc.on_join(5, '00000000-0000-0000-0000-000000046105', 'P5');                -- the original signature: joiner included
create table t.ref_new as select * from t.out_by_conn();
create table t.ref_player as select md5(row(name, gamemode, x, y, z, yaw, chunk_x, chunk_z, conn_id, entity_id, held_slot, health)::text) as m from mc.player where name = 'P5';
select t.setup_players();
select mc.on_join(5, '00000000-0000-0000-0000-000000046105', 'P5', false);
create table t.fast_new as select * from t.out_by_conn();
create table t.fast_player as select md5(row(name, gamemode, x, y, z, yaw, chunk_x, chunk_z, conn_id, entity_id, held_slot, health)::text) as m from mc.player where name = 'P5';
select t.eq('a join: connections 1-4 are sent the same bytes by both variants',
            (select count(*)::int from t.ref_new r full join t.fast_new f using (conn_id) where conn_id between 1 and 4 and r.d is distinct from f.d), 0);
select t.eq('...all four were sent something', (select count(*)::int from t.fast_new where conn_id between 1 and 4 and length(d) > 0), 4);
select t.is_true('the original variant also queued rows for the joiner (own message, own tab entry, the players already online)', exists (select 1 from t.ref_new where conn_id = 5 and length(d) > 100));
select t.eq('the quiet variant queues nothing for the joiner', (select count(*)::int from t.fast_new where conn_id = 5), 0);
select t.eq('...and nothing for any other connection', (select count(*)::int from t.fast_new where conn_id not between 1 and 5), 0);
select t.eq('the join message and tab entry are what the packet builders produce',
            (select d from t.fast_new where conn_id = 1),
            mc.pkt_system_chat(proto.nbt_root(mc.tc_translate('multiplayer.player.joined', array[mc.tc_player('00000000-0000-0000-0000-000000046105', 'P5')], 'yellow')))
            || mc.pkt_player_info_add(array[mc.pie_add('00000000-0000-0000-0000-000000046105', 'P5', (select gamemode from mc.player where name = 'P5'))]));   -- the server's default game mode, whatever earlier tests left it at
select t.eq('both variants leave the same player row', (select m from t.fast_player), (select m from t.ref_player));
select t.eq('...and it is a row (not two NULLs)', (select count(*)::int from t.ref_player where m is not null), 1);

-- 2. a duplicate login: P4 (conn 4) comes back on conn 6 while the old connection is still online (vanilla kicks the older session)
select t.setup_players();
select mc.on_join(6, '00000000-0000-0000-0000-000000046104', 'P4');
create table t.ref_dup as select * from t.out_by_conn();
create table t.ref_dup_kick as select * from mc.kick order by 1;
select t.setup_players();
select mc.on_join(6, '00000000-0000-0000-0000-000000046104', 'P4', false);
create table t.fast_dup as select * from t.out_by_conn();
create table t.fast_dup_kick as select * from mc.kick order by 1;
select t.eq('a duplicate login: every other connection (1-4) is sent the same bytes by both variants',
            (select count(*)::int from t.ref_dup r full join t.fast_dup f using (conn_id) where conn_id between 1 and 4 and r.d is distinct from f.d), 0);
select t.eq('...the same connections are kicked', (select count(*)::int from (select * from t.ref_dup_kick except select * from t.fast_dup_kick union all select * from t.fast_dup_kick except select * from t.ref_dup_kick) x), 0);
select t.is_true('...and the older connection really was kicked', (select count(*) from t.fast_dup_kick) >= 1 or exists (select 1 from t.fast_dup where conn_id = 4));
select t.eq('...nothing is queued for the new connection', (select count(*)::int from t.fast_dup where conn_id = 6), 0);
select t.eq('...the player now belongs to the new connection', (select conn_id from mc.player where name = 'P4'), 6);

-- 3. an empty server
truncate mc.play_out, mc.visible; delete from mc.player;
select mc.on_join(1, '00000000-0000-0000-0000-000000046101', 'P1', false);
select t.eq('into an empty server nothing is queued at all', (select count(*)::int from mc.play_out), 0);
select t.eq('...and the player exists', (select conn_id from mc.player where name = 'P1'), 1);
