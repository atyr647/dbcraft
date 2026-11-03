-- Survival core, part 7: the wiring.  mc.tick_core is sql/430's with the survival steps added (listed in sql/OVERRIDES.txt; docs/SURVIVAL.md has the order and why).
-- Per tick, in this order (vanilla's: network packets, then the level tick: tracker pass, then the entities):
--   survival_pre (sprint, snapshot) > apply_player_moves > survival_moves (fall) > apply_misc_input > apply_chat (commands: /kill ...)
--   > survival_after_chat: respawn, start eating, [refresh_visibility] ... tracker, deaths, void, finish eating, food, set_health/set_experience
-- refresh_visibility sits between the packet-phase steps and the entity-phase ones so that a respawned player is announced in the same tick.

create or replace function mc.survival_input(p_cur bigint) returns void language plpgsql as $$
begin
  perform mc.survival_respawn(p_cur);
  perform mc.survival_use(p_cur, 'start');
end $$;

create or replace function mc.survival_entities(p_cur bigint) returns void language plpgsql as $$
begin
  perform mc.survival_tracker(p_cur);
  perform mc.survival_deaths(p_cur);
  perform mc.survival_void(p_cur);
  perform mc.survival_use(p_cur, 'finish');
  perform mc.survival_food(p_cur);
  perform mc.survival_sync(p_cur);
end $$;

alter table mc.tick_log add column if not exists ms_survival float8;

create or replace function mc.tick_core() returns bigint language plpgsql as $$
declare cur bigint; t0 timestamptz := clock_timestamp(); t1 timestamptz; t2 timestamptz; t3 timestamptz; t4 timestamptz; t5 timestamptz; t6 timestamptz;
        mv record; ch record; vis record; ka record; n_in int; n_players int; n_out int; snap mc.surv_snap; s0 timestamptz; s1 timestamptz; s2 timestamptz; ms_surv float8;
begin
  update mc.game_state set game_time = game_time + 1, day_time = day_time + 1 returning game_time into cur;
  select count(*)::int into n_in from mc.play_in_work;
  select count(*)::int into n_players from mc.player where conn_id is not null;
  snap := mc.survival_pre();                                       s0 := clock_timestamp();                  -- (survival) sprint flags, positions before the moves
  select * into mv from mc.apply_player_moves(cur);                t1 := clock_timestamp();
  perform mc.survival_moves(cur, snap);                            s1 := clock_timestamp();                  -- (survival) fall damage, jump / sprint exhaustion
  perform mc.apply_misc_input(cur);                                t2 := clock_timestamp();
  select * into ch from mc.apply_chat(cur);                        t3 := clock_timestamp();
  perform mc.survival_input(cur);                                  s2 := clock_timestamp();                  -- (survival) respawn, start eating
  select * into vis from mc.refresh_visibility();                  t4 := clock_timestamp();
  perform mc.survival_entities(cur);                                                                          -- (survival) tracker, deaths, void, eating, food, health/experience
  select * into ka from mc.keepalive_due(cur);                     t5 := clock_timestamp();
  if cur % 20 = 0 then
    with p as materialized (select mc.pkt_set_time(cur) as d) insert into mc.play_out (conn_id, data) select conn_id, p.d from mc.player, p where conn_id is not null;
  end if;
  t6 := clock_timestamp();
  ms_surv := extract(epoch from (s0 - t0) + (s1 - t1) + (s2 - t3)) * 1000 + extract(epoch from clock_timestamp() - t4) * 0;   -- the three survival slices that sit outside the other buckets
  if current_setting('mc.count_out', true) = 'on' then select count(*)::int into n_out from mc.play_out; end if;
  insert into mc.tick_log (tick, at, players, in_rows, out_rows, ms_total, ms_moves, ms_misc, ms_chat, ms_visibility, ms_keepalive, ms_time, movers, corrections, kicks, ms_survival)
  values (cur, now(), n_players, n_in, n_out,
     extract(epoch from t6 - t0) * 1000, extract(epoch from t1 - s0) * 1000, extract(epoch from t2 - s1) * 1000, extract(epoch from t3 - t2) * 1000,
     extract(epoch from t4 - s2) * 1000, extract(epoch from t5 - t4) * 1000, extract(epoch from t6 - t5) * 1000, mv.moved, mv.corrected, mv.kicked, ms_surv);
  delete from mc.tick_log where tick < cur - 6000;       -- keep the last 5 minutes
  return cur;
end $$;
