-- Block placement states (BlockItem.getPlacementState / Block.getStateForPlacement of the 26.3 classes).  Until now a block a player placed was always the block's DEFAULT
-- state: a log lay upright whatever face was clicked, stairs and furnaces ignored the player's direction, slabs did not merge.  mc.place_state computes the state vanilla
-- computes from the block's class (mc.dyn_state.chain, read from the jar by tools/gen_dynamics.sh), the clicked face, the cursor on that face, the player's yaw and pitch, its
-- sneaking state and the neighbours.  Without that data (no dyn_states.tsv) every placement stays the default state, as before.
--
-- The families are the classes' own rules (every number below was checked against a recording of the real server: tests/e2e/place_probe.py, compare_place.py):
--   RotatedPillarBlock (logs, wood, pillars, hay, bone, chains)   axis of the clicked face
--   SlabBlock                  bottom when the face is up or (not down and the cursor is in the lower half of the cell); double when the slab being clicked can be replaced
--   StairBlock                 facing = the player's direction, half like a slab, shape from the neighbours (getStairsShape)
--   furnaces, stonecutter, loom, lectern, carved pumpkin, glazed terracotta, repeaters   facing = the opposite of the player's direction;  fence gates: the player's direction
--   anvils (clockwise of it), campfires; chests (type single / left / right from a neighbouring chest, sneaking), ender chests
--   dispensers, droppers, observers, pistons, barrels, command blocks   the opposite of the nearest looking direction;  hoppers: the opposite of the clicked face
--   trapdoors                  the clicked face on a side face, else the opposite of the player's direction; half from the cursor or the face
--   standing signs, banners, skulls   rotation 0-15 from the yaw; wall versions via the nearest looking directions
--   torches, lanterns, ladders, levers, buttons   the nearest looking directions with canSurvive (sturdy faces)
--   fences, glass panes, iron bars   the connections to the four neighbours
-- Doors and beds (two blocks), walls (tall / low), vines and multiface blocks, snow layers, candles, leaves (persistent), tall plants, rails keep their default state.

create or replace function mc.cl(ch text, cls text) returns boolean language sql immutable as $$ select position('>' || cls || '>' in '>' || ch || '>') > 0 $$;

create or replace function mc.state_with(p_block text, p_props text) returns text language plpgsql stable as $$
declare s text; kv text;
begin
  select bs.name into s from ref.block b join ref.block_state bs on bs.state_id = b.default_state where b.name = p_block;
  foreach kv in array string_to_array(coalesce(p_props, ''), ',') loop
    continue when kv = '';
    s := regexp_replace(s, '([\[,])' || split_part(kv, '=', 1) || '=[^,\]]*', '\1' || kv);
  end loop;
  return s;
end $$;

create or replace function mc.st_set(p_state text, p_key text, p_val text) returns text language sql immutable as $$
  select regexp_replace(p_state, '([\[,])' || p_key || '=[^,\]]*', '\1' || p_key || '=' || p_val) $$;
create or replace function mc.st_get(p_state text, p_key text) returns text language sql immutable as $$
  select substring(p_state from '[\[,]' || p_key || '=([^,\]]*)') $$;

-- directions
create or replace function mc.dir_h(p_yaw real) returns text language sql immutable as $$           -- Direction.fromYRot
  select (array['south', 'west', 'north', 'east'])[1 + (floor(p_yaw::float8 / 90.0 + 0.5)::int & 3)] $$;
create or replace function mc.dir_opp(d text) returns text language sql immutable as $$
  select case d when 'north' then 'south' when 'south' then 'north' when 'east' then 'west' when 'west' then 'east' when 'up' then 'down' else 'up' end $$;
create or replace function mc.dir_cw(d text) returns text language sql immutable as $$
  select case d when 'north' then 'east' when 'east' then 'south' when 'south' then 'west' else 'north' end $$;
create or replace function mc.dir_ccw(d text) returns text language sql immutable as $$
  select case d when 'north' then 'west' when 'west' then 'south' when 'south' then 'east' else 'north' end $$;
create or replace function mc.dir_dx(d text) returns int language sql immutable as $$ select case d when 'east' then 1 when 'west' then -1 else 0 end $$;
create or replace function mc.dir_dy(d text) returns int language sql immutable as $$ select case d when 'up' then 1 when 'down' then -1 else 0 end $$;
create or replace function mc.dir_dz(d text) returns int language sql immutable as $$ select case d when 'south' then 1 when 'north' then -1 else 0 end $$;
create or replace function mc.dir_horizontal(d text) returns boolean language sql immutable as $$ select d in ('north', 'south', 'east', 'west') $$;
create or replace function mc.dir_axis(d text) returns text language sql immutable as $$ select case when d in ('east', 'west') then 'x' when d in ('up', 'down') then 'y' else 'z' end $$;
-- the six directions, the order of the sturdy-face strings of mc.dyn_state (DOWN UP NORTH SOUTH WEST EAST)
create or replace function mc.dir_idx(d text) returns int language sql immutable as $$ select case d when 'down' then 1 when 'up' then 2 when 'north' then 3 when 'south' then 4 when 'west' then 5 else 6 end $$;

-- Direction.orderedByNearest(player): the six directions, the one the player looks along most first (Mth.sin / cos are table lookups in Java: the same values to 1e-4)
create or replace function mc.nearest_dirs(p_yaw real, p_pitch real) returns text[] language plpgsql immutable as $$
declare f float8 := p_pitch::float8 * pi() / 180.0; f1 float8 := -p_yaw::float8 * pi() / 180.0;
        f2 float8 := sin(f); f3 float8 := cos(f); f4 float8 := sin(f1); f5 float8 := cos(f1);
        flag boolean := f4 > 0; flag1 boolean := f2 < 0; flag2 boolean := f5 > 0;
        f6 float8 := case when flag then f4 else -f4 end; f7 float8 := case when flag1 then -f2 else f2 end; f8 float8 := case when flag2 then f5 else -f5 end;
        f9 float8; f10 float8; d text := case when flag then 'east' else 'west' end; d1 text := case when flag1 then 'up' else 'down' end; d2 text := case when flag2 then 'south' else 'north' end;
        a text; b text; c text;
begin
  f9 := f6 * f3; f10 := f8 * f3;
  if f6 > f8 then
    if f7 > f9 then a := d1; b := d; c := d2;
    elsif f10 > f7 then a := d; b := d2; c := d1;
    else a := d; b := d1; c := d2; end if;
  elsif f7 > f10 then a := d1; b := d2; c := d;
  elsif f9 > f7 then a := d2; b := d; c := d1;
  else a := d2; b := d1; c := d; end if;
  return array[a, b, c, mc.dir_opp(c), mc.dir_opp(b), mc.dir_opp(a)];
end $$;

-- BlockPlaceContext.getNearestLookingDirections: unless the clicked block itself is replaced, the opposite of the clicked face comes first
create or replace function mc.place_dirs(p_yaw real, p_pitch real, p_face text, p_replace_clicked boolean) returns text[] language plpgsql immutable as $$
declare ds text[] := mc.nearest_dirs(p_yaw, p_pitch); o text := mc.dir_opp(p_face); i int;
begin
  if p_replace_clicked then return ds; end if;
  i := array_position(ds, o);
  return array[o] || (select array_agg(x order by n) from unnest(ds) with ordinality t(x, n) where x <> o);
end $$;

-- is the face of the block's state sturdy?  (BlockState.isFaceSturdy with SupportType.FULL ('f') or CENTER ('c'))
create or replace function mc.face_sturdy(p_state text, p_dir text, p_kind text default 'f') returns boolean language sql stable as $$
  select coalesce((select substr(case p_kind when 'c' then s.sc else s.sf end, mc.dir_idx(p_dir), 1) = '1' from mc.dyn_state s where s.name = p_state), false) $$;

create or replace function mc.is_water_source(p_state text) returns boolean language sql immutable as $$ select p_state = 'minecraft:water[level=0]' $$;

-- the neighbour of a cell
create or replace function mc.nb(p_dim text, x int, y int, z int, d text) returns text language sql stable as $$
  select mc.get_block(p_dim, x + mc.dir_dx(d), y + mc.dir_dy(d), z + mc.dir_dz(d)) $$;

-- can the block (a state) survive at the cell?  Only the rules the families below need
create or replace function mc.place_survives(p_dim text, st text, x int, y int, z int) returns boolean language plpgsql stable as $$
declare ch text; f text; sup text; k text;
begin
  select s.chain into ch from mc.dyn_state s where s.name = st;
  f := mc.st_get(st, 'facing');
  if mc.cl(ch, 'RedstoneWallTorchBlock') or mc.cl(ch, 'WallTorchBlock') then         -- the support behind it: a full face towards the torch
    return mc.face_sturdy(mc.nb(p_dim, x, y, z, mc.dir_opp(f)), f, 'f');
  elsif mc.cl(ch, 'RedstoneTorchBlock') or mc.cl(ch, 'TorchBlock') then               -- standing: the centre of the top of the block below
    return mc.face_sturdy(mc.nb(p_dim, x, y, z, 'down'), 'up', 'c');
  elsif mc.cl(ch, 'LanternBlock') then
    return case when mc.st_get(st, 'hanging') = 'true' then mc.face_sturdy(mc.nb(p_dim, x, y, z, 'up'), 'down', 'c') else mc.face_sturdy(mc.nb(p_dim, x, y, z, 'down'), 'up', 'c') end;
  elsif mc.cl(ch, 'LadderBlock') then
    return mc.face_sturdy(mc.nb(p_dim, x, y, z, mc.dir_opp(f)), f, 'f');
  elsif mc.cl(ch, 'WallSignBlock') then
    return coalesce((select s.solid from mc.dyn_state s where s.name = mc.nb(p_dim, x, y, z, mc.dir_opp(f))), false);
  elsif mc.cl(ch, 'StandingSignBlock') or mc.cl(ch, 'BannerBlock') then
    return coalesce((select s.solid from mc.dyn_state s where s.name = mc.nb(p_dim, x, y, z, 'down')), false);
  elsif mc.cl(ch, 'WallSkullBlock') then                                         -- AbstractSkullBlock: attaches to anything that is not replaceable
    return not mc.cell_replaceable(coalesce(mc.nb(p_dim, x, y, z, mc.dir_opp(f)), 'minecraft:air'));
  elsif mc.cl(ch, 'WallBannerBlock') then
    return coalesce((select s.solid from mc.dyn_state s where s.name = mc.nb(p_dim, x, y, z, mc.dir_opp(f))), false);
  elsif mc.cl(ch, 'ButtonBlock') or mc.cl(ch, 'LeverBlock') then                       -- FaceAttachedHorizontalDirectionalBlock.canAttach: the connected direction's opposite
    k := mc.st_get(st, 'face');
    f := case k when 'floor' then 'up' when 'ceiling' then 'down' else mc.st_get(st, 'facing') end;
    return mc.face_sturdy(mc.nb(p_dim, x, y, z, mc.dir_opp(f)), f, 'f');
  end if;
  return true;
end $$;

-- BlockBehaviour.canBeReplaced(state, context): the clicked block is replaced (and the new block goes into ITS cell) when it can be replaced and is not the item's own block,
-- and for slabs when the click is on the half that is still free
create or replace function mc.place_replaces_clicked(p_clicked text, p_block text, p_face text, p_cy_clicked float8) returns boolean language plpgsql stable as $$
declare ch text; t text;
begin
  if p_clicked is null then return false; end if;
  select s.chain into ch from mc.dyn_state s where s.name = p_clicked;
  if mc.cl(ch, 'SlabBlock') or false then
    if split_part(p_clicked, '[', 1) <> p_block then return false; end if;
    t := mc.st_get(p_clicked, 'type');
    if t = 'double' then return false; end if;
    return case when t = 'bottom' then p_face = 'up' or (p_cy_clicked > 0.5 and mc.dir_horizontal(p_face)) else p_face = 'down' or (p_cy_clicked <= 0.5 and mc.dir_horizontal(p_face)) end;
  end if;
  return coalesce((select s.repl from mc.dyn_state s where s.name = p_clicked), false) and split_part(p_clicked, '[', 1) <> p_block;
end $$;

-- StairBlock.getStairsShape
create or replace function mc.stairs_shape(p_dim text, st text, x int, y int, z int) returns text language plpgsql stable as $$
declare facing text := mc.st_get(st, 'facing'); half text := mc.st_get(st, 'half'); b text; bf text; f text; ff text;
begin
  b := mc.nb(p_dim, x, y, z, facing);
  if exists (select 1 from mc.dyn_state s where s.name = b and mc.cl(s.chain, 'StairBlock')) and mc.st_get(b, 'half') = half then
    bf := mc.st_get(b, 'facing');
    if mc.dir_axis(bf) <> mc.dir_axis(facing) and mc.stairs_can_take(p_dim, st, x, y, z, mc.dir_opp(bf)) then
      return case when bf = mc.dir_ccw(facing) then 'outer_left' else 'outer_right' end;
    end if;
  end if;
  f := mc.nb(p_dim, x, y, z, mc.dir_opp(facing));
  if exists (select 1 from mc.dyn_state s where s.name = f and mc.cl(s.chain, 'StairBlock')) and mc.st_get(f, 'half') = half then
    ff := mc.st_get(f, 'facing');
    if mc.dir_axis(ff) <> mc.dir_axis(facing) and mc.stairs_can_take(p_dim, st, x, y, z, ff) then
      return case when ff = mc.dir_ccw(facing) then 'inner_left' else 'inner_right' end;
    end if;
  end if;
  return 'straight';
end $$;
create or replace function mc.stairs_can_take(p_dim text, st text, x int, y int, z int, d text) returns boolean language plpgsql stable as $$
declare o text := mc.nb(p_dim, x, y, z, d);
begin
  return not (exists (select 1 from mc.dyn_state s where s.name = o and mc.cl(s.chain, 'StairBlock')) and mc.st_get(o, 'facing') = mc.st_get(st, 'facing') and mc.st_get(o, 'half') = mc.st_get(st, 'half'));
end $$;

-- fence and pane connections: does the neighbour in direction d connect?
create or replace function mc.connects(p_dim text, kind text, own_block text, x int, y int, z int, d text) returns boolean language plpgsql stable as $$
declare nbs text := mc.nb(p_dim, x, y, z, d); ch text; solid_side boolean; exc boolean; same boolean;
begin
  if nbs is null then return false; end if;
  select s.chain into ch from mc.dyn_state s where s.name = nbs;
  solid_side := mc.face_sturdy(nbs, mc.dir_opp(d), 'f');
  exc := mc.cl(ch, 'LeavesBlock') or split_part(nbs, '[', 1) in ('minecraft:barrier', 'minecraft:carved_pumpkin', 'minecraft:jack_o_lantern', 'minecraft:melon', 'minecraft:pumpkin')
         or mc.cl(ch, 'ShulkerBoxBlock') or split_part(nbs, '[', 1) like '%\_shulker\_box';
  if kind = 'fence' then
    same := mc.cl(ch, 'FenceBlock') and ((split_part(nbs, '[', 1) = 'minecraft:nether_brick_fence') = (own_block = 'minecraft:nether_brick_fence'));
    return (not exc and solid_side) or same
           or (mc.cl(ch, 'FenceGateBlock') and mc.dir_axis(mc.st_get(nbs, 'facing')) = mc.dir_axis(mc.dir_cw(d)));
  else   -- IronBarsBlock.attachsTo: a solid side, another pane or bars, a wall
    return (not exc and solid_side) or mc.cl(ch, 'IronBarsBlock') or mc.cl(ch, 'WallBlock');
  end if;
end $$;

-- ChestBlock: the neighbouring chest a new one pairs with (candidatePartnerFacing)
create or replace function mc.chest_partner_facing(p_dim text, own_block text, x int, y int, z int, d text) returns text language sql stable as $$
  select case when split_part(s, '[', 1) = own_block and mc.st_get(s, 'type') = 'single' then mc.st_get(s, 'facing') end from (select mc.nb(p_dim, x, y, z, d) as s) q $$;

-- The state of the block to place at the target cell (tx, ty, tz).  p_face: the clicked face; p_cx, p_cy, p_cz: the cursor's position inside the TARGET cell; p_replace_clicked: the clicked block is
-- being replaced (the target IS the clicked cell).  NULL: the block cannot be placed there (nothing survives).
create or replace function mc.place_state(p_dim text, p_block text, tx int, ty int, tz int, p_face text, p_cx float8, p_cy float8, p_cz float8, p_replace_clicked boolean, p_yaw real, p_pitch real, p_sneak boolean) returns text
language plpgsql stable as $$
declare st text; ch text; at_target text; wl boolean; hd text; opp text; ds text[]; d text; cand text; t text; rot int; chains text; n text; ax text; sh text; own text; k text; ok boolean;
begin
  select bs.name into st from ref.block b join ref.block_state bs on bs.state_id = b.default_state where b.name = p_block;
  if st is null then return null; end if;
  select s.chain into ch from mc.dyn_state s where s.name = st;
  if ch is null then return st; end if;                                   -- no dynamics data: the default state, as before
  at_target := mc.get_block(p_dim, tx, ty, tz);
  hd := mc.dir_h(p_yaw);
  wl := mc.is_water_source(at_target);
  if mc.cl(ch, 'StairBlock') then
    st := mc.st_set(st, 'facing', hd);
    st := mc.st_set(st, 'half', case when p_face = 'down' or (p_face <> 'up' and p_cy > 0.5) then 'top' else 'bottom' end);
    st := mc.st_set(st, 'waterlogged', case when wl then 'true' else 'false' end);
    return mc.st_set(st, 'shape', mc.stairs_shape(p_dim, st, tx, ty, tz));
  elsif mc.cl(ch, 'SlabBlock') then
    if at_target is not null and split_part(at_target, '[', 1) = p_block and mc.st_get(at_target, 'type') <> 'double' then
      return mc.st_set(mc.st_set(st, 'type', 'double'), 'waterlogged', 'false');
    end if;
    return mc.st_set(mc.st_set(st, 'type', case when p_face <> 'down' and (p_face = 'up' or p_cy <= 0.5) then 'bottom' else 'top' end), 'waterlogged', case when wl then 'true' else 'false' end);
  elsif mc.cl(ch, 'RotatedPillarBlock') or mc.cl(ch, 'InfestedRotatedPillarBlock') then
    st := mc.st_set(st, 'axis', mc.dir_axis(p_face));
    return case when st like '%waterlogged=%' then mc.st_set(st, 'waterlogged', case when wl then 'true' else 'false' end) else st end;
  elsif mc.cl(ch, 'ChestBlock') or mc.cl(ch, 'CopperChestBlock') or mc.cl(ch, 'TrappedChestBlock') then
    opp := mc.dir_opp(hd); t := 'single';
    if mc.dir_horizontal(p_face) and p_sneak then
      cand := mc.chest_partner_facing(p_dim, p_block, tx, ty, tz, mc.dir_opp(p_face));
      if cand is not null and mc.dir_axis(cand) <> mc.dir_axis(p_face) then opp := cand; t := case when mc.dir_ccw(cand) = mc.dir_opp(p_face) then 'right' else 'left' end; end if;
    end if;
    if t = 'single' and not p_sneak then
      if opp = mc.chest_partner_facing(p_dim, p_block, tx, ty, tz, mc.dir_cw(opp)) then t := 'left';
      elsif opp = mc.chest_partner_facing(p_dim, p_block, tx, ty, tz, mc.dir_ccw(opp)) then t := 'right'; end if;
    end if;
    return mc.st_set(mc.st_set(mc.st_set(st, 'facing', opp), 'type', t), 'waterlogged', case when wl then 'true' else 'false' end);
  elsif mc.cl(ch, 'EnderChestBlock') then
    return mc.st_set(mc.st_set(st, 'facing', mc.dir_opp(hd)), 'waterlogged', case when wl then 'true' else 'false' end);
  elsif mc.cl(ch, 'AbstractFurnaceBlock') or mc.cl(ch, 'StonecutterBlock') or mc.cl(ch, 'LoomBlock') or mc.cl(ch, 'LecternBlock')
        or mc.cl(ch, 'CarvedPumpkinBlock') or mc.cl(ch, 'GlazedTerracottaBlock') or mc.cl(ch, 'DiodeBlock')  then
    return mc.st_set(st, 'facing', mc.dir_opp(hd));
  elsif mc.cl(ch, 'FenceGateBlock') then
    return mc.st_set(mc.st_set(st, 'facing', hd), 'in_wall',
             case when coalesce((select s.chain like 'WallBlock%' from mc.dyn_state s where s.name = mc.nb(p_dim, tx, ty, tz, mc.dir_cw(hd))), false)
                    or coalesce((select s.chain like 'WallBlock%' from mc.dyn_state s where s.name = mc.nb(p_dim, tx, ty, tz, mc.dir_ccw(hd))), false) then 'true' else 'false' end);
  elsif mc.cl(ch, 'AnvilBlock') then
    return mc.st_set(st, 'facing', mc.dir_cw(hd));
  elsif mc.cl(ch, 'CampfireBlock') then
    return mc.st_set(mc.st_set(mc.st_set(mc.st_set(st, 'facing', hd), 'waterlogged', case when wl then 'true' else 'false' end), 'lit', case when wl then 'false' else 'true' end),
                     'signal_fire', case when mc.nb(p_dim, tx, ty, tz, 'down') = 'minecraft:hay_block[axis=y]' then 'true' else 'false' end);
  elsif mc.cl(ch, 'ObserverBlock') then                                  -- (recorded) faces the way the player looks
    return mc.st_set(st, 'facing', (mc.nearest_dirs(p_yaw, p_pitch))[1]);
  elsif mc.cl(ch, 'BarrelBlock') or mc.cl(ch, 'DispenserBlock') or mc.cl(ch, 'PistonBaseBlock') or mc.cl(ch, 'CommandBlock') then
    ds := mc.nearest_dirs(p_yaw, p_pitch);
    return mc.st_set(st, 'facing', mc.dir_opp(ds[1]));
  elsif mc.cl(ch, 'BellBlock') then                                        -- (recorded) floor and ceiling bells face the player's direction; wall bells are not modelled
    return mc.st_set(mc.st_set(st, 'facing', hd), 'attachment', case when p_face = 'down' then 'ceiling' else 'floor' end);
  elsif mc.cl(ch, 'HopperBlock') then
    d := mc.dir_opp(p_face);
    return mc.st_set(st, 'facing', case when d = 'up' then 'down' else d end);
  elsif mc.cl(ch, 'TrapDoorBlock') then
    if not p_replace_clicked and mc.dir_horizontal(p_face) then
      st := mc.st_set(mc.st_set(st, 'facing', p_face), 'half', case when p_cy > 0.5 then 'top' else 'bottom' end);
    else
      st := mc.st_set(mc.st_set(st, 'facing', mc.dir_opp(hd)), 'half', case when p_face = 'up' then 'bottom' else 'top' end);
    end if;
    return mc.st_set(st, 'waterlogged', case when wl then 'true' else 'false' end);
  elsif mc.cl(ch, 'StandingSignBlock') or mc.cl(ch, 'BannerBlock') or mc.cl(ch, 'SkullBlock') or mc.cl(ch, 'PlayerHeadBlock')
        or mc.cl(ch, 'WallSignBlock') or mc.cl(ch, 'WallBannerBlock') or mc.cl(ch, 'WallSkullBlock') or mc.cl(ch, 'PlayerWallHeadBlock') or mc.cl(ch, 'PiglinWallSkullBlock') then
    -- the item is the STANDING block (the registry's default state is the item's block for these); the wall variant is chosen by the nearest looking directions
    return mc.place_standing_or_wall(p_dim, p_block, st, tx, ty, tz, p_face, p_replace_clicked, p_yaw, p_pitch);
  elsif mc.cl(ch, 'TorchBlock') or mc.cl(ch, 'RedstoneTorchBlock') then
    return mc.place_standing_or_wall(p_dim, p_block, st, tx, ty, tz, p_face, p_replace_clicked, p_yaw, p_pitch);
  elsif mc.cl(ch, 'LanternBlock') then
    foreach d in array mc.place_dirs(p_yaw, p_pitch, p_face, p_replace_clicked) loop
      continue when mc.dir_axis(d) <> 'y';
      n := mc.st_set(mc.st_set(st, 'hanging', case when d = 'up' then 'true' else 'false' end), 'waterlogged', case when wl then 'true' else 'false' end);
      if mc.place_survives(p_dim, n, tx, ty, tz) then return n; end if;
    end loop;
    return null;
  elsif mc.cl(ch, 'LadderBlock') then
    if not p_replace_clicked and mc.dir_horizontal(p_face) then
      n := mc.st_set(mc.st_set(st, 'facing', p_face), 'waterlogged', case when wl then 'true' else 'false' end);
      if mc.place_survives(p_dim, n, tx, ty, tz) then return n; end if;
    end if;
    foreach d in array mc.place_dirs(p_yaw, p_pitch, p_face, p_replace_clicked) loop
      continue when not mc.dir_horizontal(d);
      n := mc.st_set(mc.st_set(st, 'facing', mc.dir_opp(d)), 'waterlogged', case when wl then 'true' else 'false' end);
      if mc.place_survives(p_dim, n, tx, ty, tz) then return n; end if;
    end loop;
    return null;
  elsif mc.cl(ch, 'ButtonBlock') or mc.cl(ch, 'LeverBlock') or mc.cl(ch, 'GrindstoneBlock') then
    foreach d in array mc.place_dirs(p_yaw, p_pitch, p_face, p_replace_clicked) loop
      if mc.dir_axis(d) = 'y' then n := mc.st_set(mc.st_set(st, 'face', case when d = 'up' then 'ceiling' else 'floor' end), 'facing', hd);
      else n := mc.st_set(mc.st_set(st, 'face', 'wall'), 'facing', mc.dir_opp(d)); end if;
      if mc.place_survives(p_dim, n, tx, ty, tz) then return n; end if;
    end loop;
    return null;
  elsif mc.cl(ch, 'DoorBlock') then
    if not mc.cell_replaceable(coalesce(mc.get_block(p_dim, tx, ty + 1, tz), 'minecraft:air')) then return null; end if;
    return mc.st_set(mc.st_set(st, 'facing', hd), 'hinge', mc.door_hinge(p_dim, tx, ty, tz, hd, p_cx, p_cz));
  elsif mc.cl(ch, 'FenceBlock') then
    own := p_block;
    st := mc.st_set(st, 'waterlogged', case when wl then 'true' else 'false' end);
    foreach d in array array['north', 'east', 'south', 'west'] loop
      st := mc.st_set(st, d, case when mc.connects(p_dim, 'fence', own, tx, ty, tz, d) then 'true' else 'false' end);
    end loop;
    return st;
  elsif mc.cl(ch, 'IronBarsBlock') then
    own := p_block;
    st := mc.st_set(st, 'waterlogged', case when wl then 'true' else 'false' end);
    foreach d in array array['north', 'east', 'south', 'west'] loop
      st := mc.st_set(st, d, case when mc.connects(p_dim, 'pane', own, tx, ty, tz, d) then 'true' else 'false' end);
    end loop;
    return st;
  end if;
  return st;
end $$;

-- StandingAndWallBlockItem (torches, signs, banners, skulls): through the nearest looking directions, the standing block when the direction is UP, otherwise the wall block facing the
-- opposite of the direction; the first one that survives wins.  A DOWN direction is skipped (the attachment direction).
create or replace function mc.place_standing_or_wall(p_dim text, p_block text, p_st text, tx int, ty int, tz int, p_face text, p_replace_clicked boolean, p_yaw real, p_pitch real) returns text language plpgsql stable as $$
declare wall_block text; wall_st text; d text; n text; w text; rot int; wl boolean := mc.is_water_source(mc.get_block(p_dim, tx, ty, tz)); stand boolean; is_sign boolean; is_ban boolean;
begin
  wall_block := case
    when p_block like 'minecraft:%\_hanging\_sign' then null
    when p_block like 'minecraft:%\_sign' then replace(p_block, '_sign', '_wall_sign')
    when p_block like 'minecraft:%\_banner' then replace(p_block, '_banner', '_wall_banner')
    when p_block like 'minecraft:%\_skull' then replace(p_block, '_skull', '_wall_skull')
    when p_block like 'minecraft:%\_head' and p_block <> 'minecraft:player_head' then replace(p_block, '_head', '_wall_head')
    when p_block = 'minecraft:player_head' then 'minecraft:player_wall_head'
    when p_block = 'minecraft:torch' then 'minecraft:wall_torch'
    when p_block = 'minecraft:soul_torch' then 'minecraft:soul_wall_torch'
    when p_block = 'minecraft:redstone_torch' then 'minecraft:redstone_wall_torch'
    when p_block = 'minecraft:copper_torch' then 'minecraft:copper_wall_torch' end;
  if wall_block is null then return p_st; end if;
  select bs.name into wall_st from ref.block b join ref.block_state bs on bs.state_id = b.default_state where b.name = wall_block;
  if wall_st is null then return p_st; end if;
  -- the standing block's state (signs and banners and skulls turn by the yaw)
  n := p_st;
  if n like '%[%rotation=%' then
    rot := (floor((case when p_block like '%\_skull' or p_block like '%\_head' then 0.0 else 180.0 end + p_yaw::float8) * 16.0 / 360.0 + 0.5)::int) & 15;
    n := mc.st_set(n, 'rotation', rot::text);
  end if;
  if n like '%waterlogged=%' then n := mc.st_set(n, 'waterlogged', case when wl then 'true' else 'false' end); end if;
  -- the wall block's own getStateForPlacement: the first looking direction that survives
  w := null;
  foreach d in array mc.place_dirs(p_yaw, p_pitch, p_face, p_replace_clicked) loop
    continue when not mc.dir_horizontal(d);
    w := mc.st_set(wall_st, 'facing', mc.dir_opp(d));
    if w like '%waterlogged=%' then w := mc.st_set(w, 'waterlogged', case when wl then 'true' else 'false' end); end if;
    exit when mc.place_survives(p_dim, w, tx, ty, tz);
    w := null;
  end loop;
  foreach d in array mc.place_dirs(p_yaw, p_pitch, p_face, p_replace_clicked) loop
    continue when d = 'down';
    if d = 'up' then
      if mc.place_survives(p_dim, n, tx, ty, tz) then return n; end if;
    elsif w is not null and mc.place_survives(p_dim, w, tx, ty, tz) then return w; end if;
  end loop;
  return null;
end $$;

-- BlockBehaviour.canBeReplaced() of the state at a cell: the jar's flag when the dynamics data is loaded, the short list of sql/410 otherwise
create or replace function mc.cell_replaceable(p_state text) returns boolean language sql stable as $$
  select coalesce((select s.repl from mc.dyn_state s where s.name = p_state), mc.replaceable(p_state)) $$;

-- is the state's collision shape a full block?
create or replace function mc.full_block(p_state text) returns boolean language sql stable as $$
  select coalesce((select h.kind = 1 from mc.dyn_state s join mc.dyn_shape h on h.id = s.coll where s.name = p_state), false) $$;

-- DoorBlock.getHinge
create or replace function mc.door_hinge(p_dim text, x int, y int, z int, dir text, cx float8, cz float8) returns text language plpgsql stable as $$
declare ccw text := mc.dir_ccw(dir); cw text := mc.dir_cw(dir);
        s1 text := mc.get_block(p_dim, x + mc.dir_dx(ccw), y, z + mc.dir_dz(ccw)); s2 text := mc.get_block(p_dim, x + mc.dir_dx(ccw), y + 1, z + mc.dir_dz(ccw));
        s3 text := mc.get_block(p_dim, x + mc.dir_dx(cw), y, z + mc.dir_dz(cw));  s4 text := mc.get_block(p_dim, x + mc.dir_dx(cw), y + 1, z + mc.dir_dz(cw));
        i int; f1 boolean; f3 boolean; j int := mc.dir_dx(dir); k int := mc.dir_dz(dir);
begin
  i := (case when mc.full_block(s1) then -1 else 0 end) + (case when mc.full_block(s2) then -1 else 0 end) + (case when mc.full_block(s3) then 1 else 0 end) + (case when mc.full_block(s4) then 1 else 0 end);
  f1 := coalesce(split_part(s1, '[', 1) like 'minecraft:%\_door' and mc.st_get(s1, 'half') = 'lower', false);
  f3 := coalesce(split_part(s3, '[', 1) like 'minecraft:%\_door' and mc.st_get(s3, 'half') = 'lower', false);
  if (not f1 or f3) and i <= 0 then
    if (not f3 or f1) and i >= 0 then
      return case when (j >= 0 or not (cz < 0.5)) and (j <= 0 or not (cz > 0.5)) and (k >= 0 or not (cx > 0.5)) and (k <= 0 or not (cx < 0.5)) then 'left' else 'right' end;
    else return 'left'; end if;
  else return 'right'; end if;
end $$;

-- Block.updateShape for the neighbour at direction d (seen from the block at x, y, z) that just changed: the states of the families whose shape follows their neighbours
create or replace function mc.update_shape(p_dim text, st text, x int, y int, z int, d text) returns text language plpgsql stable as $$
declare ch text; own text := split_part(st, '[', 1); f text; ns text := mc.nb(p_dim, x, y, z, d); t text; nt text; o text; wl1 boolean; wl2 boolean; conn text;
begin
  select s.chain into ch from mc.dyn_state s where s.name = st;
  if ch is null then return st; end if;
  if mc.cl(ch, 'FenceBlock') then
    return case when mc.dir_horizontal(d) then mc.st_set(st, d, case when mc.connects(p_dim, 'fence', own, x, y, z, d) then 'true' else 'false' end) else st end;
  elsif mc.cl(ch, 'IronBarsBlock') then
    return case when mc.dir_horizontal(d) then mc.st_set(st, d, case when mc.connects(p_dim, 'pane', own, x, y, z, d) then 'true' else 'false' end) else st end;
  elsif mc.cl(ch, 'StairBlock') then
    return case when mc.dir_horizontal(d) then mc.st_set(st, 'shape', mc.stairs_shape(p_dim, st, x, y, z)) else st end;
  elsif mc.cl(ch, 'FenceGateBlock') then
    f := mc.st_get(st, 'facing');
    if mc.dir_axis(d) = mc.dir_axis(mc.dir_cw(f)) then
      return mc.st_set(st, 'in_wall', case when coalesce((select s.chain like '%WallBlock%' from mc.dyn_state s where s.name = ns), false)
                                             or coalesce((select s.chain like '%WallBlock%' from mc.dyn_state s where s.name = mc.nb(p_dim, x, y, z, mc.dir_opp(d))), false) then 'true' else 'false' end);
    end if;
    return st;
  elsif mc.cl(ch, 'ChestBlock') then
    t := mc.st_get(st, 'type');
    conn := case t when 'left' then mc.dir_cw(mc.st_get(st, 'facing')) else mc.dir_ccw(mc.st_get(st, 'facing')) end;
    if ns is not null and split_part(ns, '[', 1) = own and mc.dir_horizontal(d) then
      nt := mc.st_get(ns, 'type');
      if t = 'single' and nt <> 'single' and mc.st_get(st, 'facing') = mc.st_get(ns, 'facing')
         and (case nt when 'left' then mc.dir_cw(mc.st_get(ns, 'facing')) else mc.dir_ccw(mc.st_get(ns, 'facing')) end) = mc.dir_opp(d) then
        return mc.st_set(st, 'type', case nt when 'left' then 'right' else 'left' end);
      end if;
    elsif conn = d then
      return mc.st_set(st, 'type', 'single');
    end if;
    return st;
  end if;
  return st;
end $$;

-- Level.setBlock's updateShape pass: the six neighbours of the changed cell recompute their shape, in vanilla's order (west, east, north, south, down, up), each seeing the world the earlier ones left
create or replace function mc.shape_neighbours(p_dim text, x int, y int, z int) returns void language plpgsql as $$
declare d text; s text; n text; nx int; ny int; nz int;
begin
  foreach d in array array['west', 'east', 'north', 'south', 'down', 'up'] loop
    nx := x + mc.dir_dx(d); ny := y + mc.dir_dy(d); nz := z + mc.dir_dz(d);
    s := mc.get_block(p_dim, nx, ny, nz);
    continue when s is null or s like 'minecraft:air';
    n := mc.update_shape(p_dim, s, nx, ny, nz, mc.dir_opp(d));
    if n is distinct from s then perform mc.set_block(p_dim, nx, ny, nz, n); end if;
  end loop;
end $$;
