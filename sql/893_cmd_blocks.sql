-- Commands that take block positions: /setblock and /fill (docs/MINING-AND-COMMANDS.md).  The arguments are parsed by sql/811 (block_pos, block_state, block_predicate); the world
-- changes are mc.set_block (one position) and mc.fill_mode (sql/961: replace [filter], keep, outline, hollow).  Read from the 26.3 bytecode of SetBlockCommand / FillCommand and
-- compared with the real server by tests/e2e/cmd_blocks.py.
--
-- Rules:
--   * a position must be in a loaded chunk (`argument.pos.unloaded`: here, a chunk dbcraft has) and in the world (`argument.pos.outofworld`)
--   * /setblock  replace (default): any; keep: only an air cell; destroy: the old block is destroyed first (break effect 2001 to everybody within 64 blocks, its loot dropped with no tool
--     when entity-mode is inline, the cell becomes air or its fluid); the command FAILS (commands.setblock.failed) when the cell already has that state.  Destroying air with air is a
--     "success" that changes nothing.  Neighbours are notified unless `strict`.
--   * /fill  the box may hold at most max_block_modifications (32768) positions (commands.fill.toobig, with the limit and the size); destroy breaks every block of the box (effect 2001,
--     loot) and then places the block everywhere; the count in the message is the number of positions whose state changed; none changed: commands.fill.failed.
-- Not modelled: block entity data (`block{...}` is said not to be supported), the neighbour updates of /fill (the dynamics engine reacts to the changes it sees), `strict`'s lack of
-- shape updates (strict is accepted and acts like the default), the loaded-chunk test is "dbcraft has the chunk".

-- A block position argument as the block it names: relative (~) to the executor's feet, local (^) along its view
create or replace function mc.cmd_blockpos(me mc.player, coords jsonb, out px int, out py int, out pz int) language plpgsql stable as $$
declare ex mc.player := mc.cmd_me(me.uuid); dx float8; dy float8; dz float8; c text[]; ox float8; oy float8; oz float8;
begin
  select array_agg(e order by o) into c from jsonb_array_elements_text(coords) with ordinality t(e, o);
  if c[1] like '^%' then
    select l.dx, l.dy, l.dz into dx, dy, dz from mc.local_offset(ex.yaw, ex.pitch, coalesce(nullif(substr(c[1], 2), ''), '0')::float8, coalesce(nullif(substr(c[2], 2), ''), '0')::float8,
                                                                  coalesce(nullif(substr(c[3], 2), ''), '0')::float8) l;
    px := floor(ex.x + dx)::int; py := floor(ex.y + dy)::int; pz := floor(ex.z + dz)::int; return;
  end if;
  ox := ex.x; oy := ex.y; oz := ex.z;
  px := floor(case when c[1] like '~%' then ox + coalesce(nullif(substr(c[1], 2), ''), '0')::float8 else coalesce(nullif(c[1], ''), '0')::float8 end)::int;
  py := floor(case when c[2] like '~%' then oy + coalesce(nullif(substr(c[2], 2), ''), '0')::float8 else coalesce(nullif(c[2], ''), '0')::float8 end)::int;
  pz := floor(case when c[3] like '~%' then oz + coalesce(nullif(substr(c[3], 2), ''), '0')::float8 else coalesce(nullif(c[3], ''), '0')::float8 end)::int;
end $$;

-- BlockPosArgument.getLoadedBlockPos: the chunk must be there, the position inside the world; null (after the failure message) when not
create or replace function mc.cmd_pos_loaded(me mc.player, coords jsonb) returns int[] language plpgsql as $$
declare b record;
begin
  select * into b from mc.cmd_blockpos(me, coords);
  if mc.get_block('minecraft:overworld', b.px, 0, b.pz) is null and not exists (select 1 from mc.chunk c where c.dimension = 'minecraft:overworld' and c.cx = b.px >> 4 and c.cz = b.pz >> 4) then
    perform mc.cmd_fail(me, mc.tc_translate('argument.pos.unloaded')); return null;
  end if;
  if b.py < -64 or b.py > 319 or abs(b.px) >= 30000000 or abs(b.pz) >= 30000000 then perform mc.cmd_fail(me, mc.tc_translate('argument.pos.outofworld')); return null; end if;
  return array[b.px, b.py, b.pz];
end $$;

-- the state of a block_state argument value
create or replace function mc.cmd_block_input(v jsonb) returns text language sql immutable as $$ select v ->> 'state' $$;

-- a block predicate argument (the filter of /fill replace) as the text mc.fill_filter_states reads: `block[props]` or `#tag[props]`
create or replace function mc.cmd_pred_text(v jsonb) returns text language sql immutable as $$
  select coalesce(v ->> 'block', '#' || (v ->> 'tag')) || case when v -> 'props' = '{}'::jsonb then '' else '[' || (select string_agg(key || '=' || (value #>> '{}'), ',' order by key) from jsonb_each(v -> 'props')) || ']' end $$;

-- Level.destroyBlock(pos, true): the break effect to everybody within 64 blocks (not for fire), the block's loot (no tool), the cell becomes air (water for a waterlogged block).
-- The broadcast of the tick must not send the effect again: an actor row for every connection suppresses it (sql/432).
create or replace function mc.destroy_block(bx int, yy int, bz int) returns boolean language plpgsql as $$
declare dim text := 'minecraft:overworld'; st text := mc.get_block(dim, bx, yy, bz); ns text;
begin
  if st is null or mc.is_air(st) then return false; end if;
  if split_part(st, '[', 1) not in ('minecraft:fire', 'minecraft:soul_fire') then perform mc.level_event_near(2001, bx, yy, bz, mc.block_state_id(st)); end if;
  perform mc.block_drops(null, bx, yy, bz, st, null);
  ns := case when st like '%waterlogged=true%' then 'minecraft:water[level=0]' when st like 'minecraft:water%' or st like 'minecraft:lava%' then st else 'minecraft:air' end;
  insert into mc.block_actor select dim, bx, yy, bz, c.conn_id from net.conn c where c.state = 'play' and not c.closing;
  return mc.set_block(dim, bx, yy, bz, ns);
end $$;

------------------------------------------------------------------------------------------------ /setblock
create or replace function mc.cmd_run_setblock(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare dim text := 'minecraft:overworld'; pos int[]; mode text := coalesce(nullif(split_part(sig, '/', 4), ''), 'replace'); new_state text := mc.cmd_block_input(args -> 'block'); cur text; flag boolean := true;
        old text; ok boolean; is_strict boolean := mode = 'strict';
begin
  pos := mc.cmd_pos_loaded(me, args -> 'pos'); if pos is null then return; end if;
  cur := coalesce(mc.get_block(dim, pos[1], pos[2], pos[3]), 'minecraft:air');
  if mode = 'keep' and not mc.is_air(cur) then perform mc.cmd_fail(me, mc.tc_translate('commands.setblock.failed')); return; end if;
  if mode = 'destroy' then
    perform mc.destroy_block(pos[1], pos[2], pos[3]);
    flag := not mc.is_air(new_state) or not mc.is_air(coalesce(mc.get_block(dim, pos[1], pos[2], pos[3]), 'minecraft:air'));
  end if;
  old := coalesce(mc.get_block(dim, pos[1], pos[2], pos[3]), 'minecraft:air');
  if flag then
    -- (vanilla's setBlock without the destroy flag sends no break effect: the actor rows keep the broadcast from sending one)
    if mode <> 'destroy' then insert into mc.block_actor select dim, pos[1], pos[2], pos[3], c.conn_id from net.conn c where c.state = 'play' and not c.closing; end if;
    ok := mc.set_block(dim, pos[1], pos[2], pos[3], new_state);
    if not ok then perform mc.cmd_fail(me, mc.tc_translate('commands.setblock.failed')); return; end if;
  end if;
  if not is_strict then perform mc.shape_neighbours(dim, pos[1], pos[2], pos[3]); end if;
  perform mc.cmd_success(me, mc.tc_translate('commands.setblock.success', array[mc.tc_arg_int(pos[1]), mc.tc_arg_int(pos[2]), mc.tc_arg_int(pos[3])]));
end $$;

------------------------------------------------------------------------------------------------ /fill
create or replace function mc.cmd_run_fill(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare dim text := 'minecraft:overworld'; a int[]; b int[]; parts text[] := string_to_array(sig, '/'); mode text; filt text; cnt bigint; lim int := mc.gamerule_get('max_block_modifications')::int;
        new_state text := mc.cmd_block_input(args -> 'block'); n int; is_strict boolean := false; wx int; wy int; wz int; cur text; filt_states text[];
begin
  a := mc.cmd_pos_loaded(me, args -> 'from'); if a is null then return; end if;
  b := mc.cmd_pos_loaded(me, args -> 'to'); if b is null then return; end if;
  cnt := (abs(a[1] - b[1]) + 1)::bigint * (abs(a[2] - b[2]) + 1) * (abs(a[3] - b[3]) + 1);
  if cnt > lim then perform mc.cmd_fail(me, mc.tc_translate('commands.fill.toobig', array[mc.tc_arg_int(lim), mc.tc_arg_int(cnt::int)])); return; end if;
  -- the path: fill/from/to/block[/mode[/filter[/mode2]]]
  mode := coalesce(nullif(parts[5], ''), 'replace');
  if mode = 'strict' then is_strict := true; mode := 'replace'; end if;
  if parts[6] is not null and parts[6] <> '' then filt := mc.cmd_pred_text(args -> 'filter'); if parts[7] in ('destroy', 'hollow', 'outline') then mode := parts[7]; elsif parts[7] = 'strict' then is_strict := true; end if; end if;
  if mode = 'destroy' then
    -- Mode.DESTROY (position by position, z, y, x): where the filter holds, the block is destroyed (effect, loot) and the new block placed; the count is the placements that changed a state
    filt_states := case when filt is null then null else mc.fill_filter_states(filt) end; n := 0;
    for wz in least(a[3], b[3]) .. greatest(a[3], b[3]) loop for wy in least(a[2], b[2]) .. greatest(a[2], b[2]) loop for wx in least(a[1], b[1]) .. greatest(a[1], b[1]) loop
      cur := coalesce(mc.get_block(dim, wx, wy, wz), 'minecraft:air');
      continue when filt_states is not null and not (cur = any (filt_states));
      perform mc.destroy_block(wx, wy, wz);
      insert into mc.block_actor select dim, wx, wy, wz, c.conn_id from net.conn c where c.state = 'play' and not c.closing;
      if mc.set_block(dim, wx, wy, wz, new_state) then n := n + 1; end if;
    end loop; end loop; end loop;
  else
    n := mc.fill_mode(dim, a[1], a[2], a[3], b[1], b[2], b[3], new_state, mode, filt);
  end if;
  if n = 0 then perform mc.cmd_fail(me, mc.tc_translate('commands.fill.failed')); return; end if;
  perform mc.cmd_success(me, mc.tc_translate('commands.fill.success', array[mc.tc_arg_int(n)]));
end $$;
