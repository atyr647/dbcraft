-- The database cost of one joiner's tracker work (docs/PERF-PAIRING.md), measured in the database alone, on the tree whose SQL is loaded: N returning players are online and settled
-- (spread over a square of side blocks, view distance 10, every client asks for 10), then J more join one per tick; the statements the tick runs for them (mc.refresh_visibility = the pair
-- search and bundles, and mc.vis_step = first tracker pass, locator connections of the new source, entity phase) are timed per tick, in ms, wall clock.  Works on trees without and with
-- the pairing queue (sql/903); set  :bud  to the dbcraft.pair-budget-ms of the run ('off' = every joiner at once) on a tree that has it.
--   usage: sed 's/:n;/200;/; s/:j;/20;/; s/:side/960/; s/:bud/off/' tools/scoreboard/pairing_join_bench.sql | psql -X -q dbcraft        (a scratch database: it empties mc.player)
\set ON_ERROR_STOP on
update mc.server_property set value = 'true' where key = 'dbcraft.vanilla-tracker';
update mc.server_property set value = '10' where key in ('view-distance', 'simulation-distance'); select net.sync_settings();
truncate mc.play_out, mc.visible, net.conn, mc.vtrk, mc.wp; delete from mc.player; select setval('mc.entity_id_seq', 1, false);
do $$ begin if to_regclass('mc.vpair') is not null then truncate mc.vpair; update mc.server_property set value = 'off' where key = 'dbcraft.pair-budget-ms'; end if; end $$;
update mc.game_state set game_time = 1000;
select setseed(0.3);
do $$
declare i int; side float8 := :side; n int := :n; j int := :j; tk int; gt bigint; a timestamptz; t_r float8[] := '{}'; t_s float8[] := '{}'; x float8; qlen int := 0;
begin
  for i in 1 .. n + j loop
    insert into mc.player (uuid, name, first_seen, x, z, chunk_x, chunk_z) select md5('pd' || i)::uuid, 'pd' || i, now() - interval '1 day', g.px, g.pz, floor(g.px / 16)::int, floor(g.pz / 16)::int
      from (select random() * side as px, random() * side as pz) g;
  end loop;
  for i in 1 .. n loop
    update mc.game_state set spawn_x = random() * side, spawn_z = random() * side;
    insert into net.conn (conn_id, state, name, uuid, compression, client_info) values (i, 'play', 'pd' || i, md5('pd' || i)::uuid, -1, '{"view_distance": 10, "skin_parts": 0, "main_hand": 1}'::jsonb);
    perform mc.on_join(i, md5('pd' || i)::uuid, 'pd' || i, false);
    perform mc.vis_join(i, md5('pd' || i)::uuid);
  end loop;
  for tk in 1 .. 12 loop
    gt := 1000 + tk; update mc.game_state set game_time = gt;
    perform mc.refresh_visibility(); perform mc.vis_step(gt);
  end loop;
  truncate mc.play_out;
  if to_regclass('mc.vpair') is not null then execute format('update mc.server_property set value = %L where key = ''dbcraft.pair-budget-ms''', ':bud'); end if;
  for tk in 1 .. j + 12 loop
    gt := 1012 + tk; update mc.game_state set game_time = gt;
    if tk <= j then
      i := n + tk;
      update mc.game_state set spawn_x = random() * side, spawn_z = random() * side;
      insert into net.conn (conn_id, state, name, uuid, compression, client_info) values (i, 'play', 'pd' || i, md5('pd' || i)::uuid, -1, '{"view_distance": 10, "skin_parts": 0, "main_hand": 1}'::jsonb);
      perform mc.on_join(i, md5('pd' || i)::uuid, 'pd' || i, false);
      perform mc.vis_join(i, md5('pd' || i)::uuid);
    end if;
    a := clock_timestamp(); perform mc.refresh_visibility(); x := extract(epoch from clock_timestamp() - a) * 1000; t_r := t_r || x;
    a := clock_timestamp(); perform mc.vis_step(gt); t_s := t_s || (extract(epoch from clock_timestamp() - a) * 1000);
    truncate mc.play_out;
  end loop;
  -- (the first five joiners are warm-up: plpgsql plans are made on the first calls)
  raise notice 'online % + % joiners one a tick: per tick, ms: refresh median % / mean %, vis_step median % / mean %, sum of the two % ms mean over the %.. ticks, worst tick %',
    n, j,
    round((select percentile_cont(0.5) within group (order by v) from unnest(t_r[6:j]) v)::numeric, 2), round((select avg(v) from unnest(t_r[6:j]) v)::numeric, 2),
    round((select percentile_cont(0.5) within group (order by v) from unnest(t_s[6:j]) v)::numeric, 2), round((select avg(v) from unnest(t_s[6:j]) v)::numeric, 2),
    round((select avg(a1 + b1) from unnest(t_r[6:j], t_s[6:j]) u(a1, b1))::numeric, 2), j, round((select max(a1 + b1) from unnest(t_r[6:j], t_s[6:j]) u(a1, b1))::numeric, 2);
end $$;
