-- /spawnpoint and /setworldspawn (docs/MINING-AND-COMMANDS.md), recorded from the real 26.3 server (tests/e2e/cmd_blocks.py, group spawn).
--
--   /spawnpoint [<targets> [<pos> [<rotation>]]]   sets each target player's spawn point (a block position and an angle); no position: the executor's block; no rotation: yaw 0 pitch 0
--                                                  (the executor's own rotation when no position is given either); nothing is sent to the client.  The message carries x y z (ints),
--                                                  yaw pitch (floats), the dimension and the player (or the number of players).  A dead player respawns there (sql/836).
--   /setworldspawn [<pos> [<rotation>]]            sets the world spawn: the message carries x y z, yaw, pitch and the dimension; a CHANGED spawn is sent to everybody as
--                                                  set_default_spawn_position.
--   A rotation is two angles, each absolute or `~` relative to the executor's rotation.
-- Not modelled: the spawn radius of the world spawn for new players (spawn_radius is 0 in the recorded runs), spawn points that are beds or respawn anchors (a bed does not set one),
-- and the check that a forced spawn point is still standing (a /spawnpoint is forced: it never needs a bed).

-- (the table mc.player_spawn and the column mc.game_state.spawn_pitch are created in sql/836, whose respawn uses them)

-- a rotation argument ["90", "~5"] against the executor's rotation: [yaw, pitch]
create or replace function mc.cmd_rotation(me mc.player, rot jsonb, out ryaw real, out rpitch real) language plpgsql stable as $$
declare ex mc.player := mc.cmd_me(me.uuid); a text := rot ->> 0; b text := rot ->> 1;
begin
  ryaw := case when a like '~%' then ex.yaw + coalesce(nullif(substr(a, 2), ''), '0')::real else coalesce(nullif(a, ''), '0')::real end;
  rpitch := case when b like '~%' then ex.pitch + coalesce(nullif(substr(b, 2), ''), '0')::real else coalesce(nullif(b, ''), '0')::real end;
end $$;

create or replace function mc.cmd_run_spawnpoint(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare tgts mc.player[]; t mc.player; ex mc.player := mc.cmd_me(me.uuid); px int; py int; pz int; yaw real := 0; pitch real := 0; r record; a int[]; msg bytea[];
begin
  if args ? 'targets' then tgts := mc.cmd_players(me, args -> 'targets'); if tgts is null then return; end if; else tgts := array[ex]; end if;
  if args ? 'pos' then
    a := mc.cmd_pos_loaded(me, args -> 'pos'); if a is null then return; end if;
    px := a[1]; py := a[2]; pz := a[3];
    if args ? 'rotation' then select * into r from mc.cmd_rotation(me, args -> 'rotation'); yaw := r.ryaw; pitch := r.rpitch; end if;
  else
    px := floor(ex.x)::int; py := floor(ex.y)::int; pz := floor(ex.z)::int; yaw := ex.yaw; pitch := ex.pitch;
  end if;
  foreach t in array tgts loop
    insert into mc.player_spawn (uuid, x, y, z, yaw, pitch) values (t.uuid, px, py, pz, yaw, pitch)
    on conflict (uuid) do update set dimension = 'minecraft:overworld', x = excluded.x, y = excluded.y, z = excluded.z, yaw = excluded.yaw, pitch = excluded.pitch;
  end loop;
  msg := array[mc.tc_arg_int(px), mc.tc_arg_int(py), mc.tc_arg_int(pz), proto.nbt_float('', yaw), proto.nbt_float('', pitch), mc.tc_arg_str('minecraft:overworld')];
  if cardinality(tgts) = 1 then
    perform mc.cmd_success(me, mc.tc_translate('commands.spawnpoint.success.single', msg || mc.tc_player(tgts[1].uuid, tgts[1].name)));
  else
    perform mc.cmd_success(me, mc.tc_translate('commands.spawnpoint.success.multiple', msg || mc.tc_arg_int(cardinality(tgts))));
  end if;
end $$;

create or replace function mc.cmd_run_setworldspawn(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare ex mc.player := mc.cmd_me(me.uuid); px int; py int; pz int; yaw real := 0; pitch real := 0; r record; a int[]; g mc.game_state;
begin
  if args ? 'pos' then
    a := mc.cmd_pos_loaded(me, args -> 'pos'); if a is null then return; end if;
    px := a[1]; py := a[2]; pz := a[3];
    if args ? 'rotation' then select * into r from mc.cmd_rotation(me, args -> 'rotation'); yaw := r.ryaw; pitch := r.rpitch; end if;
  else
    px := floor(ex.x)::int; py := floor(ex.y)::int; pz := floor(ex.z)::int; yaw := ex.yaw; pitch := ex.pitch;
  end if;
  select * into g from mc.game_state;
  if (floor(g.spawn_x)::int, floor(g.spawn_y)::int, floor(g.spawn_z)::int, g.spawn_yaw, g.spawn_pitch) is distinct from (px, py, pz, yaw, pitch) then
    update mc.game_state set spawn_x = px + 0.5, spawn_y = py, spawn_z = pz + 0.5, spawn_yaw = yaw, spawn_pitch = pitch;
    insert into mc.play_out (conn_id, data) select conn_id, mc.cb('set_default_spawn_position', proto.string('minecraft:overworld') || proto.position(px, py, pz) || proto.f32(yaw) || proto.f32(pitch))
      from mc.player where conn_id is not null order by entity_id;
  end if;
  perform mc.cmd_success(me, mc.tc_translate('commands.setworldspawn.success', array[mc.tc_arg_int(px), mc.tc_arg_int(py), mc.tc_arg_int(pz), proto.nbt_float('', yaw), proto.nbt_float('', pitch),
                                                                                       mc.tc_arg_str('minecraft:overworld')]));
end $$;
