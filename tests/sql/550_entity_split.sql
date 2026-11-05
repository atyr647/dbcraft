-- The entity simulation on its own connection (sql/550).  Two REAL connections, not an emulation: tests/sql/550_split_driver.sh runs A (clock, block changes, mc.entity_step) and B
-- (mc.entity_tick) as separate psql sessions with their own transactions.
--   A  DETERMINISM: the same scenario (walking cows and zombies, two stacks to pick up, a sleeping item woken by a block change) run in inline mode (one connection) and in split mode
--      with B in lockstep (B's tick k right after A's tick k) ends in the same entity states and the same packets for every viewer (multiset: the order of rows across the two
--      connections differs by construction, the bytes do not)
--   B  OWNERSHIP: a pickup in split mode is a request of B and a grant of A: the inventory changes on A's tick, the item row disappears on B's next tick, nobody else wrote either
--   C  a block change in split mode is a command row (the trigger does not touch B's rows) and B applies it
--   D  the TRUNCATE of mc.play_out every 20th tick would wait for B's open transaction and is skipped in split mode (a real second connection holds an uncommitted INSERT)
--   E  mc.entity_step / the mode setting: off does nothing, errors are logged and never fatal
-- (docs/PERF-IDLE2.md) the tick truncates its queues once a second only above dbcraft.tick-truncate-bytes (default 256 KiB); this file tests the truncation itself, on tiny queues, so it asks for the old behaviour
update mc.server_property set value = '0' where key = 'dbcraft.tick-truncate-bytes';
\! python3 tools/load_world_ref.py >/dev/null
select mc.block_class_refresh();

create or replace function t.split(b bytea) returns setof bytea language plpgsql as $$
declare off int := 0; r record;
begin
    while off < octet_length(b) loop
        select * into r from proto.varint_read(b, off);
        return next substring(b from off + 1 for (r.nxt - off) + r.val);
        off := r.nxt + r.val;
    end loop;
end $$;

select set_config('dbcraft.entity_spawner', 'off', false);
delete from mc.chunk where dimension = 'minecraft:overworld' and cx between -4 and 4 and cz between -4 and 4;
select mc.generate_flat('minecraft:overworld', cx, cz) from generate_series(-4, 4) cx, generate_series(-4, 4) cz;
-- (the spawner is a database-level choice for the B sessions of the driver too)
alter database :"DBNAME" set dbcraft.entity_spawner = 'off';

-- the scenario: players A (chunk 0,0) and B (chunk 1,0), six walking mobs, a stack of 3 stone at A's feet, a stack of 5 stone at B's feet, a sleeping stack at (-30.5, -60, 0.5)
create or replace function t.setup(p_mode text) returns void language plpgsql as $$
begin
    update mc.server_property set value = p_mode where key = 'dbcraft.entity-mode';      -- first: the grass blocks below fire the trigger of the mode that is set
    delete from mc.entity; delete from mc.entity_lane; delete from mc.play_out; delete from mc.entity_cell_viewer; delete from mc.entity_viewer_cell; delete from mc.player;
    delete from mc.entity_floor; delete from mc.solid_mask; delete from mc.inventory_slot; delete from mc.entity_cmd; delete from mc.entity_pickup_req; delete from mc.block_event;
    perform mc.set_block('minecraft:overworld', -30 + dx, -61, 0 + dz, 'minecraft:grass_block') from generate_series(-1, 1) dx, generate_series(-1, 1) dz;
    perform mc.entity_build_mask('minecraft:overworld', cx, cz, sy) from generate_series(-4, 4) cx, generate_series(-4, 4) cz, generate_series(-4, -1) sy;
    update mc.server_property set value = '3' where key = 'view-distance';
    update mc.server_property set value = p_mode where key = 'dbcraft.entity-mode';
    delete from mc.entity_cmd;
    update mc.game_state set game_time = 0;
    insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values
        ('00000000-0000-0000-0000-00000000000a', 'A', 1, 901, 0.5, -60, 0.5, 0, 0, 0),
        ('00000000-0000-0000-0000-00000000000b', 'B', 2, 902, 24.5, -60, 0.5, 1, 0, 0);
    insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, gx, gz, goal_until, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz, yaw)
    select v.id, ('00000000-0000-0000-0000-0000000' || lpad(v.id::text, 5, '0'))::uuid, v.tp, mc.entity_type_id(v.tp), v.x, -60, v.z, true, v.id % 3, 0, floor(v.x / 16)::int, floor(v.z / 16)::int,
           v.gx, v.gz, v.goal, 0, 0, 0, 0, 0, 0, v.id
      from (values (8001, 'minecraft:cow', 5.5, 5.5, 0.1, 0.0, 40), (8002, 'minecraft:cow', -9.5, 3.5, 0.0, 0.1, 25), (8003, 'minecraft:cow', 20.5, -6.5, -0.08, 0.06, 50),
                   (8004, 'minecraft:zombie', 40.5, 8.5, -0.1, 0.0, 30), (8005, 'minecraft:zombie', -20.5, 12.5, 0.1, 0.1, 20), (8006, 'minecraft:cow', 12.5, 12.5, 0.0, 0.0, 6)) v(id, tp, x, z, gx, gz, goal);
    insert into mc.entity (id, uuid, type, type_id, x, y, z, vx, vy, vz, on_ground, born_tick, phys_tick, cx, cz, deep_sleep, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz, pickup_at, data)
    select v.id, ('00000000-0000-0000-0000-0000000' || lpad(v.id::text, 5, '0'))::uuid, 'minecraft:item', mc.entity_type_id('minecraft:item'), v.x, -60, v.z, 0, 0, 0, true, -100, 0, floor(v.x / 16)::int, floor(v.z / 16)::int,
           v.asleep, 1, floor(v.x / 16)::int, floor(v.z / 16)::int, round(v.x * 4096), round(-60 * 4096.0), round(v.z * 4096), 0, jsonb_build_object('item', 'minecraft:stone', 'count', v.cnt)
      from (values (7001, 0.9, 0.5, 3, false), (7002, 24.9, 0.5, 5, false), (7003, -30.5, 0.5, 2, true)) v(id, x, z, cnt, asleep);
end $$;

-- A's tick k: the clock, the scripted block change (tick 4: the floor under the sleeping stack goes away), the hook of mc.server_tick.  Commits (autocommit of the calling session).
create or replace function t.a_tick(k int) returns void language plpgsql as $$
begin
    update mc.game_state set game_time = k;
    if k = 4 then
        perform mc.set_block('minecraft:overworld', -30 + dx, -61, 0 + dz, 'minecraft:air') from generate_series(-1, 1) dx, generate_series(-1, 1) dz;
    end if;
    perform mc.entity_step(k);
end $$;

-- everything that describes the world of the entities after tick 24 (lane mobs at their live position), and the packets the viewers got as a multiset
create or replace function t.entity_digest() returns text language sql as $$
  select md5(string_agg(concat_ws('|', e.id, e.type, mc.quant(case when e.lane_until > 0 then e.x + e.gx * greatest(24 - e.phys_tick, 0) else e.x end), mc.quant(e.y),
                                  mc.quant(case when e.lane_until > 0 then e.z + e.gz * greatest(24 - e.phys_tick, 0) else e.z end), e.on_ground, e.deep_sleep, e.cx, e.cz, e.data::text), ',' order by e.id))
    from mc.entity e $$;
create or replace function t.packet_digest() returns text language sql as $$
  select md5(string_agg(q.conn || ':' || encode(q.pkt, 'hex') || ':' || q.n, ',' order by q.conn, q.pkt))
    from (select o.conn_id as conn, p.pkt, count(*) as n from mc.play_out o cross join lateral t.split(o.data) p(pkt) group by 1, 2) q $$;

------------------------------------------------------------------------------------------------ A  determinism, inline vs two connections in lockstep
select t.setup('inline');
select t.a_tick(k) from generate_series(1, 24) k;
drop table if exists t.inl;
create table t.inl as select t.entity_digest() as ed, t.packet_digest() as pd, (select count(*) from mc.entity) as n_ent,
       (select string_agg(slot || ':' || item || ':' || count, ',' order by player, slot) from mc.inventory_slot) as inv,
       (select count(*) from mc.play_out) as rows_out, (select count(*) from mc.entity_lane) as lanes;
select t.is_true('A: the inline run did something: lanes exist, the stacks at A and B were collected (3 + 5 stone in the inventories), the woken stack fell',
                 (select lanes > 0 and inv = '36:minecraft:stone:3,36:minecraft:stone:5' and n_ent = 7 from t.inl));
select t.is_true('A: ... and the sleeping stack woke on the block change and fell through the hole (y below -60.5; it may sleep again once landed)', (select y < -60.5 from mc.entity where id = 7003));

select t.setup('split');
\! bash tests/sql/550_split_driver.sh 24
select t.is_true('A: both runs have the same entities in the same state after 24 ticks (positions to 1/4096, chunk cells, sleep, data)', (select t.entity_digest() = ed from t.inl));
select t.eq('A: the inventories are the same', (select string_agg(slot || ':' || item || ':' || count, ',' order by player, slot) from mc.inventory_slot), (select inv from t.inl));
select t.eq('A: every viewer received exactly the same packets (multiset, byte for byte: mob moves, appearances, take_item_entity, slot updates, removals)', t.packet_digest(), (select pd from t.inl));
select t.is_true('A: the split run left no command or request behind (all applied)', not exists (select 1 from mc.entity_cmd) and not exists (select 1 from mc.entity_pickup_req));

------------------------------------------------------------------------------------------------ B  a pickup across the two connections
select t.setup('split');
update mc.game_state set game_time = 2;
select set_config('dbcraft.entity_tick', '1', false);
select mc.entity_tick(2);                       -- B's tick 2 (this session plays B): player B (entity id 902) is on the 4-tick phase (902 + 2) % 4 = 0
select t.eq('B: B filed one request (stack 7002 for player B) and did not touch the inventory or the entity', (select count(*)::int from mc.entity_pickup_req where item_id = 7002 and peid = 902), 1);
select t.is_true('B: the item row is still there, its pickup_at pushed 20 ticks ahead (nobody else can request it meanwhile)', (select pickup_at = 22 from mc.entity where id = 7002));
select t.is_true('B: the inventory is untouched', not exists (select 1 from mc.inventory_slot));
select mc.entity_step(3);                       -- A's tick 3 grants
select t.eq('B: A granted: 5 stone in player B''s first hotbar slot', (select slot || ':' || count from mc.inventory_slot where player = '00000000-0000-0000-0000-00000000000b'), '36:5');
select t.is_true('B: A sent the collector take_item_entity + the slot update (and nothing about removing the item: that is B''s)',
                 (select count(*) = 1 from mc.play_out where conn_id = 2 and position(mc.cb('take_item_entity', proto.varint(7002) || proto.varint(902) || proto.varint(5)) in data) = 1));
select t.eq('B: A filed a discard for B', (select count(*)::int from mc.entity_cmd where kind = 'discard' and id = 7002 and n = 5), 1);
select t.is_true('B: and the item is still in the table (A never writes an entity)', exists (select 1 from mc.entity where id = 7002));
select mc.entity_tick(3);                       -- B's tick 3 applies the discard first
select t.is_true('B: B removed the item on its next tick, and the command is gone', not exists (select 1 from mc.entity where id = 7002) and not exists (select 1 from mc.entity_cmd where kind = 'discard'));
-- a request for an item that is no longer there / a player that left grants nothing
delete from mc.entity_pickup_req;      -- (B's tick 3 also filed the request of player A for stack 7001: not what this check is about)
insert into mc.entity_pickup_req (tick, item_id, uuid, peid) values (3, 7002, '00000000-0000-0000-0000-00000000000b', 902), (3, 7001, '00000000-0000-0000-0000-0000000000ff', 901);
select t.eq('B: requests for a vanished item or a departed player grant nothing', mc.entity_apply_events(4), 0);
-- a stack that does not fit: nothing granted, the item stays and can be requested again later
delete from mc.inventory_slot;
insert into mc.inventory_slot (player, slot, item, count) select '00000000-0000-0000-0000-00000000000a', s, 'minecraft:dirt', 64 from generate_series(9, 44) s;
insert into mc.entity_pickup_req (tick, item_id, uuid, peid) values (4, 7001, '00000000-0000-0000-0000-00000000000a', 901);
select t.eq('B: a full inventory: the request is dropped, nothing granted', mc.entity_apply_events(5), 0);
select t.is_true('B: ... and the item stays', exists (select 1 from mc.entity where id = 7001));

------------------------------------------------------------------------------------------------ C  a block change is a command in split mode, applied by B
select t.setup('split');
select mc.entity_tick(1);
select mc.set_block('minecraft:overworld', -30 + dx, -61, 0 + dz, 'minecraft:air') from generate_series(-1, 1) dx, generate_series(-1, 1) dz;
select t.is_true('C: the trigger left the sleeping stack alone (A writes no entity row) and filed wake commands', (select deep_sleep from mc.entity where id = 7003) and (select count(*) > 0 from mc.entity_cmd where kind = 'wake'));
select set_config('dbcraft.entity_tick', '1', false);
select mc.entity_tick(2);
select t.is_true('C: B woke it at the start of its next tick, the commands are gone', (select not deep_sleep from mc.entity where id = 7003) and not exists (select 1 from mc.entity_cmd));
select t.setup('inline');
select mc.entity_tick(1);
select mc.set_block('minecraft:overworld', -30 + dx, -61, 0 + dz, 'minecraft:air') from generate_series(-1, 1) dx, generate_series(-1, 1) dz;
select t.is_true('C: in the other modes the trigger wakes it at once, as before, and files nothing', (select not deep_sleep from mc.entity where id = 7003) and not exists (select 1 from mc.entity_cmd));

------------------------------------------------------------------------------------------------ D  TRUNCATE of mc.play_out vs a second connection's open transaction
-- the server tick at game time 19 -> 20 would TRUNCATE mc.play_out; a second session holds an uncommitted INSERT into it for four seconds
create or replace function t.tick_at_20(p_mode text) returns text language plpgsql as $$
begin
    update mc.server_property set value = p_mode where key = 'dbcraft.entity-mode';
    delete from mc.tick_log; delete from mc.server_tick_log;        -- (a tick number that was logged before makes mc.tick fail)
    update mc.game_state set game_time = 19;
    perform set_config('lock_timeout', '1000ms', true);
    perform mc.server_tick();
    return 'ok';
exception when lock_not_available then return 'blocked';
end $$;
\! (psql -X -q -c "begin; insert into mc.play_out (conn_id, data) values (99, '\\x00'); select pg_sleep(4); commit;" > /dev/null 2>&1 &)
select pg_sleep(1);
select t.eq('D: inline mode: the TRUNCATE of mc.play_out waits for the other connection (the hazard exists)', t.tick_at_20('inline'), 'blocked');
select t.eq('D: split mode: the tick does not truncate, it goes through while the other connection holds its row', t.tick_at_20('split'), 'ok');
select pg_sleep(3);

------------------------------------------------------------------------------------------------ E  the mode setting and the hook
update mc.server_property set value = 'off' where key = 'dbcraft.entity-mode';
select t.setup('off');
delete from mc.entity_tick_log;
select mc.entity_step(9001);
select t.is_true('E: mode off: mc.entity_step does nothing (no entity tick happened)', not exists (select 1 from mc.entity_tick_log where tick = 9001));
update mc.server_property set value = 'inline' where key = 'dbcraft.entity-mode';
select mc.entity_spawn('minecraft:item', 0.5, -59.0, 0.5, p_tick => 9006);          -- (with no entity row at all the tick is empty and returns early: sql/550, tests/sql/1010)
select mc.entity_step(9007);
select t.is_true('E: inline mode: mc.entity_step runs the entity tick', exists (select 1 from mc.entity_tick_log where tick = 9007));
update mc.server_property set value = 'bogus' where key = 'dbcraft.entity-mode';
select mc.entity_step(9008);
select t.is_true('E: an unknown mode value behaves like off (nothing ran)', not exists (select 1 from mc.entity_tick_log where tick = 9008));
update mc.server_property set value = 'off' where key = 'dbcraft.entity-mode';
select t.is_true('E: the default stays off in a fresh migration', (select default_value = 'off' from mc.server_property where key = 'dbcraft.entity-mode'));
