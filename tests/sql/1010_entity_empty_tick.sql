-- The empty entity tick (sql/550: mc.entity_tick returns at once when there is no entity row and nothing that could create one; sql/800: tick_quiet accepts inline mode with no entity).
-- docs/WHY-MOBS-COST.md.  What is proved here:
--   A  DIFFERENTIAL: the same 220-tick history (empty ticks, two cows and an item appear, are discarded, the world is empty again while the players MOVE, one leaves, one joins, then
--      three mobs and an item appear in view of the new positions) is run with the early exit on and with dbcraft.entity_empty_exit = off (the full tick).  Every play_out row of every
--      tick (viewer, bytes) is identical, and so are the final entity rows, lane rows and interest sets.
--   B  the exit is taken exactly when it may be: no entity and (spawner off, or nobody connected); with the prototype spawner on and a player connected the tick runs and spawns;
--      an entity row, a lane, a split-mode connection each make the tick run in full.  An empty tick writes no tick-log row and leaves the clock alone, and empties the interest sets once.
--   C  the first tick with an entity after a long empty period (the clock is behind, the interest sets are gone) announces the entity to exactly the players who can see it.
--   D  sql/800: mc.tick_quiet is true for inline mode with no entity row (and nobody connected), false with an entity row, false in split mode.
\! python3 tools/load_world_ref.py >/dev/null
select mc.block_class_refresh();
select set_config('dbcraft.entity_spawner', 'off', false);
delete from mc.chunk where dimension = 'minecraft:overworld' and cx between -8 and 8 and cz between -8 and 8;
select mc.generate_flat('minecraft:overworld', cx, cz) from generate_series(-8, 8) cx, generate_series(-8, 8) cz;
select mc.entity_build_mask('minecraft:overworld', cx, cz, sy) from generate_series(-8, 8) cx, generate_series(-8, 8) cz, generate_series(-4, -3) sy;
select mc.entity_floor_build('minecraft:overworld', cx, cz) from generate_series(-8, 8) cx, generate_series(-8, 8) cz;
update mc.server_property set value = '4' where key = 'view-distance';

create table t.pk (run text, tick int, conn int, h text, n int);
create table t.st (run text, what text, digest text);
create table t.lg (run text, ticks int, clock bigint);

create or replace function t.clear() returns void language plpgsql as $$
begin
    delete from mc.entity; delete from mc.entity_lane; delete from mc.play_out; delete from mc.entity_cell_viewer; delete from mc.entity_viewer_cell; delete from mc.player;
    delete from mc.entity_tick_log; update mc.entity_clock set last_tick = null;
    perform setval('mc.entity_id_seq', 9000);
end $$;

create or replace function t.cow(p_id int, p_cx int, p_cz int, p_tp text default 'minecraft:cow') returns void language sql as $$
    insert into mc.entity (id, uuid, type, type_id, x, y, z, vx, vy, vz, on_ground, born_tick, phys_tick, cx, cz, goal_until, yaw, data)
    values (p_id, md5('e' || p_id)::uuid, p_tp, mc.entity_type_id(p_tp), p_cx * 16 + 8.5, -60.0, p_cz * 16 + 8.5, 0, 0, 0, true, 0, 0, p_cx, p_cz, 1, 0, '{}')
$$;
create or replace function t.item(p_id int, p_cx int, p_cz int) returns void language sql as $$
    insert into mc.entity (id, uuid, type, type_id, x, y, z, vx, vy, vz, on_ground, born_tick, phys_tick, cx, cz, goal_until, yaw, data, pickup_at)
    values (p_id, md5('e' || p_id)::uuid, 'minecraft:item', mc.entity_type_id('minecraft:item'), p_cx * 16 + 8.5, -58.5, p_cz * 16 + 8.5, 0, 0, 0, false, 0, 0, p_cx, p_cz, 0, 0, '{"item":"minecraft:stone","count":1}', 100000)
$$;
create or replace function t.player(p_conn int, p_cx int, p_cz int) returns void language sql as $$
    insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values (md5('p' || p_conn)::uuid, 'P' || p_conn, p_conn, 900 + p_conn, p_cx * 16 + 0.5, -60, p_cz * 16 + 0.5, p_cx, p_cz, 1)
$$;

-- one tick and what it put into play_out, per viewer (bytes digested: the order of the rows of one viewer is part of the comparison)
create or replace function t.tick(p_run text, p_tick int) returns void language plpgsql as $$
begin
    perform mc.entity_tick(p_tick);
    insert into t.pk select p_run, p_tick, o.conn_id, md5(string_agg(encode(o.data, 'hex'), '' order by o.seq)), count(*)::int from mc.play_out o group by o.conn_id;
    delete from mc.play_out;
end $$;

-- the history
create or replace function t.history(p_run text, p_exit text) returns void language plpgsql as $$
declare k int;
begin
    perform t.clear();
    perform set_config('dbcraft.entity_empty_exit', p_exit, false);
    perform set_config('dbcraft.entity_spawner', 'off', false);
    perform t.player(1, 0, 0); perform t.player(2, 3, 0);
    for k in 1..10 loop perform t.tick(p_run, k); end loop;                                         -- empty
    perform t.cow(7001, 0, 0); perform t.cow(7002, 3, 0); perform t.item(7003, 1, 1); perform t.cow(7004, -4, -4);      -- 7004: in nobody's view
    for k in 11..80 loop perform t.tick(p_run, k); end loop;
    perform mc.entity_discard(array[7001, 7002, 7003, 7004]);                                        -- the removal packets are sent from the interest sets as they are
    insert into t.pk select p_run, 80, o.conn_id, md5(string_agg(encode(o.data, 'hex'), '' order by o.seq)), count(*)::int from mc.play_out o group by o.conn_id; delete from mc.play_out;
    for k in 81..120 loop
        if k = 90 then update mc.player set chunk_x = 5, chunk_z = 0, x = 5 * 16 + 0.5 where conn_id = 1; end if;         -- player 1 walks away while nothing exists
        if k = 95 then delete from mc.player where conn_id = 2; end if;                                                    -- player 2 leaves
        if k = 100 then perform t.player(3, -3, 2); end if;                                                                -- player 3 joins
        if k = 110 then update mc.player set chunk_x = -2, chunk_z = 2, x = -2 * 16 + 0.5, z = 2 * 16 + 0.5 where conn_id = 1; end if;      -- player 1 moves on (a jump of 7 chunks)
        perform t.tick(p_run, k);
    end loop;
    perform t.cow(7011, -3, 2); perform t.cow(7012, -2, 2); perform t.cow(7013, 5, 0); perform t.item(7014, -2, 3); perform t.cow(7015, 6, 6, 'minecraft:zombie');
    for k in 121..220 loop
        if k = 150 then update mc.player set chunk_x = -4, chunk_z = 3, x = -4 * 16 + 0.5, z = 3 * 16 + 0.5 where conn_id = 3; end if;
        perform t.tick(p_run, k);
    end loop;
    insert into t.st select p_run, 'entity', md5(string_agg(format('%s %s %s %s %s %s %s %s %s %s %s %s %s %s', e.id, e.x, e.y, e.z, e.vx, e.vz, e.cx, e.cz, e.gx, e.gz, e.goal_until, e.last_sent_tick, e.sent_qx, e.sent_qz), ';' order by e.id)) from mc.entity e;
    insert into t.st select p_run, 'lane', md5(coalesce(string_agg(format('%s %s %s %s %s %s %s %s %s', l.id, l.goal_until, l.t0, l.x0, l.z0, l.gx, l.gz, l.sqx, l.sqz), ';' order by l.id), '')) from mc.entity_lane l;
    insert into t.st select p_run, 'cell_viewer', md5(coalesce(string_agg(format('%s %s %s', v.cx, v.cz, v.conn_id), ';' order by v.cx, v.cz, v.conn_id), '')) from mc.entity_cell_viewer v;
    insert into t.st select p_run, 'viewer_cell', md5(coalesce(string_agg(format('%s %s %s %s', v.conn_id, v.cx, v.cz, v.r), ';' order by v.conn_id), '')) from mc.entity_viewer_cell v;
    insert into t.lg select p_run, (select count(*)::int from mc.entity_tick_log), (select last_tick from mc.entity_clock);
end $$;

------------------------------------------------------------------------------------------------ A  differential
select t.history('warm', 'on');           -- (a first history on a fresh database differs from every later one in the timing of the lanes - floor summaries and masks being built on first touch - exit or not; so: warm up first)
select t.history('full', 'off');
select t.history('exit', 'on');
select t.history('full_b', 'off');
select t.eq('A: the harness is deterministic: two runs of the full tick give the same play_out rows',
            (select count(*)::int from (select tick, conn, h, n from t.pk where run = 'full' except select tick, conn, h, n from t.pk where run = 'full_b') d)
          + (select count(*)::int from (select tick, conn, h, n from t.pk where run = 'full_b' except select tick, conn, h, n from t.pk where run = 'full') d), 0);
select t.is_true('A: the history is not vacuous (packets for both viewers, announcements, moves, removals; more than 80 (tick, viewer) rows)',
                 (select count(*) > 80 and count(distinct conn) >= 3 from t.pk where run = 'full'));
select t.eq('A: the early exit changes no play_out row of any tick for any viewer (tick, viewer, bytes, number of rows)',
            (select count(*)::int from (select tick, conn, h, n from t.pk where run = 'full' except select tick, conn, h, n from t.pk where run = 'exit') d)
          + (select count(*)::int from (select tick, conn, h, n from t.pk where run = 'exit' except select tick, conn, h, n from t.pk where run = 'full') d), 0);
select t.eq('A: ... and the same number of rows', (select count(*)::int from t.pk where run = 'full'), (select count(*)::int from t.pk where run = 'exit'));
select t.eq('A: final entity rows identical', (select digest from t.st where run = 'exit' and what = 'entity'), (select digest from t.st where run = 'full' and what = 'entity'));
select t.eq('A: final lane rows identical', (select digest from t.st where run = 'exit' and what = 'lane'), (select digest from t.st where run = 'full' and what = 'lane'));
select t.eq('A: final interest sets identical (cell -> viewers)', (select digest from t.st where run = 'exit' and what = 'cell_viewer'), (select digest from t.st where run = 'full' and what = 'cell_viewer'));
select t.eq('A: final interest sets identical (viewer -> cell)', (select digest from t.st where run = 'exit' and what = 'viewer_cell'), (select digest from t.st where run = 'full' and what = 'viewer_cell'));
select t.is_true('A: the mobs walked in lanes in this history (the comparison covers the lanes, not only the first tick)', (select count(*) >= 3 from mc.entity_lane));
select t.eq('A: the full tick wrote a tick-log row for each of the 220 ticks (the empty ones too)', (select ticks from t.lg where run = 'full'), 220);
select t.eq('A: the early exit wrote none for the 50 empty ticks (10 at the start, 40 after the discard): 170 rows', (select ticks from t.lg where run = 'exit'), 170);
select t.is_true('A: the clock of the exit run is the last tick (it ran again after the empty period)', (select clock from t.lg where run = 'exit') = 220 and (select clock from t.lg where run = 'full') = 220);

------------------------------------------------------------------------------------------------ B  when the exit is taken
select t.clear();
select set_config('dbcraft.entity_empty_exit', 'on', false);
select set_config('dbcraft.entity_spawner', 'off', false);
select t.player(1, 0, 0);
select mc.entity_tick(1);
select mc.entity_tick(2);
select t.eq('B: empty world, spawner off, a player connected: no tick-log row, clock untouched', (select count(*)::int from mc.entity_tick_log) || '/' || coalesce((select last_tick::text from mc.entity_clock), 'null'), '0/null');
select t.eq('B: ... and no interest set was built for the player', (select count(*)::int from mc.entity_viewer_cell) + (select count(*)::int from mc.entity_cell_viewer), 0);
select t.cow(7101, 0, 0);
select mc.entity_tick(3);
select t.eq('B: with a cow the tick runs in full (tick-log row, clock, interest sets: 81 cells of the view, one viewer)', (select count(*)::int from mc.entity_tick_log) || '/' || (select last_tick from mc.entity_clock) || '/' || (select count(*)::int from mc.entity_cell_viewer), '1/3/81');
delete from mc.play_out;
select mc.entity_discard(array[7101]);
select t.eq('B: the removal of the last entity reached the viewer from the interest sets (one row)', (select count(*)::int from mc.play_out where conn_id = 1), 1);
delete from mc.play_out;
select mc.entity_tick(4);
select t.eq('B: the next tick is empty again: the interest sets are emptied once, no new log row', (select count(*)::int from mc.entity_cell_viewer) + (select count(*)::int from mc.entity_viewer_cell) || '/' || (select count(*)::int from mc.entity_tick_log), '0/1');
-- the spawner on, a player connected: not empty-able, the spawner creates mobs (hash cadence: some tick in 1..40 for entity id 901)
select set_config('dbcraft.entity_spawner', 'on', false);
select t.clear();
select t.player(1, 0, 0);
select mc.entity_tick(k) from generate_series(1, 80) k;
select t.is_true('B: spawner on and a player connected: the ticks are not skipped (the spawner made mobs, the log has rows)', (select count(*) from mc.entity) > 0 and (select count(*) from mc.entity_tick_log) = 80);
select t.clear();
select mc.entity_tick(k) from generate_series(1, 5) k;
select t.eq('B: spawner on but nobody connected: skipped', (select count(*)::int from mc.entity_tick_log), 0);
select set_config('dbcraft.entity_spawner', 'off', false);
select t.clear();
select t.player(1, 0, 0);
select set_config('dbcraft.entity_empty_exit', 'off', false);
select mc.entity_tick(1);
select t.eq('B: dbcraft.entity_empty_exit = off runs the full tick', (select count(*)::int from mc.entity_tick_log), 1);
select set_config('dbcraft.entity_empty_exit', 'on', false);
-- split mode: the commands of the other connection are still consumed by an empty tick
select t.clear();
update mc.server_property set value = 'split' where key = 'dbcraft.entity-mode';
insert into mc.entity_cmd (kind, id, n) values ('setcount', 1, 1), ('discard', 2, 3);
select mc.entity_tick(1);
select t.eq('B: split mode: an empty entity tick consumes the commands queued by the player connection', (select count(*)::int from mc.entity_cmd), 0);
update mc.server_property set value = 'off' where key = 'dbcraft.entity-mode';

------------------------------------------------------------------------------------------------ C  the first entity after a long empty period
select t.clear();
select t.player(1, 0, 0); select t.player(2, 9, 9);
select mc.entity_tick(k) from generate_series(1, 500) k;
update mc.player set chunk_x = -6, chunk_z = 5, x = -6 * 16 + 0.5, z = 5 * 16 + 0.5 where conn_id = 1;          -- player 1 far from where it was, player 2 stays where nothing is
select t.cow(7201, -5, 5);
select mc.entity_tick(501);
select t.is_true('C: after 500 empty ticks and a long walk the cow is announced to player 1 (in view: its add_entity packet carries the uuid) and to nobody else',
                 exists (select 1 from mc.play_out where conn_id = 1 and position(uuid_send(md5('e7201')::uuid) in data) > 0) and (select count(*) from mc.play_out where conn_id = 2) = 0);
select t.eq('C: the first non-empty tick did not need the clock (null before): the clock is 501 now', (select last_tick from mc.entity_clock), 501::bigint);

------------------------------------------------------------------------------------------------ D  sql/800: the quiet tick
select t.clear();
truncate net.conn_ctl, net.conn, net.inbox, net.outbox, net.play_inbox, net.batch, mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor,
         mc.block_event, mc.chunk_wanted, net.auth_result, net.join_parked, mc.chunk_request;
update net.join_gate_state set active = false;
update mc.server_property set value = 'inline' where key = 'dbcraft.entity-mode';
select set_config('dbcraft.quiet_tick', 'on', false);
select set_config('dbcraft.quiet_mark', '', false);
select t.eq('D: inline mode, no entity, nobody connected: the tick is quiet', mc.tick_quiet(), true);
select t.cow(7301, 0, 0);
select set_config('dbcraft.quiet_mark', '', false);
select t.eq('D: inline mode with an entity row: not quiet', mc.tick_quiet(), false);
delete from mc.entity;
update mc.server_property set value = 'split' where key = 'dbcraft.entity-mode';
select set_config('dbcraft.quiet_mark', '', false);
select t.eq('D: split mode: not quiet (the entity connection and the pickup requests)', mc.tick_quiet(), false);
update mc.server_property set value = 'off' where key = 'dbcraft.entity-mode';
select set_config('dbcraft.quiet_mark', '', false);
select t.eq('D: mode off: quiet as before', mc.tick_quiet(), true);
select set_config('dbcraft.entity_spawner', 'off', false);
