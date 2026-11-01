-- Entity tracker, interest relation, pickup, despawn, AI and spawner (sql/520, 530).  The spawn packets are compared with bytes captured from the real 26.3 server
-- (a thrown stack of 3 stone: add_entity + set_entity_data, entity id 26, uuid 6a9e84b8-580a-4a08-ab5f-aebae926ee6f), and the tracker's cadence with the packets vanilla
-- sent for that item (motion + position sync at tick 20, a forced sync at tick 60).
\! python3 tools/load_world_ref.py >/dev/null

create or replace function t.frame_names(b bytea) returns text[] language plpgsql as $$
declare o int := 0; o2 int; ln int; pid int; r record; res text[] := '{}';
begin
    while o < length(b) loop
        select * into r from proto.varint_read(b, o); ln := r.val; o2 := r.nxt;
        select * into r from proto.varint_read(b, o2); pid := r.val;
        res := res || replace(net.pkt_name('play', 'clientbound', pid), 'minecraft:', '');
        o := o2 + ln;
    end loop;
    return res;
end $$;

-- a flat world around the origin, masks built, two players: A at the origin, B 10 chunks away (view distance 3: they do not overlap)
delete from mc.entity; delete from mc.play_out; delete from mc.entity_cell_viewer; delete from mc.entity_viewer_cell; delete from mc.solid_mask; delete from mc.player;
update mc.server_property set value = '3' where key = 'view-distance';
delete from mc.chunk where dimension = 'minecraft:overworld' and cx between -4 and 4 and cz between -4 and 4;
select mc.generate_flat('minecraft:overworld', cx, cz) from generate_series(-4, 4) cx, generate_series(-4, 4) cz;
select mc.entity_build_mask('minecraft:overworld', cx, cz, sy) from generate_series(-4, 4) cx, generate_series(-4, 4) cz, generate_series(-4, -1) sy;
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values
    ('00000000-0000-0000-0000-00000000000a', 'A', 1, 901, 0.5, -60, 0.5, 0, 0, 0), ('00000000-0000-0000-0000-00000000000b', 'B', 2, 902, 160.5, -60, 0.5, 10, 0, 0);

------------------------------------------------------------------------------------------------ spawn packets = the captured bytes
insert into mc.entity (id, uuid, type, type_id, x, y, z, vx, vy, vz, born_tick, phys_tick, cx, cz, data)
values (26, '6a9e84b8-580a-4a08-ab5f-aebae926ee6f', 'minecraft:item', mc.entity_type_id('minecraft:item'), -4.5, -58, -4.5, 0.2, 0.3, 0.1, 100, 100, -1, -1, '{"item":"minecraft:stone","count":3}');
select t.eq('item type id is the captured 0x48', mc.entity_type_id('minecraft:item'), 72);
select mc.entity_viewers_refresh(100);
select t.eq('player A sees 7x7 chunk cells (view distance 3)', (select count(*)::int from mc.entity_cell_viewer where conn_id = 1), 49);
select t.eq('player B sees its own 49 cells', (select count(*)::int from mc.entity_cell_viewer where conn_id = 2), 49);
select mc.entity_tracker(100, '{}');
select t.eq('the item appears for A with the bytes of vanilla (add_entity + set_entity_data, same fields)',
            (select encode(data, 'hex') from mc.play_out where conn_id = 1),
            '35011a6a9e84b8580a4a08ab5faebae926ee6f48c012000000000000c04d000000000000c01200000000000061668ccb4cca00000000' || '09651a080703010000ff');
select t.eq('B, far away, is told nothing', (select count(*)::int from mc.play_out where conn_id = 2), 0);
select t.eq('the item is now announced (sent-state base = where it is)', (select (last_sent_tick, sent_qx, sent_qy, sent_qz)::text from mc.entity where id = 26), '(100,-18432,-237568,-18432)');

------------------------------------------------------------------------------------------------ interest relation: leaving and entering the view
delete from mc.play_out;
update mc.player set x = 48.5, chunk_x = 3 where entity_id = 901;                -- the item (chunk -1) is now 4 chunks away: out of A's view of 3
select mc.entity_viewers_refresh(101);
select t.eq('crossing a chunk border moves the view: 49 cells still', (select count(*)::int from mc.entity_cell_viewer where conn_id = 1), 49);
select t.eq('the item leaves A''s view: one remove_entities for it', (select encode(data, 'hex') from mc.play_out where conn_id = 1), encode(mc.pkt_remove_entities(array[26]), 'hex'));
delete from mc.play_out;
update mc.player set x = 0.5, chunk_x = 0 where entity_id = 901;
select mc.entity_viewers_refresh(102);
select t.eq('walking back: the item appears again (the same add_entity + data)',
            (select encode(data, 'hex') from mc.play_out where conn_id = 1),
            '35011a6a9e84b8580a4a08ab5faebae926ee6f48c012000000000000c04d000000000000c01200000000000061668ccb4cca00000000' || '09651a080703010000ff');
delete from mc.player where entity_id = 902;
select mc.entity_viewers_refresh(102);
select t.eq('a player that disconnects loses all its cells', (select count(*)::int from mc.entity_cell_viewer where conn_id = 2) + (select count(*)::int from mc.entity_viewer_cell where conn_id = 2), 0);

------------------------------------------------------------------------------------------------ the cadence of vanilla for that item: ticks 20 and 60
delete from mc.play_out;
create temp table lg (tick int, names text[]);
do $$
declare t bigint; ids int[]; nm text[];
begin
    for t in 101..170 loop
        perform mc.entity_viewers_refresh(t);
        ids := mc.entity_physics_ids(t);
        perform mc.entity_tracker(t, ids);
        select t.frame_names(string_agg(data, ''::bytea order by seq)) into nm from mc.play_out where conn_id = 1;
        if cardinality(nm) > 0 then insert into lg values ((t - 100)::int, nm); end if;
        delete from mc.play_out;
    end loop;
end $$;
select 'timeline of the tracked item (ticks after spawn, packets to player A): ' || coalesce(string_agg(tick || ':' || array_to_string(names, '+'), '  ' order by tick), '(none)') as timeline from lg;
select t.eq('tick 20 (tracker interval): set_entity_motion then entity_position_sync, in the order vanilla sent them', (select names from lg where tick = 20), array['set_entity_motion', 'entity_position_sync']);
-- DEVIATION (docs/ENTITY.md): vanilla also sends a forced sync at tick 60 and a wobbling set_entity_motion every 20 ticks for an item at rest; a deep-sleeping item sends nothing
select t.is_true('the item sleeps by tick 60 and so sends nothing then (vanilla would send a sync: deliberate bandwidth saving)', not exists (select 1 from lg where tick >= 45));
select t.is_true('every packet the item produced after its spawn is one of motion / position sync / move (never an add or a remove while it stays in view)',
                 not exists (select 1 from lg where names && array['add_entity', 'remove_entities']));
select t.is_true('nothing is sent between the intervals (ticks 1-19)', not exists (select 1 from lg where tick between 1 and 19));
select t.is_true('the item came to rest and sleeps deeply', (select deep_sleep and on_ground from mc.entity where id = 26));
select t.is_true('at rest the position of the entity equals what the clients were told (within one quantum)',
                 (select abs(sent_qx - mc.quant(x)) <= 1 and abs(sent_qy - mc.quant(y)) <= 1 and abs(sent_qz - mc.quant(z)) <= 1 from mc.entity where id = 26));

------------------------------------------------------------------------------------------------ deep sleep wakes when the block below changes
select mc.set_block('minecraft:overworld', floor(x)::int + dx, floor(y - 0.5)::int, floor(z)::int + dz, 'minecraft:air') from mc.entity, generate_series(-1, 1) dx, generate_series(-1, 1) dz where id = 26;   -- the 3x3 under it (a 0.25 wide item can straddle two blocks)
select t.is_true('removing the blocks under a sleeping item wakes it (trigger on the block event)', (select not deep_sleep from mc.entity where id = 26));
do $$ begin for t in 171..200 loop perform mc.entity_physics(t); end loop; end $$;
select t.is_true('...and it falls into the hole (below the old floor)', (select y < -60.5 from mc.entity where id = 26));

------------------------------------------------------------------------------------------------ pickup
delete from mc.entity; delete from mc.play_out; delete from mc.inventory_slot;
update mc.player set x = -4.5, z = -4.5, chunk_x = -1, chunk_z = -1 where entity_id = 901;
select mc.entity_viewers_refresh(300);
select mc.entity_spawn('minecraft:item', -4.5, -60, -4.5, 0, 0, 0, 290, '{"item":"minecraft:stone","count":3}') as e1 \gset
select mc.entity_tracker(300, '{}');
delete from mc.play_out;
select t.eq('pickup happens on the tick when (player entity id + tick) % 4 = 0: tick 303 for entity id 901', mc.entity_pickup(300), 0);
select t.eq('...collected at tick 303', mc.entity_pickup(303), 1);
select t.eq('the stone is in the first hotbar slot with count 3', (select (slot, item, count)::text from mc.inventory_slot where player = '00000000-0000-0000-0000-00000000000a'), '(36,minecraft:stone,3)');
select t.is_true('the item entity is gone', not exists (select 1 from mc.entity));
select t.is_true('the collector gets take_item_entity (entity, collector 901, 3), a slot update and remove_entities',
                 (select t.frame_names(string_agg(data, ''::bytea order by seq)) = array['take_item_entity', 'container_set_slot', 'remove_entities'] from mc.play_out where conn_id = 1));
select t.is_true('take_item_entity is [item entity id][collector id 901][amount 3] and comes first',
                 (select position(mc.cb('take_item_entity', proto.varint(:e1) || proto.varint(901) || proto.varint(3)) in string_agg(data, ''::bytea order by seq)) = 1 from mc.play_out where conn_id = 1));
select mc.entity_spawn('minecraft:item', -4.5, -60, -4.5, 0, 0, 0, 400, '{"item":"minecraft:stone","count":64}');
update mc.inventory_slot set count = 63 where slot = 36;
select t.eq('a stack still inside its 10-tick pickup delay is not collected (tick 403)', mc.entity_pickup(403), 0);
select mc.entity_pickup(411);
select t.eq('a stack of 64 into a slot holding 63: that slot fills to 64, the next free hotbar slot gets the remaining 63',
            (select string_agg(slot || ':' || count, ',' order by slot) from mc.inventory_slot), '36:64,37:63');

------------------------------------------------------------------------------------------------ despawn
delete from mc.entity; delete from mc.play_out;
select mc.entity_spawn('minecraft:item', 2.5, -60, 2.5, 0, 0, 0, 0, '{"item":"minecraft:stone","count":1}');
select mc.entity_spawn('minecraft:item', 3.5, -60, 3.5, 0, 0, 0, 5990, '{"item":"minecraft:stone","count":1}');
select mc.entity_despawn(6000);
select t.eq('an item older than 6000 ticks despawns, a younger one stays', (select count(*)::int from mc.entity), 1);
select t.eq('nothing happens off the 20-tick beat', mc.entity_despawn(6001), 0);

------------------------------------------------------------------------------------------------ AI goals and the spawner
delete from mc.entity; delete from mc.play_out;
update mc.player set x = 0.5, z = 0.5, chunk_x = 0, chunk_z = 0 where entity_id = 901;
insert into mc.entity (id, uuid, type, type_id, x, y, z, born_tick, phys_tick, cx, cz, goal_until, deep_sleep, on_ground)
values (700, gen_random_uuid(), 'minecraft:zombie', mc.entity_type_id('minecraft:zombie'), 8.5, -60, 0.5, 0, 0, 0, 0, 1, true, true),
       (701, gen_random_uuid(), 'minecraft:cow', mc.entity_type_id('minecraft:cow'), 4.5, -60, 4.5, 0, 0, 0, 0, 1, true, true);
select mc.entity_ai(105);       -- (700 + 105) % 5 = 0: the zombie looks for a player
select t.is_true('a zombie 8 blocks from a player walks toward them (-x) at its walk speed',
                 (select gx < -0.12 and gx > -0.14 and abs(gz) < 1e-9 and goal_until = 110 and not deep_sleep from mc.entity where id = 700));
select t.is_true('a cow whose goal ran out has a new one (it walks or stands) and is awake', (select goal_until > 105 and not deep_sleep from mc.entity where id = 701));
insert into mc.entity (id, uuid, type, type_id, x, y, z, born_tick, phys_tick, cx, cz, goal_until, deep_sleep, on_ground)
values (705, gen_random_uuid(), 'minecraft:zombie', mc.entity_type_id('minecraft:zombie'), 40.5, -60, 0.5, 0, 0, 2, 0, 1, true, true);
select mc.entity_ai(110);       -- (705 + 110) % 5 = 0: a zombie 40 blocks away does not chase (out of the 16-block range)
select t.is_true('a zombie 40 blocks away is not chasing (its goal is a wander goal, not the 5-tick chase goal)', (select goal_until <> 115 from mc.entity where id = 705));
delete from mc.entity;
select t.eq('the spawner places one mob for a player with none around on its beat ((901 + 19) % 40 = 0)', mc.entity_spawner(19), 1);
select t.is_true('...16 to 32 blocks away, a cow or a zombie', (select abs(x - 0.5) between 16 and 32 and abs(z - 0.5) between 16 and 32 and type in ('minecraft:cow', 'minecraft:zombie') from mc.entity));
delete from mc.entity;
select mc.entity_spawn('minecraft:cow', 1 + g, -60, 1, 0, 0, 0, 0) from generate_series(1, 8) g;
select t.eq('the spawner leaves a player with 8 mobs within 3 chunks alone', mc.entity_spawner(59), 0);

delete from mc.entity; delete from mc.play_out; delete from mc.entity_cell_viewer; delete from mc.entity_viewer_cell; delete from mc.player;
