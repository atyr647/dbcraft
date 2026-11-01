-- State tiering for per-player live state: OPT-IN PROTOTYPE.  Nothing in the game reads or writes these objects yet; applying this file changes no behaviour.
-- Why, what it saves and exactly what it risks: docs/TUNING.md, "State tiering for per-player live state".
--
-- The idea: mc.player carries ~35 columns, of which about 20 change every tick for a moving player (position, rotation, "what the viewers were last told", keep-alive
-- bookkeeping).  Every one of those updates writes a WAL record.  Only a snapshot of the position every few seconds (plus when the player leaves and on important events) must survive
-- a crash.  So the fast-changing columns move into a narrow table, `mc.player_live`, and the durable row in `mc.player` is brought up to date by `mc.live_snapshot()`.
--
--   select mc.live_state_enable();             -- UNLOGGED live table (variant a): no WAL for the per-tick updates; a crash empties it, mc.live_restore() rebuilds it from the snapshot
--   select mc.live_state_enable(false);        -- LOGGED narrow live table (variant b): every update is WAL-logged but the tuples are small and updates stay in place (HOT)
--   select mc.live_snapshot();                 -- every N ticks (N = 100 is 5 s), all players that moved;  select mc.live_snapshot(uuid) on leave, teleport, death ...
--   select mc.live_restore();                  -- after crash recovery, once, before the gateway starts
--   select * from mc.player_state;             -- one row per player with the CURRENT position (live when present, else the durable snapshot)
--   select mc.live_state_disable();            -- back to the status quo (snapshots first, then drops the live table and the view)
--
-- What the game would have to change to use it (not done here: those are other modules' files): the tick's UPDATEs of the hot columns in sql/340_game_input.sql
-- (movement, the sent_* bookkeeping, keep-alive, vis_dirty) and sql/330_game_players.sql (mc.on_join inserts the live row, mc.on_leave snapshots and deletes it) target
-- mc.player_live instead of mc.player, and their reads of those columns come from mc.player_state / mc.player_live.

do $$ begin
    if to_regclass('mc.player') is null then raise exception 'sql/456_player_live.sql needs mc.player (sql/330_game_players.sql)'; end if;
end $$;

-- The hot columns, keyed like mc.player (uuid) with the two lookup keys the tick joins on (conn_id, entity_id; neither changes while a player is online, so updates stay HOT).
create or replace function mc.live_state_enable(p_unlogged boolean default true) returns void language plpgsql as $$
begin
    if to_regclass('mc.player_live') is not null then raise exception 'mc.player_live already exists (mc.live_state_disable() first)'; end if;
    execute format('create %s table mc.player_live (
        uuid uuid primary key references mc.player (uuid) on delete cascade,
        conn_id int, entity_id int,
        x float8 not null, y float8 not null, z float8 not null, yaw real not null, pitch real not null, on_ground boolean not null, chunk_x int not null, chunk_z int not null,
        vis_dirty boolean not null default false,
        sent_qx bigint, sent_qy bigint, sent_qz bigint, sent_yaw real, sent_pitch real, last_sent_tick bigint,
        keepalive_id bigint, keepalive_sent_tick bigint, latency_ms int not null default 0,
        snapshot_x float8, snapshot_y float8, snapshot_z float8) with (fillfactor = 60)', case when p_unlogged then 'unlogged' else '' end);
    create unique index player_live_entity_idx on mc.player_live (entity_id) where entity_id is not null;
    create index player_live_conn_idx on mc.player_live (conn_id) where conn_id is not null;
    insert into mc.player_live (uuid, conn_id, entity_id, x, y, z, yaw, pitch, on_ground, chunk_x, chunk_z, vis_dirty, sent_qx, sent_qy, sent_qz, sent_yaw, sent_pitch, last_sent_tick,
                                keepalive_id, keepalive_sent_tick, latency_ms, snapshot_x, snapshot_y, snapshot_z)
    select uuid, conn_id, entity_id, x, y, z, yaw, pitch, on_ground, chunk_x, chunk_z, vis_dirty, sent_qx, sent_qy, sent_qz, sent_yaw, sent_pitch, last_sent_tick,
           keepalive_id, keepalive_sent_tick, latency_ms, x, y, z from mc.player;
    create or replace view mc.player_state as
        select p.uuid, p.name, p.gamemode, p.health, p.food, p.saturation, p.xp_level, p.held_slot, p.first_seen, p.last_seen,
               coalesce(l.conn_id, p.conn_id) as conn_id, coalesce(l.entity_id, p.entity_id) as entity_id,
               coalesce(l.x, p.x) as x, coalesce(l.y, p.y) as y, coalesce(l.z, p.z) as z, coalesce(l.yaw, p.yaw) as yaw, coalesce(l.pitch, p.pitch) as pitch,
               coalesce(l.on_ground, p.on_ground) as on_ground, coalesce(l.chunk_x, p.chunk_x) as chunk_x, coalesce(l.chunk_z, p.chunk_z) as chunk_z,
               (l.uuid is not null) as has_live_row
          from mc.player p left join mc.player_live l using (uuid);
end $$;

-- Write the durable snapshot: the position, rotation and chunk of live rows that moved since their last snapshot.  One player (on leave, teleport, death ...) or all.
-- Returns the number of rows written.  A row that did not move writes nothing, so an idle server costs nothing.
create or replace function mc.live_snapshot(p_uuid uuid default null) returns int language plpgsql as $$
declare n int;
begin
    with moved as (
        select l.uuid, l.x, l.y, l.z, l.yaw, l.pitch, l.on_ground, l.chunk_x, l.chunk_z
          from mc.player_live l join mc.player p using (uuid)
         where (p_uuid is null or l.uuid = p_uuid)
           and (p.x, p.y, p.z, p.yaw, p.pitch, p.on_ground) is distinct from (l.x, l.y, l.z, l.yaw, l.pitch, l.on_ground)),
    w as (
        update mc.player p set x = m.x, y = m.y, z = m.z, yaw = m.yaw, pitch = m.pitch, on_ground = m.on_ground, chunk_x = m.chunk_x, chunk_z = m.chunk_z
          from moved m where p.uuid = m.uuid returning p.uuid),
    s as (
        update mc.player_live l set snapshot_x = l.x, snapshot_y = l.y, snapshot_z = l.z from w where l.uuid = w.uuid returning 1)
    select count(*) into n from w;
    return n;
end $$;

-- After a crash an UNLOGGED table comes back empty.  Rebuild it from the durable snapshot: every player is at the position of the last snapshot (at most the snapshot interval
-- of movement is lost), nobody is connected (the gateway's sockets died with the server), so the keep-alive and visibility bookkeeping starts clean.  Idempotent: rows that exist are kept.
create or replace function mc.live_restore() returns int language plpgsql as $$
declare n int;
begin
    insert into mc.player_live (uuid, conn_id, entity_id, x, y, z, yaw, pitch, on_ground, chunk_x, chunk_z, vis_dirty, sent_qx, sent_qy, sent_qz, sent_yaw, sent_pitch, last_sent_tick,
                                keepalive_id, keepalive_sent_tick, latency_ms, snapshot_x, snapshot_y, snapshot_z)
    select uuid, null, null, x, y, z, yaw, pitch, on_ground, chunk_x, chunk_z, false, sent_qx, sent_qy, sent_qz, sent_yaw, sent_pitch, last_sent_tick, null, null, latency_ms, x, y, z
      from mc.player
    on conflict (uuid) do nothing;
    get diagnostics n = row_count;
    update mc.player set conn_id = null, entity_id = null where conn_id is not null or entity_id is not null;       -- the sessions that held them are gone
    return n;
end $$;

create or replace function mc.live_state_disable() returns void language plpgsql as $$
begin
    if to_regclass('mc.player_live') is null then return; end if;
    perform mc.live_snapshot();
    drop view if exists mc.player_state;
    drop table mc.player_live;
end $$;
