-- this test pins the classic (simplified) player broadcast of sql/430-468; the vanilla tracker of sql/900-910 has its own test (900_vis.sql)
update mc.server_property set value = 'false' where key = 'dbcraft.vanilla-tracker';
-- mc.fanout_moves (sql/430_tick_perf_fanout.sql): the per-chunk blob path must give every viewer exactly the bytes of the row-wise path through mc.visible,
-- on random states: dense crowds, sparse worlds, mixtures, several view distances, self-exclusion, movers that are alone, viewers that are only themselves.
create or replace function t.fan_case(p_seed float8, p_n int, p_side int, p_view int, p_mover_frac float8, p_far int, p_mode_b text default 'cells', p_dirty_b boolean default false) returns int language plpgsql as $$
declare bad int; f_eid int[]; f_data bytea[]; f_ocx int[]; f_ocz int[]; v_conn int[]; v_eid int[]; v_cx int[]; v_cz int[];
begin
  perform setseed(p_seed);
  truncate mc.play_out, mc.visible; delete from mc.player;
  update mc.server_property set value = p_view::text where key = 'view-distance';
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, vis_dirty, last_sent_tick, gamemode, keepalive_sent_tick)
  select md5(i::text)::uuid, 'f' || i, i, i, px, -60, pz, 0, 0, floor(px / 16)::int, floor(pz / 16)::int, mc.quant(px), mc.quant(-60), mc.quant(pz), true, 0, 1, 0
    from (select i, case when i <= p_n - p_far then random() * p_side * 16 else 1000 + random() * 2000 end as px, case when i <= p_n - p_far then random() * p_side * 16 else random() * 2000 end as pz
            from generate_series(1, p_n) i) g;
  perform count(*) from mc.refresh_visibility();
  truncate mc.play_out;
  -- the movers: a random subset, each with a packet of random length (the eid first so that every packet is distinguishable)
  select coalesce(array_agg(entity_id order by entity_id), '{}'), coalesce(array_agg(set_byte('\x00'::bytea, 0, entity_id % 256) || decode(repeat(md5(entity_id::text), 1 + entity_id % 3), 'hex') order by entity_id), '{}'),
         coalesce(array_agg(chunk_x order by entity_id), '{}'), coalesce(array_agg(chunk_z order by entity_id), '{}')
    into f_eid, f_data, f_ocx, f_ocz from mc.player where random() < p_mover_frac;
  select array_agg(conn_id order by conn_id), array_agg(entity_id order by conn_id), array_agg(chunk_x order by conn_id), array_agg(chunk_z order by conn_id)
    into v_conn, v_eid, v_cx, v_cz from mc.player where conn_id is not null;
  perform mc.fanout_moves(f_eid, f_data, f_ocx, f_ocz, v_conn, v_eid, v_cx, v_cz, false, 'rows');
  create temp table if not exists t_rows (conn_id int, data bytea);
  create temp table if not exists t_cells (conn_id int, data bytea);
  truncate t_rows, t_cells;
  insert into t_rows select conn_id, data from mc.play_out;
  truncate mc.play_out;
  perform mc.fanout_moves(f_eid, f_data, f_ocx, f_ocz, v_conn, v_eid, v_cx, v_cz, p_dirty_b, p_mode_b);
  insert into t_cells select conn_id, data from mc.play_out;
  truncate mc.play_out;
  select count(*) into bad from (select conn_id, data from t_rows except select conn_id, data from t_cells) a;
  bad := bad + (select count(*) from (select conn_id, data from t_cells except select conn_id, data from t_rows) b);
  bad := bad + abs((select count(*) from t_rows) - (select count(*) from t_cells))::int;
  return bad;
end $$;

-- dense crowds (everybody sees everybody), medium, sparse; view distances 1..10; few and many movers
select t.eq('crowd 60 players in 2x2 chunks, view 3, 50% moving', t.fan_case(0.11, 60, 2, 3, 0.5, 0), 0);
select t.eq('crowd 120 players in 3x3 chunks, view 10, 100% moving', t.fan_case(0.12, 120, 3, 10, 1.0, 0), 0);
select t.eq('crowd 80 players in 6x6 chunks, view 2 (partial overlap), 40% moving', t.fan_case(0.13, 80, 6, 2, 0.4, 0), 0);
select t.eq('crowd 100 players in 8x8 chunks, view 3, 20% moving', t.fan_case(0.14, 100, 8, 3, 0.2, 0), 0);
select t.eq('crowd plus 30 players far away, view 4', t.fan_case(0.15, 110, 3, 4, 0.6, 30), 0);
select t.eq('one mover only', t.fan_case(0.16, 70, 2, 5, 0.015, 0), 0);
select t.eq('no mover at all', t.fan_case(0.17, 40, 2, 3, 0.0, 0), 0);
select t.eq('sparse world: 50 players over 40x40 chunks, view 3', t.fan_case(0.18, 50, 40, 3, 0.5, 0), 0);
select t.eq('everybody moves, view 1, 4x4 chunks', t.fan_case(0.19, 90, 4, 1, 1.0, 0), 0);
select t.eq('mixed: 20 random cases', (select sum(t.fan_case(s * 0.013, 40 + s * 3, 1 + s % 7, 1 + s % 6, (s % 5) / 4.0, s % 4)) from generate_series(1, 20) s)::int, 0);

-- a pending visibility change (vis_dirty) must route to the row-wise path (mc.visible does not match the coordinates yet): even in 'cells' mode the dirty flag wins
select t.eq('dirty flag forces the row-wise path (auto mode)', t.fan_case(0.2, 60, 2, 3, 0.5, 0, 'auto', true), 0);
select t.eq('dirty flag forces the row-wise path (even when cells are asked for)', t.fan_case(0.21, 90, 3, 4, 0.7, 10, 'cells', true), 0);
-- auto mode picks cells for crowds and rows for sparse worlds: either way the same bytes
select t.eq('auto mode, crowd', t.fan_case(0.22, 150, 3, 10, 0.5, 0, 'auto', false), 0);
select t.eq('auto mode, sparse world', t.fan_case(0.23, 60, 40, 3, 0.5, 0, 'auto', false), 0);
-- the viewer that is the only mover gets nothing (no row): both paths agree on the row count too (checked in fan_case), and a crowd of one has no rows at all
select t.eq('single player: nothing to send', t.fan_case(0.24, 1, 1, 3, 1.0, 0), 0);
select t.is_true('the cell path really runs for a crowd (mc.fanout_moves returns 1)', (
  select mc.fanout_moves(array[1], array['\x01'::bytea], array[0], array[0], array[1, 2], array[1, 2], array[0, 0], array[0, 0], false, 'cells') = 1));
select t.is_true('...and the row path returns 0', (
  select mc.fanout_moves(array[1], array['\x01'::bytea], array[0], array[0], array[1, 2], array[1, 2], array[0, 0], array[0, 0], true, 'auto') = 0));
