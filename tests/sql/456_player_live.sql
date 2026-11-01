-- sql/456_player_live.sql: state tiering prototype.  Everything runs in one transaction that is rolled back, so no other test sees these objects.
begin;
insert into mc.player (uuid, name, x, y, z, yaw, pitch, chunk_x, chunk_z, conn_id, entity_id) values
    ('00000000-0000-0000-0000-000000000a01', 'live_a', 10, 64, 10, 0, 0, 0, 0, 7001, 7001),
    ('00000000-0000-0000-0000-000000000a02', 'live_b', 100, 64, 100, 0, 0, 6, 6, 7002, 7002);

select mc.live_state_enable();      -- UNLOGGED
select t.eq('live table is UNLOGGED', (select relpersistence::text from pg_class where oid = 'mc.player_live'::regclass), 'u');
select t.eq('a live row per player', (select count(*) from mc.player_live where uuid::text like '00000000-0000-0000-0000-000000000a0_')::int, 2);
select t.raises('enable twice is refused', 'select mc.live_state_enable()');

-- the hot path writes the live row only
update mc.player_live set x = 20, z = 30, chunk_x = 1, chunk_z = 1 where entity_id = 7001;
select t.eq('the durable row is untouched by a live update', (select x from mc.player where uuid = '00000000-0000-0000-0000-000000000a01'), 10::float8);
select t.eq('the state view shows the live position', (select x from mc.player_state where uuid = '00000000-0000-0000-0000-000000000a01'), 20::float8);
select t.eq('the state view shows the live chunk', (select chunk_x from mc.player_state where uuid = '00000000-0000-0000-0000-000000000a01'), 1);

-- snapshot: only the player that moved is written
select t.eq('snapshot writes the one player that moved', mc.live_snapshot(), 1);
select t.eq('the durable row now has x', (select x from mc.player where uuid = '00000000-0000-0000-0000-000000000a01'), 20::float8);
select t.eq('the durable row now has z', (select z from mc.player where uuid = '00000000-0000-0000-0000-000000000a01'), 30::float8);
select t.eq('the durable row now has the chunk', (select chunk_x * 100 + chunk_z from mc.player where uuid = '00000000-0000-0000-0000-000000000a01'), 101);
select t.eq('a second snapshot writes nothing', mc.live_snapshot(), 0);

-- movement after the snapshot, then a crash: an UNLOGGED table comes back empty after crash recovery
update mc.player_live set x = 99, z = 99 where entity_id = 7001;
update mc.player_live set x = 150 where entity_id = 7002;
truncate mc.player_live;                                         -- what crash recovery does to an unlogged table
select t.eq('after the crash the live table is empty', (select count(*) from mc.player_live)::int, 0);
select t.is_true('the state view still answers from the snapshot', (select count(*) = 2 from mc.player_state where uuid::text like '00000000-0000-0000-0000-000000000a0_'));
select t.eq('restore rebuilds a row per player', mc.live_restore() >= 2, true);
select t.eq('restored x is the LAST SNAPSHOT, not the later movement', (select x from mc.player_live where uuid = '00000000-0000-0000-0000-000000000a01'), 20::float8);
select t.eq('restored z is the LAST SNAPSHOT, not the later movement', (select z from mc.player_live where uuid = '00000000-0000-0000-0000-000000000a01'), 30::float8);
select t.eq('the player that never moved after enable is where it was', (select x from mc.player_live where uuid = '00000000-0000-0000-0000-000000000a02'), 100::float8);
select t.eq('restore clears session ids (nobody is connected after a crash)', (select count(*) from mc.player where conn_id is not null or entity_id is not null)::int, 0);
select t.eq('restore is idempotent', mc.live_restore(), 0);

-- per-player snapshot (leave, teleport)
update mc.player_live set x = 5, z = 6, chunk_x = 0, chunk_z = 0 where uuid = '00000000-0000-0000-0000-000000000a02';
select t.eq('snapshot of one player', mc.live_snapshot('00000000-0000-0000-0000-000000000a02'), 1);
select t.eq('...which wrote that player only', (select x from mc.player where uuid = '00000000-0000-0000-0000-000000000a02'), 5::float8);

-- back to the status quo keeps the last positions
update mc.player_live set x = 1234 where uuid = '00000000-0000-0000-0000-000000000a01';
select mc.live_state_disable();
select t.is_true('live table and view are gone', to_regclass('mc.player_live') is null and to_regclass('mc.player_state') is null);
select t.eq('disable snapshots first', (select x from mc.player where uuid = '00000000-0000-0000-0000-000000000a01'), 1234::float8);

-- variant b: the same objects, logged
select mc.live_state_enable(false);
select t.eq('live table is LOGGED', (select relpersistence::text from pg_class where oid = 'mc.player_live'::regclass), 'p');
rollback;
