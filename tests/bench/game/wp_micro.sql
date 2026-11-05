-- Micro benchmark of the locator bar pass alone (tests/bench/game/wp_micro.sh): the same state and the same movement given to mc.vis_wp_pass_pairs (the reference: every pair) and to
-- mc.vis_wp_pass (dirty-driven), alternately, wall time of the pass in ms (median and p10 of the runs).  Needs a state made by tests/bench/game/walk_prof.sh (players, connections).
create or replace function bench.wp_micro(p_iter int, p_speed float8 default 0.215) returns table(line text) language plpgsql as $$
declare i int; t0 timestamptz; ta float8[] := '{}'; tb float8[] := '{}'; cur bigint := (select game_time from mc.game_state) + 1000; n int; npk bigint; nb bigint;
begin
  select count(*)::int into n from mc.player where conn_id is not null;
  create temp table if not exists t_mp (entity_id int, wp_state smallint, wp_bx int, wp_by int, wp_bz int, wp_cx int, wp_cz int, wp_vr smallint);
  create temp table if not exists t_mw as select * from mc.wp with no data;
  perform mc.vis_wp_pass(cur, 1, n); truncate mc.play_out;
  for i in 1 .. p_iter loop
    cur := cur + 1;
    update mc.player set x = x - sin(radians(yaw)) * p_speed, z = z + cos(radians(yaw)) * p_speed, last_move_tick = cur,
                         chunk_x = floor((x - sin(radians(yaw)) * p_speed) / 16)::int, chunk_z = floor((z + cos(radians(yaw)) * p_speed) / 16)::int where conn_id is not null;
    truncate t_mp, t_mw;
    insert into t_mp select entity_id, wp_state, wp_bx, wp_by, wp_bz, wp_cx, wp_cz, wp_vr from mc.player where conn_id is not null;
    insert into t_mw select * from mc.wp;
    t0 := clock_timestamp(); perform mc.vis_wp_pass_pairs(cur, 1, n); ta := ta || extract(epoch from clock_timestamp() - t0) * 1000;
    truncate mc.play_out;
    update mc.player p set wp_state = s.wp_state, wp_bx = s.wp_bx, wp_by = s.wp_by, wp_bz = s.wp_bz, wp_cx = s.wp_cx, wp_cz = s.wp_cz, wp_vr = s.wp_vr from t_mp s where s.entity_id = p.entity_id;
    truncate mc.wp; insert into mc.wp select * from t_mw;
    t0 := clock_timestamp(); perform mc.vis_wp_pass(cur, 1, n); tb := tb || extract(epoch from clock_timestamp() - t0) * 1000;
    select count(*), coalesce(sum(length(data)), 0) into npk, nb from mc.play_out; truncate mc.play_out;
  end loop;
  return query select format('players %s: reference pass median %s p10 %s ms | dirty-driven median %s p10 %s ms | rows %s | last tick out rows %s bytes %s', n,
    round((select percentile_cont(.5) within group (order by v) from unnest(ta) v)::numeric, 2), round((select percentile_cont(.1) within group (order by v) from unnest(ta) v)::numeric, 2),
    round((select percentile_cont(.5) within group (order by v) from unnest(tb) v)::numeric, 2), round((select percentile_cont(.1) within group (order by v) from unnest(tb) v)::numeric, 2),
    (select count(*) from mc.wp), npk, nb);
end $$;
