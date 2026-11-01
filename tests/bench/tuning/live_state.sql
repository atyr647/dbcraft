-- State tiering for per-player live state: three layouts of the rows the tick updates every tick, same update pattern, measured side by side.
--   wide          the status quo: everything in mc.player (35 columns; fillfactor 60; its real indexes)
--   hot_logged    a narrow LOGGED table with only the fast-changing columns (fillfactor 60, no index on a changed column, so updates stay HOT)
--   hot_unlogged  the same narrow table UNLOGGED (no WAL) plus a durable snapshot into the wide table every p_snap_every ticks
-- The update pattern is the one in sql/340_game_input.sql / 330_game_players.sql: per tick, for each mover (a random fraction): (6) x y z yaw pitch on_ground chunk_x chunk_z vis_dirty,
-- (7) the "what the viewers were last told" bookkeeping sent_qx..last_sent_tick; the vis_dirty clear; every 300 ticks (15 s) the keep-alive columns for everybody and the answer on the
-- next tick.  Run by tests/bench/tuning/live_state.sh on a throwaway copy of the golden database.
create schema if not exists lv;

create or replace procedure lv.setup(p_variant text, p_n int) language plpgsql as $$
begin
    drop table if exists lv.player_wide, lv.player_hot, lv.fin cascade;
    -- the real table shape: columns, defaults, constraints and indexes of mc.player
    create table lv.player_wide (like mc.player including defaults including constraints including indexes) with (fillfactor = 60);
    create unlogged table lv.fin (conn_id int primary key, x float8, y float8, z float8, yaw real, pitch real);
    perform setseed(0.42);
    insert into lv.player_wide (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, vis_dirty, last_sent_tick)
    select md5(i::text)::uuid, 'bot' || i, i, i, px, -60, pz, (random() * 360)::real, 0, floor(px / 16)::int, floor(pz / 16)::int, (px * 4096)::bigint, (-60 * 4096)::bigint, (pz * 4096)::bigint, false, 0
      from (select i, random() * 1600 as px, random() * 1600 as pz from generate_series(1, p_n) i) g;
    if p_variant in ('hot_logged', 'hot_unlogged') then
        execute format('create %s table lv.player_hot (
            uuid uuid primary key, conn_id int, entity_id int,
            x float8, y float8, z float8, yaw real, pitch real, on_ground boolean, chunk_x int, chunk_z int, vis_dirty boolean,
            sent_qx bigint, sent_qy bigint, sent_qz bigint, sent_yaw real, sent_pitch real, last_sent_tick bigint,
            keepalive_id bigint, keepalive_sent_tick bigint, latency_ms int) with (fillfactor = 60)', case when p_variant = 'hot_unlogged' then 'unlogged' else '' end);
        create unique index player_hot_entity_idx on lv.player_hot (entity_id);
        create index player_hot_conn_idx on lv.player_hot (conn_id);
        insert into lv.player_hot select uuid, conn_id, entity_id, x, y, z, yaw, pitch, on_ground, chunk_x, chunk_z, vis_dirty, sent_qx, sent_qy, sent_qz, sent_yaw, sent_pitch,
                                         last_sent_tick, keepalive_id, keepalive_sent_tick, latency_ms from lv.player_wide;
    end if;
    analyze lv.player_wide;
    if p_variant <> 'wide' then analyze lv.player_hot; end if;
    commit;
end $$;

-- Runs p_ticks ticks at 20 Hz.  One transaction per tick like the gateway.  Returns per-tick milliseconds through lv.lat.
create table if not exists lv.lat (seq int primary key, ms float8, snap_ms float8);

create or replace procedure lv.run(p_variant text, p_ticks int, p_frac float8, p_snap_every int default 0) language plpgsql as $$
declare
    t0 timestamptz := clock_timestamp(); ta timestamptz; tb timestamptz; i int; deadline timestamptz; slp float8; hot boolean := p_variant <> 'wide';
    arr float8[] := '{}'; snap float8[] := '{}'; sms float8;
begin
    truncate lv.lat;
    for i in 1 .. p_ticks loop
        deadline := t0 + make_interval(secs => i * 0.05);
        ta := clock_timestamp();
        delete from lv.fin;
        if hot then
            insert into lv.fin select conn_id, x + (random() - 0.5) * 0.4, y, z + (random() - 0.5) * 0.4, yaw + 1, pitch from lv.player_hot where random() < p_frac;
            -- (6) apply
            update lv.player_hot p set x = f.x, y = f.y, z = f.z, yaw = f.yaw, pitch = f.pitch, on_ground = true,
                   chunk_x = floor(f.x / 16)::int, chunk_z = floor(f.z / 16)::int,
                   vis_dirty = p.vis_dirty or (floor(f.x / 16)::int <> p.chunk_x or floor(f.z / 16)::int <> p.chunk_z)
              from lv.fin f where p.conn_id = f.conn_id;
            -- (7) bookkeeping of what the viewers were told
            update lv.player_hot p set sent_qx = (p.x * 4096)::bigint, sent_qy = (p.y * 4096)::bigint, sent_qz = (p.z * 4096)::bigint, sent_yaw = p.yaw, sent_pitch = p.pitch, last_sent_tick = i
              from lv.fin f where p.conn_id = f.conn_id;
            update lv.player_hot set vis_dirty = false where vis_dirty;
            if i % 300 = 0 then update lv.player_hot set keepalive_id = i, keepalive_sent_tick = i; end if;
            if i % 300 = 1 then update lv.player_hot set latency_ms = ((coalesce(latency_ms, 0) * 3 + ((i - keepalive_sent_tick) * 50)::int) / 4), keepalive_id = null where keepalive_id is not null; end if;
        else
            insert into lv.fin select conn_id, x + (random() - 0.5) * 0.4, y, z + (random() - 0.5) * 0.4, yaw + 1, pitch from lv.player_wide where random() < p_frac;
            update lv.player_wide p set x = f.x, y = f.y, z = f.z, yaw = f.yaw, pitch = f.pitch, on_ground = true,
                   chunk_x = floor(f.x / 16)::int, chunk_z = floor(f.z / 16)::int,
                   vis_dirty = p.vis_dirty or (floor(f.x / 16)::int <> p.chunk_x or floor(f.z / 16)::int <> p.chunk_z)
              from lv.fin f where p.conn_id = f.conn_id;
            update lv.player_wide p set sent_qx = (p.x * 4096)::bigint, sent_qy = (p.y * 4096)::bigint, sent_qz = (p.z * 4096)::bigint, sent_yaw = p.yaw, sent_pitch = p.pitch, last_sent_tick = i
              from lv.fin f where p.conn_id = f.conn_id;
            update lv.player_wide set vis_dirty = false where vis_dirty;
            if i % 300 = 0 then update lv.player_wide set keepalive_id = i, keepalive_sent_tick = i; end if;
            if i % 300 = 1 then update lv.player_wide set latency_ms = ((latency_ms * 3 + ((i - keepalive_sent_tick) * 50)::int) / 4), keepalive_id = null where keepalive_id is not null; end if;
        end if;
        commit;
        tb := clock_timestamp();
        arr := arr || extract(epoch from tb - ta)::float8 * 1000;
        -- (a) the durable snapshot: positions of the players that moved since the last one
        sms := 0;
        if p_variant = 'hot_unlogged' and p_snap_every > 0 and i % p_snap_every = 0 then
            ta := clock_timestamp();
            update lv.player_wide w set x = h.x, y = h.y, z = h.z, yaw = h.yaw, pitch = h.pitch, on_ground = h.on_ground, chunk_x = h.chunk_x, chunk_z = h.chunk_z
              from lv.player_hot h where w.uuid = h.uuid and (w.x, w.z, w.y, w.yaw, w.pitch) is distinct from (h.x, h.z, h.y, h.yaw, h.pitch);
            commit;
            sms := extract(epoch from clock_timestamp() - ta)::float8 * 1000;
        end if;
        snap := snap || sms;
        slp := extract(epoch from deadline - clock_timestamp())::float8;
        if slp > 0.0005 then perform pg_sleep(slp); end if;
    end loop;
    insert into lv.lat select n, arr[n], snap[n] from generate_series(1, p_ticks) n;
    commit;
end $$;
