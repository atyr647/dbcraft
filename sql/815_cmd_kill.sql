-- Commands, part 6: /kill.
--
-- Selecting the victims, the failure when nobody matches and the feedback are done here (verified against the real server: `commands.kill.success.single` with the
-- player's name component, said AFTER the death packets).  Dying itself - the damage event, the death message, the death screen, the respawn - belongs to the survival
-- module: this command calls mc.kill_players(uuid[]) when that function exists.  Without it (a build without survival) the command answers with a red line and kills nobody,
-- instead of pretending.

create or replace function mc.cmd_run_kill(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare tgts mc.player[]; n int;
begin
  if args ? 'targets' then tgts := mc.cmd_players(me, args -> 'targets', true); if tgts is null then return; end if;
  else tgts := array[mc.cmd_me(me.uuid)]; end if;
  if to_regprocedure('mc.kill_players(uuid[])') is null then
    perform mc.cmd_fail(me, proto.nbt_str('text', '/kill needs the survival module (death is not implemented in this build)')); return;
  end if;
  execute 'select mc.kill_players($1)' using array(select u.uuid from unnest(tgts) u);
  if cardinality(tgts) = 1 then
    perform mc.cmd_success(me, mc.tc_translate('commands.kill.success.single', array[mc.tc_player(tgts[1].uuid, tgts[1].name)]));
  else
    perform mc.cmd_success(me, mc.tc_translate_json('commands.kill.success.multiple', jsonb_build_array(cardinality(tgts))));
  end if;
end $$;
