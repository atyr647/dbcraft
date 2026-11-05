-- The walking share of dbcraft's cows by distance from the one player, measured exactly as tools/entity/vanilla_walkshare.py measures vanilla's (docs/WHY-MOBS-COST.md section 10):
-- N cows at 8-24 blocks ("near"), N at 40-70 ("mid"), N at 100-130 ("far") from a player standing at the origin; positions sampled once a second (20 ticks); a cow walks in a second when it
-- moved more than 0.5 blocks in it.
-- usage: psql -X -v n=40 -v seconds=240 [-v ai=vanilla|wander] -f tests/bench/mobs2/walkshare.sql        (a database made by tests/bench/entity/setup_db.sh; it is changed)
\set ON_ERROR_STOP on
\timing off
\if :{?n}
\else
\set n 40
\endif
\if :{?seconds}
\else
\set seconds 240
\endif
\if :{?ai}
\else
\set ai vanilla
\endif
select set_config('dbcraft.entity_spawner', 'off', false), set_config('dbcraft.entity_ai', :'ai', false);
update mc.server_property set value = '5' where key = 'view-distance';
update mc.server_property set value = '10' where key = 'simulation-distance';
delete from mc.chunk where dimension = 'minecraft:overworld' and cx between -12 and 11 and cz between -12 and 11;
delete from mc.entity_floor;
select count(*) as chunks_generated from (select mc.generate_flat('minecraft:overworld', a.x, b.z) from generate_series(-12, 11) a(x), generate_series(-12, 11) b(z)) g \gset
select count(*) as masks_built from (select mc.entity_build_mask('minecraft:overworld', a.x, b.z, c.sy) from generate_series(-12, 11) a(x), generate_series(-12, 11) b(z), generate_series(-4, -3) c(sy)) w \gset
select count(*) as floors_built from (select mc.entity_floor_build('minecraft:overworld', a.x, b.z) from generate_series(-12, 11) a(x), generate_series(-12, 11) b(z)) w \gset
truncate mc.play_out, mc.entity_cell_viewer, mc.entity_viewer_cell, mc.entity_tick_log;
delete from mc.entity; delete from mc.player;
select setseed(0.37);
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode) values (gen_random_uuid(), 'p1', 1, nextval('mc.entity_id_seq'), 0.5, -60, 0.5, 0, 0, 1);
insert into mc.entity (id, uuid, type, type_id, x, y, z, vx, vy, vz, on_ground, born_tick, phys_tick, deep_sleep, cx, cz, gx, gz, goal_until, yaw, data, last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz)
select id, gen_random_uuid(), 'minecraft:cow', mc.entity_type_id('minecraft:cow'), x, -60.0, z, 0, 0, 0, true, 0, 0, false, floor(x / 16)::int, floor(z / 16)::int, 0, 0, 1, (random() * 360)::real, '{}'::jsonb,
       1, floor(x / 16)::int, floor(z / 16)::int, round(x * 4096), round(-60 * 4096.0), round(z * 4096)
  from (select nextval('mc.entity_id_seq')::int as id, g.grp, (lo + random() * (hi - lo)) * cos(a) as x, (lo + random() * (hi - lo)) * sin(a) as z
          from (select grp, lo, hi, random() * 2 * pi() as a from (values ('near', 8, 24), ('mid', 40, 70), ('far', 100, 130)) v(grp, lo, hi), generate_series(1, :n)) g (grp, lo, hi, a)) q;
create temp table _grp as select id, case when sqrt(x * x + z * z) < 30 then 'near' when sqrt(x * x + z * z) < 80 then 'mid' else 'far' end as grp from mc.entity;
create temp table _s (sec int, id int, x float8, z float8);
vacuum analyze mc.entity, mc.entity_lane;
create procedure pg_temp.run(p_secs int) language plpgsql as $$
declare tk int := 0;
begin
    for s in 0..p_secs loop
        for k in 1..20 loop
            tk := tk + 1;
            perform mc.entity_tick(tk);
            delete from mc.play_out;
            commit;
        end loop;
        insert into _s select s, e.id, e.x, e.z from mc.entity_live e;
        commit;
    end loop;
end $$;
call pg_temp.run(:seconds);
select g.grp, count(*) as cow_seconds, round((count(*) filter (where sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2) > 0.5))::numeric / count(*), 3) as walking_share
  from _s a join _s b on b.id = a.id and b.sec = a.sec + 1 join _grp g on g.id = a.id group by g.grp order by g.grp;
select 'dormant lanes at the end: ' || count(*) filter (where dormant) || ' of ' || count(*) as lanes from mc.entity_lane;
\if :{?series}
-- the per-second displacement series of every cow, one JSON line each (tools/entity/walkshare_stats.py reads them: run lengths, gaps, speed)
\pset tuples_only on
\pset format unaligned
select json_build_object('tag', g.grp, 'cow', a.id, 'd', array_agg(round(sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)::numeric, 3) order by a.sec)) from _s a join _s b on b.id = a.id and b.sec = a.sec + 1 join _grp g on g.id = a.id group by g.grp, a.id;
\endif
