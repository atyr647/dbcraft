-- Fan-out per chunk cell for lane mobs (sql/551): every viewer in range gets exactly the packets the per-mob rules say, no more and no fewer, in at most one play_out row;
-- the tracking-range probe that is skipped when the range is at least the view distance never lets a viewer out of range through.
--   A  view distance 12 (zombies 8 and cows 10 chunks are SHORTER than the view: the range check is made): four viewers at chunk distances 0, 3, 12 and far away
--   B  view distance 3 (every tracking range is at least the view: the probe is skipped)
--   C  the tracker for an entity that crosses a chunk border: viewers who lose it get exactly mc.pkt_remove_entities, who gain it exactly the appearance, who keep it the movement
--   D  the ranges and update intervals of mc.entity_type_param are the ones read from the 26.3 bytecode (EntityTypes / EntityType$Builder: default range 5, interval 3)
\! python3 tools/load_world_ref.py >/dev/null
select mc.block_class_refresh();

create or replace function t.clear() returns void language plpgsql as $$
begin
    delete from mc.entity; delete from mc.entity_lane; delete from mc.play_out; delete from mc.entity_cell_viewer; delete from mc.entity_viewer_cell; delete from mc.player;
    delete from mc.entity_floor; delete from mc.solid_mask;
    perform mc.entity_build_mask('minecraft:overworld', cx, cz, sy) from generate_series(-4, 4) cx, generate_series(-4, 4) cz, generate_series(-4, -1) sy;
end $$;
select t.clear();
select set_config('dbcraft.entity_spawner', 'off', false);
delete from mc.chunk where dimension = 'minecraft:overworld' and cx between -4 and 4 and cz between -4 and 4;
select mc.generate_flat('minecraft:overworld', cx, cz) from generate_series(-4, 4) cx, generate_series(-4, 4) cz;

-- the packets of a play_out row (varint length, id, body)
create or replace function t.split(b bytea) returns setof bytea language plpgsql as $$
declare off int := 0; r record;
begin
    while off < octet_length(b) loop
        select * into r from proto.varint_read(b, off);
        return next substring(b from off + 1 for (r.nxt - off) + r.val);
        off := r.nxt + r.val;
    end loop;
end $$;

-- four viewers: A at chunk (0, 0), B at (3, 0), C at (12, 0), D far away at (-40, 40); four mobs that walk +x at 0.1 blocks per tick inside their chunk
create or replace function t.scenario(p_view int) returns void language plpgsql as $$
begin
    perform t.clear();
    update mc.server_property set value = p_view::text where key = 'view-distance';
    insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values
        ('00000000-0000-0000-0000-00000000000a', 'A', 1, 901, 0.5, -60, 0.5, 0, 0, 0),
        ('00000000-0000-0000-0000-00000000000b', 'B', 2, 902, 3 * 16 + 0.5, -60, 0.5, 3, 0, 0),
        ('00000000-0000-0000-0000-00000000000c', 'C', 3, 903, 12 * 16 + 0.5, -60, 0.5, 12, 0, 0),
        ('00000000-0000-0000-0000-00000000000d', 'D', 4, 904, -40 * 16 + 0.5, -60, 40 * 16 + 0.5, -40, 40, 0);
    -- 6001 cow in chunk 0, 6002 zombie and 6003 cow in chunk 3, 6004 zombie in chunk 4, 6005 cow in chunk 0 as well (two mobs in one cell: one blob)
    insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, gx, gz, goal_until, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz, yaw)
    select v.id, gen_random_uuid(), v.tp, mc.entity_type_id(v.tp), v.x, -60, v.z, true, 0, 0, floor(v.x / 16)::int, 0, 0.1, 0, 60, 1, floor(v.x / 16)::int, 0,
           round(v.x * 4096), round(-60 * 4096.0), round(v.z * 4096), 0
      from (values (6001, 'minecraft:cow', 2.5, 8.5), (6002, 'minecraft:zombie', 51.5, 8.5), (6003, 'minecraft:cow', 50.5, 5.5), (6004, 'minecraft:zombie', 66.5, 8.5),
                   (6005, 'minecraft:cow', 3.5, 2.5)) v(id, tp, x, z);
    perform mc.entity_tick(1);            -- the first tick: the sweep, then the lanes start after the tracker
    perform mc.entity_tick(2);
end $$;

-- what the step of tick 3 must send, computed from the rows with the rules of the header of sql/530 (an independent oracle: chebyshev distance of the chunks, closed-form position, delta base)
create or replace function t.expected() returns table (conn int, id int, pkt bytea) language sql as $$
  select pl.conn_id::int, e.id, mc.epkt_mob_move(e.id, (q.qx - l.sqx)::int, (q.qy - l.sqy)::int, (q.qz - l.sqz)::int, (3 - l.last_tick)::int, e.on_ground, false, e.yaw, e.pitch)
    from mc.entity e join mc.entity_lane l on l.id = e.id join mc.entity_type_param p on p.type = e.type
    cross join lateral (select mc.quant(e.x + e.gx * (3 - e.phys_tick)) as qx, mc.quant(e.y) as qy, mc.quant(e.z + e.gz * (3 - e.phys_tick)) as qz) q
    join mc.player pl on pl.conn_id is not null
   where greatest(abs(pl.chunk_x - e.cx), abs(pl.chunk_z - e.cz)) <= least(p.tracking_chunks, mc.prop_int('view-distance'))
$$;

------------------------------------------------------------------------------------------------ A  view distance 12
select t.scenario(12);
select t.eq('A: all five mobs walk in lanes after two ticks', (select count(*)::int from mc.entity_lane), 5);
drop table if exists t.exp_a, t.act_a, t.exp_b, t.act_b;
create table t.exp_a as select * from t.expected();
select t.is_true('A: the oracle says: A sees 6001, 6005 (and 6002, 6003 at 3 chunks, 6004 at 4), C sees only 6003 (cow, 9 <= 10) and 6004 (zombie, 8 <= 8), D sees nothing',
                 (select count(*) filter (where conn = 1) = 5 and count(*) filter (where conn = 2) = 5 and count(*) filter (where conn = 3) = 2 and count(*) filter (where conn = 4) = 0 from t.exp_a));
delete from mc.play_out;
select set_config('dbcraft.entity_tick', '3', false);
select mc.entity_viewers_refresh(3);
select cardinality(mc.entity_lane_step(3)) as synced;
create table t.act_a as select o.conn_id::int as conn, p.pkt from mc.play_out o cross join lateral t.split(o.data) p(pkt);
select t.eq('A: every viewer gets at most two play_out rows (one per statement: the autonomous lanes of the cows, the chasing lanes of the zombies)', (select count(*)::int from (select conn_id from mc.play_out group by conn_id having count(*) > 2) q), 0);
select t.eq('A: viewers D (far away) gets no row, C gets one', (select count(*)::int from mc.play_out where conn_id in (4)), 0);
select t.is_true('A: the packets every viewer receives are EXACTLY the expected ones (same multiset, byte for byte)',
                 not exists (select 1 from (select conn, pkt, count(*) from t.exp_a group by 1, 2 except select conn, pkt, count(*) from t.act_a group by 1, 2) d)
                 and not exists (select 1 from (select conn, pkt, count(*) from t.act_a group by 1, 2 except select conn, pkt, count(*) from t.exp_a group by 1, 2) d));
select t.is_true('A: the mobs of one cell are concatenated in id order in one blob (viewer A: the packet of 6001 directly followed by the packet of 6005)',
                 (select bool_or(position((select pkt from t.exp_a where conn = 1 and id = 6001) || (select pkt from t.exp_a where conn = 1 and id = 6005) in o.data) > 0) from mc.play_out o where o.conn_id = 1));

------------------------------------------------------------------------------------------------ B  view distance 3: the range probe is skipped, nobody may get packets out of range
select t.scenario(3);
create table t.exp_b as select * from t.expected();
select t.is_true('B: the oracle says: A sees chunks 0..3 (everything but 6004 at 4), B sees all five (4 - 3 = 1), C and D see nothing',
                 (select count(*) filter (where conn = 1) = 4 and count(*) filter (where conn = 2) = 5 and count(*) filter (where conn = 3) = 0 and count(*) filter (where conn = 4) = 0 from t.exp_b));
delete from mc.play_out;
select set_config('dbcraft.entity_tick', '3', false);
select mc.entity_viewers_refresh(3);
select cardinality(mc.entity_lane_step(3)) as synced;
create table t.act_b as select o.conn_id::int as conn, p.pkt from mc.play_out o cross join lateral t.split(o.data) p(pkt);
select t.is_true('B: the packets every viewer receives are exactly the expected ones',
                 not exists (select 1 from (select conn, pkt, count(*) from t.exp_b group by 1, 2 except select conn, pkt, count(*) from t.act_b group by 1, 2) d)
                 and not exists (select 1 from (select conn, pkt, count(*) from t.act_b group by 1, 2 except select conn, pkt, count(*) from t.exp_b group by 1, 2) d));

------------------------------------------------------------------------------------------------ C  a mover that changes chunk (sql/551's tracker: the remove packet is built once per entity)
select t.clear();
update mc.server_property set value = '3' where key = 'view-distance';
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values
    ('00000000-0000-0000-0000-00000000000a', 'P1', 1, 901, -3 * 16 + 0.5, -60, 0.5, -3, 0, 0),
    ('00000000-0000-0000-0000-00000000000b', 'P2', 2, 902, 0.5, -60, 0.5, 0, 0, 0),
    ('00000000-0000-0000-0000-00000000000c', 'P3', 3, 903, 4 * 16 + 0.5, -60, 0.5, 4, 0, 0);
select mc.entity_viewers_refresh(1);
-- a cow that was last announced in chunk 0 at x = 15.9 and is now at x = 16.5 in chunk 1
insert into mc.entity (id, uuid, type, type_id, x, y, z, on_ground, born_tick, phys_tick, cx, cz, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz, yaw)
values (6101, gen_random_uuid(), 'minecraft:cow', mc.entity_type_id('minecraft:cow'), 16.5, -60, 8.5, true, 0, 0, 1, 0, 1, 0, 0, round(15.9 * 4096), round(-60 * 4096.0), round(8.5 * 4096), 0);
delete from mc.play_out;
select mc.entity_tracker(3, array[6101]);
select t.eq('C: the viewer who loses the cow (chunk -3: 4 chunks from the new cell) gets exactly remove_entities', (select string_agg(encode(data, 'hex'), ',') from mc.play_out where conn_id = 1), encode(mc.pkt_remove_entities(array[6101]), 'hex'));
select t.is_true('C: the viewer who gains it (chunk 4) gets exactly the appearance of the cow at its new place',
                 (select o.data = mc.epkt_appear(6101, e.uuid, e.type, e.type_id, e.x, e.y, e.z, e.vx, e.vy, e.vz, e.yaw, e.pitch, e.data) from mc.play_out o, mc.entity e where o.conn_id = 3 and e.id = 6101));
select t.is_true('C: the viewer who keeps it (chunk 0 sees chunks -3..3) gets a movement packet, no add and no remove',
                 (select o.data = mc.epkt_mob_move(6101, (mc.quant(16.5) - round(15.9 * 4096))::int, 0, 0, 2, true, false, e.yaw, e.pitch) from mc.play_out o, mc.entity e where o.conn_id = 2 and e.id = 6101));

------------------------------------------------------------------------------------------------ D  the vanilla parameters (javap, EntityTypes + EntityType$Builder of 26.3)
select t.is_true('D: cow: tracking range 10 chunks, update interval 3 (the Builder default)', (select tracking_chunks = 10 and update_interval = 3 from mc.entity_type_param where type = 'minecraft:cow'));
select t.is_true('D: zombie: tracking range 8, interval 3', (select tracking_chunks = 8 and update_interval = 3 from mc.entity_type_param where type = 'minecraft:zombie'));
select t.is_true('D: item: tracking range 6, interval 20', (select tracking_chunks = 6 and update_interval = 20 from mc.entity_type_param where type = 'minecraft:item'));
