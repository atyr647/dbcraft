-- Prototype measurement of the narrow position table (docs/PERF-PAIRING.md, "Narrow position table"): what does one mover's UPDATE cost in the real wide mc.player row and in a
-- narrow UNLOGGED table, with the statement shape of mc.apply_player_moves (sql/431: one UPDATE ... FROM unnest(...) for all movers of the tick).
--   usage: psql -X -q -f tools/scoreboard/pos_proto_bench.sql dbcraft     (a database with the dbcraft schema; it creates and drops its own rows and a table in schema pp)
\set ON_ERROR_STOP on
\timing off
create schema if not exists pp;
drop table if exists pp.pos;
create unlogged table pp.pos (entity_id int primary key, x float8 not null, y float8 not null, z float8 not null, yaw real not null, pitch real not null, on_ground boolean not null,
                              chunk_x int not null, chunk_z int not null, last_move_tick bigint, vis_dirty boolean not null default false, vis_x float8, vis_z float8, vis_ocx int, vis_ocz int, yaw_prev real) with (fillfactor = 50);
truncate mc.player cascade;
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z)
select md5(i::text)::uuid, 'p' || i, i, i, random() * 800, 70, random() * 800, random() * 360, 0, 0, 0 from generate_series(1, 500) i;
update mc.player set vis_x = x, vis_z = z, last_move_tick = 0, trk_start = 0, wp_state = 1;
insert into pp.pos select entity_id, x, y, z, yaw, pitch, on_ground, chunk_x, chunk_z, last_move_tick, vis_dirty, vis_x, vis_z, vis_ocx, vis_ocz, yaw from mc.player;
vacuum analyze mc.player; vacuum analyze pp.pos;

create or replace function pp.bench(p_movers int, p_iter int) returns table(what text, us_per_mover float8) language plpgsql as $$
declare t0 timestamptz; i int; tot_wide float8 := 0; tot_narrow float8 := 0; tot_wide_min float8 := 0; ids int[]; xs float8[]; zs float8[]; n int;
begin
  select array_agg(entity_id order by entity_id) into ids from (select entity_id from mc.player order by entity_id limit p_movers) s;
  -- the maintenance the gateway does beside the tick: both tables are vacuumed once in a while
  for i in 1 .. p_iter loop
    select array_agg(random() * 800) into xs from unnest(ids);
    select array_agg(random() * 800) into zs from unnest(ids);
    t0 := clock_timestamp();
    update mc.player p set x = n.x, y = 70, z = n.z, yaw = (random() * 360)::real, pitch = 0, on_ground = true, chunk_x = floor(n.x / 16)::int, chunk_z = floor(n.z / 16)::int,
           last_move_tick = i, vis_dirty = (n.x - p.vis_x) ^ 2 + (n.z - p.vis_z) ^ 2 >= 16, yaw_prev = p.yaw
      from unnest(ids, xs, zs) as n(id, x, z) where p.entity_id = n.id;
    tot_wide := tot_wide + extract(epoch from clock_timestamp() - t0);
    t0 := clock_timestamp();
    update pp.pos p set x = n.x, y = 70, z = n.z, yaw = (random() * 360)::real, pitch = 0, on_ground = true, chunk_x = floor(n.x / 16)::int, chunk_z = floor(n.z / 16)::int,
           last_move_tick = i, vis_dirty = (n.x - p.vis_x) ^ 2 + (n.z - p.vis_z) ^ 2 >= 16, yaw_prev = p.yaw
      from unnest(ids, xs, zs) as n(id, x, z) where p.entity_id = n.id;
    tot_narrow := tot_narrow + extract(epoch from clock_timestamp() - t0);
    if i % 20 = 0 then null; end if;
  end loop;
  what := 'wide mc.player UPDATE (' || p_movers || ' movers, ' || (select count(*) from pg_attribute where attrelid = 'mc.player'::regclass and attnum > 0 and not attisdropped) || ' columns)'; us_per_mover := tot_wide / p_iter / p_movers * 1e6; return next;
  what := 'narrow unlogged pp.pos UPDATE (' || p_movers || ' movers)'; us_per_mover := tot_narrow / p_iter / p_movers * 1e6; return next;
end $$;
-- (each call runs in one transaction: no vacuum in between; the dead tuples of 200 iterations of 500 movers fit the page free space the way a second of ticks does)
select * from pp.bench(500, 100);
select * from pp.bench(100, 100);
select * from pp.bench(25, 100);
select pg_size_pretty(pg_relation_size('mc.player')) as player_size, pg_size_pretty(pg_relation_size('pp.pos')) as pos_size;
drop schema pp cascade;
truncate mc.player cascade;
