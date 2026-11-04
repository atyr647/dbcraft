-- Survival core, part 7: the wiring.  mc.tick_core is sql/430's with the survival steps added (listed in sql/OVERRIDES.txt; docs/SURVIVAL.md has the order and why).
-- Per tick, in this order (vanilla's: network packets, then the level tick: tracker pass, then the entities):
--   survival_pre (sprint, snapshot) > apply_player_moves > survival_moves (fall) > apply_misc_input > apply_chat (commands: /kill ...)
--   > survival_after_chat: respawn, start eating, [refresh_visibility] ... tracker, deaths, void, finish eating, food, set_health/set_experience
-- refresh_visibility sits between the packet-phase steps and the entity-phase ones so that a respawned player is announced in the same tick.

-- packet phase: respawn and the start of eating, only when this tick's input has such a packet (the snapshot of mc.survival_pre says which kinds it has; null = look)
drop function if exists mc.survival_input(bigint);
create or replace function mc.survival_input(p_cur bigint, s mc.surv_snap default null) returns void language plpgsql as $$
begin
  if s.kinds is null or mc.sid('client_command') = any (s.kinds) then perform mc.survival_respawn(p_cur); end if;
  if s.kinds is null or mc.sid('use_item') = any (s.kinds) or mc.sid('player_action') = any (s.kinds) then perform mc.survival_use(p_cur, 'start'); end if;
end $$;

-- entity phase: ONE scan of the online players finds everybody who has anything to do (an unsent health/food/experience/entity-data change, a death animation running,
-- below the world, using an item, a hunger or regeneration timer, peaceful regeneration due); the steps then run on that short list, or not at all.  A player who is not
-- in the list cannot be changed by any step of this tick: damage from earlier steps (moves, commands) is an unsent change, damage from the steps below is to players
-- the list already holds (the void, the hungry).
create or replace function mc.survival_entities(p_cur bigint) returns void language plpgsql as $$
declare ids int[]; peaceful boolean := mc.difficulty() = 0;
begin
  select array_agg(p.entity_id order by p.entity_id) into ids
    from mc.player p
   where p.conn_id is not null
     and (p.sent_health is distinct from p.health or p.sent_food is distinct from p.food or p.sent_sat_zero is distinct from (p.saturation = 0) or p.sent_xp_total is distinct from p.xp_total
          or p.sent_eh is distinct from p.health or p.sent_using is distinct from (p.use_slot is not null) or p.sent_score is distinct from p.xp_score or p.pend_slot is not null
          or (p.dead and p.death_tick is not null) or (not p.dead and p.y < -128) or p.use_slot is not null
          or p.exhaustion > 4 or (p.health > 0 and p.health < 20) or p.food <= 0 or p.food_timer <> 0
          or (peaceful and p.join_tick is not null and (p_cur - p.join_tick) % 10 = 0 and (p.food < 20 or p.health < 20 or p.saturation < 20)));
  if ids is null then return; end if;
  perform mc.survival_tracker(p_cur, ids);
  perform mc.survival_deaths(p_cur, ids);
  perform mc.survival_void(p_cur, ids);
  perform mc.survival_use(p_cur, 'finish', ids);
  perform mc.survival_food(p_cur, ids);
  perform mc.survival_sync(p_cur, ids);
end $$;

alter table mc.tick_log add column if not exists ms_survival float8;

create or replace function mc.tick_core() returns bigint language plpgsql as $$
declare cur bigint; t0 timestamptz := clock_timestamp(); t1 timestamptz; t2 timestamptz; t3 timestamptz; t4 timestamptz; t5 timestamptz; t6 timestamptz;
        mv record; ch record; vis record; ka record; n_in int; n_players int; n_out int; snap mc.surv_snap; n_misc boolean; n_chat boolean; s0 timestamptz; s1 timestamptz; s2 timestamptz; ms_surv float8;
begin
  update mc.game_state set game_time = game_time + 1, day_time = day_time + 1 returning game_time into cur;
  select count(*)::int into n_in from mc.play_in_work;
  select count(*)::int into n_players from mc.player where conn_id is not null;
  snap := mc.survival_pre();                                       s0 := clock_timestamp();                  -- (survival) sprint flags, positions before the moves
  -- sql/800 (idle): phases with nothing to do are not run; movement is skipped only when mc.moves_idle() proves apply_player_moves would change nothing
  select coalesce(bool_or(packet_id in (mc.sid('keep_alive'), mc.sid('set_carried_item'), mc.sid('set_creative_mode_slot'))), false),
         coalesce(bool_or(packet_id in (mc.sid('chat'), mc.sid('chat_command'), mc.sid('chat_command_signed'))), false)
    into n_misc, n_chat from mc.play_in_work;
  if current_setting('dbcraft.quiet_tick', true) = 'off' then n_misc := true; n_chat := true; end if;       -- the switch of sql/800: run every phase, as before
  if mc.moves_idle() then
    select 0::int as moved, 0::int as corrected, 0::int as kicked into mv;
    if n_in > 0 and exists (select 1 from mc.play_in_work where packet_id = mc.sid('client_tick_end')) then delete from mc.play_in_work where packet_id = mc.sid('client_tick_end'); end if;
  else
    select * into mv from mc.apply_player_moves(cur);
  end if;                                                          t1 := clock_timestamp();
  perform mc.survival_moves(cur, snap);                            s1 := clock_timestamp();                  -- (survival) fall damage, jump / sprint exhaustion
  if n_misc then perform mc.apply_misc_input(cur); end if;         t2 := clock_timestamp();
  perform mc.container_step(cur);                                                                                                  -- (containers) menus: clicks, open, close, furnaces; sql/860-866, docs/CONTAINERS.md
  if n_chat then select * into ch from mc.apply_chat(cur); end if; t3 := clock_timestamp();
  perform mc.survival_input(cur, snap);                            s2 := clock_timestamp();                  -- (survival) respawn, start eating
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
