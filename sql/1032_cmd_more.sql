-- /experience (alias /xp): add, set and query experience points and levels (ExperienceCommand).  The state changes are the survival module's (mc.xp_give, mc.xp_give_levels,
-- mc.xp_set_levels, mc.xp_set_points: sql/832, compared with the real server's set_experience packets); this is the command around them: the selector, the feedback keys and
-- the failure of `set ... points` for more points than the level needs.  Verified against the real server: tests/e2e/cmd_mini.py (see docs/GAME.md).

create or replace function mc.cmd_run_experience(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare parts text[] := string_to_array(sig, '/'); op text := parts[2]; unit text; amt int := nullif(args ->> 'amount', '')::int; tgts mc.player[]; t mc.player; n int := 0; need int;
begin
  tgts := mc.cmd_players(me, args -> 'target'); if tgts is null then return; end if;
  unit := case when op = 'query' then parts[4] else coalesce(parts[5], 'points') end;
  if op = 'query' then
    select * into t from mc.player where uuid = tgts[1].uuid;
    perform mc.cmd_success(me, mc.tc_translate('commands.experience.query.' || unit, array[mc.tc_player(t.uuid, t.name), mc.tc_arg_int(case when unit = 'levels' then t.xp_level else t.xp_total end)]), false);
    return;
  end if;
  foreach t in array tgts loop
    if op = 'add' then
      if unit = 'levels' then perform mc.xp_give_levels(t.uuid, amt); else perform mc.xp_give(t.uuid, amt); end if;
      n := n + 1;
    elsif unit = 'levels' then
      perform mc.xp_set_levels(t.uuid, amt); n := n + 1;
    else                                          -- ServerPlayer.setExperiencePoints: refused when the level does not need that many
      select mc.xp_needed(p.xp_level) into need from mc.player p where p.uuid = t.uuid;
      if amt < need then perform mc.xp_set_points(t.uuid, amt); n := n + 1; end if;
    end if;
  end loop;
  if n = 0 then perform mc.cmd_fail(me, mc.tc_translate('commands.experience.set.points.invalid')); return; end if;
  if cardinality(tgts) = 1 then
    perform mc.cmd_success(me, mc.tc_translate('commands.experience.' || op || '.' || unit || '.success.single', array[mc.tc_arg_int(amt), mc.tc_player(tgts[1].uuid, tgts[1].name)]));
  else
    perform mc.cmd_success(me, mc.tc_translate_json('commands.experience.' || op || '.' || unit || '.success.multiple', jsonb_build_array(amt, cardinality(tgts))));
  end if;
end $$;

-- /damage <target> <amount> [<damageType>]  (DamageCommand: the entity takes the damage as if hurt by that type, no attacker): the survival pipeline's mc.hurt does the rest (damage
-- event, hurt sound, health, death).  The success message says the amount (a float as Java prints it) and the target; a hit that was not taken says commands.damage.failed.
create or replace function mc.cmd_run_damage(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare tgts mc.player[]; t mc.player; amt real := (args ->> 'amount')::real; ty text := coalesce(nullif(regexp_replace(coalesce(args ->> 'damageType', ''), '^minecraft:', ''), ''), 'generic'); n int;
begin
  tgts := mc.cmd_players(me, args -> 'target', true); if tgts is null then return; end if;
  t := tgts[1];
  if not exists (select 1 from mc.damage_type where name = 'minecraft:' || ty) then perform mc.cmd_fail(me, mc.tc_translate('argument.resource.invalid_type')); return; end if;
  n := mc.hurt(array[t.entity_id], array[amt], ty, (select game_time from mc.game_state));
  if n = 0 then perform mc.cmd_fail(me, mc.tc_translate('commands.damage.invulnerable')); return; end if;
  perform mc.cmd_success(me, mc.tc_translate('commands.damage.success', array[proto.nbt_str('text', regexp_replace(trim_scale(amt::numeric)::text, '^(-?[0-9]+)$', '\1.0')), mc.tc_player(t.uuid, t.name)]));
end $$;

-- /kick <targets> [<reason>]: the disconnect packet carries the reason (the default is the translatable multiplayer.disconnect.kicked); the operators get commands.kick.success
create or replace function mc.cmd_run_kick(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare tgts mc.player[]; t mc.player; reason text := nullif(args #>> '{reason,text}', ''); nbt bytea; comp bytea; n int := 0;
begin
  tgts := mc.cmd_players(me, args -> 'targets'); if tgts is null then return; end if;
  nbt := proto.nbt_root(case when reason is null then proto.nbt_str('translate', 'multiplayer.disconnect.kicked') else proto.nbt_str('text', reason) end);
  comp := case when reason is null then proto.nbt_str('translate', 'multiplayer.disconnect.kicked') else proto.nbt_str('text', reason) end;
  foreach t in array tgts loop
    if t.conn_id is not null then
      insert into mc.play_out (conn_id, data) values (t.conn_id, mc.pkt_disconnect(nbt));
      insert into mc.kick values (t.conn_id, nbt) on conflict do nothing;
    end if;
    n := n + 1;
    if cardinality(tgts) = 1 then perform mc.cmd_success(me, mc.tc_translate('commands.kick.success', array[mc.tc_player(t.uuid, t.name), comp])); end if;
  end loop;
  if cardinality(tgts) > 1 then perform mc.cmd_success(me, mc.tc_translate_json('commands.kick.success.multiple', jsonb_build_array(n))); end if;
end $$;

-- /defaultgamemode <mode>: the game mode new players join with (the property `gamemode`); players already online keep theirs (force-gamemode is off)
create or replace function mc.cmd_run_defaultgamemode(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare gm text := args ->> 'gamemode';
begin
  update mc.server_property set value = gm where key = 'gamemode';
  perform mc.cmd_success(me, mc.tc_translate('commands.defaultgamemode.success', array[mc.tc_translate('gameMode.' || gm)]));
end $$;
