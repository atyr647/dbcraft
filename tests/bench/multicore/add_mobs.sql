-- Adds awake walking mobs (87.5% cows, 12.5% zombies; announced, goals staggered) uniformly over +-area blocks to a database that already has players (ibench.setup).
-- usage: psql -v mobs=2000 -v area=790 -v crowd=0 -f add_mobs.sql        crowd=1: every mob within +-12 blocks of a random player instead (500 players crowded: everybody sees many mobs)
\set ON_ERROR_STOP on
\if :{?crowd}
\else
\set crowd 0
\endif
select set_config('dbcraft.entity_spawner', 'off', false);
delete from mc.entity; delete from mc.entity_lane; delete from mc.entity_cell_viewer; delete from mc.entity_viewer_cell;
select setseed(0.37);
insert into mc.entity (id, uuid, type, type_id, x, y, z, vx, vy, vz, on_ground, born_tick, phys_tick, deep_sleep, cx, cz, gx, gz, goal_until, yaw, data,
                       last_sent_tick, sent_cx, sent_cz, sent_qx, sent_qy, sent_qz)
select id, gen_random_uuid(), tp, mc.entity_type_id(tp), x, -60, z, 0, 0, 0, true, born, 0, false, floor(x / 16)::int, floor(z / 16)::int, 0, 0, goal, yaw, '{}'::jsonb,
       1, floor(x / 16)::int, floor(z / 16)::int, round(x * 4096), round(-60 * 4096.0), round(z * 4096)
  from (select nextval('mc.entity_id_seq')::int as id, case when random() < 0.875 then 'minecraft:cow' else 'minecraft:zombie' end as tp,
               case when :crowd = 1 then p.x + (random() - 0.5) * 24 else (-:area + random() * 2 * :area) end as x,
               case when :crowd = 1 then p.z + (random() - 0.5) * 24 else (-:area + random() * 2 * :area) end as z,
               -floor(random() * 60)::int as born, 1 + (random() * 60)::int as goal, (random() * 360)::real as yaw
          from generate_series(1, :mobs) g
          left join lateral (select pl.x, pl.z from mc.player pl where :crowd = 1 order by random() limit 1) p on true) e;
vacuum analyze mc.entity;
select count(*) as mobs_added from mc.entity;
