-- World dynamics, part 7: block support (Block.canSurvive and the updateShape that breaks a block whose support went away).
--
-- Vanilla asks every block class: BlockState.canSurvive(level, pos), and its updateShape returns air when the answer is no (a torch, a flower, a door half, a carpet ...).  The jar
-- cannot be asked for each class's answer without a level, so the families that matter are read from the bytecode (javap -c, the methods canSurvive / mayPlaceOn of each class; the
-- scan is in docs/WORLD-DYNAMICS.md) and reduced to a few RULES per block state, kept in mc.dyn_vec.rule:  rule = type | param << 8
--      1 the block BELOW must be in the tag with bit `param` of mc.dyn_vec.tagbits (VegetationBlock: supports_vegetation; CropBlock: supports_crops; ...)
--      2 the block below must support the CENTER of its top face (TorchBlock: Block.canSupportCenter(level, pos.below(), UP))
--      3 the neighbour in direction `param` must have a FULL sturdy face toward us (WallTorchBlock, LadderBlock, buttons, levers: the block they are attached to)
--      5 the block below must be the block with ordinal `param` and its `half` must be lower (the upper half of a door or a tall plant)
--      6 the block below must have a FULL sturdy top face (the lower half of a door)
--      7 the block below must not be air (CarpetBlock: !level.isEmptyBlock(pos.below()))
--      8 the block below must have a RIGID sturdy top face (pressure plates, rails: Block.canSupportRigidBlock)
--      9 the block below must be solid (BlockState.isSolid: standing signs and banners)
--     10 the neighbour in direction `param` must be solid (wall signs and banners)
-- The light conditions of crops and mushrooms are NOT modelled (there is no block light: a crop in a lit greenhouse would otherwise be uprooted).  What is not covered keeps
-- its block until something else removes it: sugar cane, cactus, lily pads, kelp, seagrass, mushrooms, stems, dripleaf, vines, fire, sea pickles, snow layers, hanging signs, lanterns.
-- tagbits: bit 0 supports_vegetation, 1 supports_crops, 2 supports_dry_vegetation, 3 supports_azalea, 4 supports_nether_sprouts, 5 supports_nether_wart, 6 supports_wither_rose,
--          7 grows_crops, 8 maintains_farmland, 9 snow, 10 prevents_nearby_leaf_decay (what a leaf counts as distance 0: logs, wood ...),
--          11 supports_sugar_cane, 12 supports_sugar_cane_adjacently (a block tag: frosted ice), 13 supports_cactus

create or replace function mc.dyn_isa(p_chain text, p_class text) returns boolean language sql immutable parallel safe as $$
  select p_chain = p_class or p_chain like p_class || '>%' or p_chain like '%>' || p_class || '>%' or p_chain like '%>' || p_class $$;

create or replace function mc.dyn_dir_index(p_name text) returns int language sql immutable parallel safe as $$
  select case p_name when 'down' then 0 when 'up' then 1 when 'north' then 2 when 'south' then 3 when 'west' then 4 when 'east' then 5 end $$;

create or replace function mc.dyn_rebuild_rules() returns void language plpgsql volatile as $$
declare tags text[] := array['supports_vegetation', 'supports_crops', 'supports_dry_vegetation', 'supports_azalea', 'supports_nether_sprouts', 'supports_nether_wart', 'supports_wither_rose', 'grows_crops', 'maintains_farmland', 'snow', 'prevents_nearby_leaf_decay', 'supports_sugar_cane', 'supports_sugar_cane_adjacently', 'supports_cactus'];
begin
    -- per BLOCK facts first (1,286 blocks, not 35,723 states): which classes its chain has, which tags it is in
    create temp table _rb on commit drop as
    select d.block, b.bid, d.chain,
           mc.dyn_isa(d.chain, 'WallTorchBlock') or mc.dyn_isa(d.chain, 'LadderBlock') as attach_full,
           mc.dyn_isa(d.chain, 'TorchBlock') as torch, mc.dyn_isa(d.chain, 'DoorBlock') as door,
           mc.dyn_isa(d.chain, 'DoublePlantBlock') and not mc.dyn_isa(d.chain, 'PitcherCropBlock') and not mc.dyn_isa(d.chain, 'TallSeagrassBlock') and not mc.dyn_isa(d.chain, 'SmallDripleafBlock') as dplant,
           mc.dyn_isa(d.chain, 'CarpetBlock') and not mc.dyn_isa(d.chain, 'MossyCarpetBlock') as carpet,
           mc.dyn_isa(d.chain, 'BasePressurePlateBlock') or mc.dyn_isa(d.chain, 'BaseRailBlock') as rigid,
           mc.dyn_isa(d.chain, 'StandingSignBlock') or mc.dyn_isa(d.chain, 'BannerBlock') as standing,
           mc.dyn_isa(d.chain, 'WallSignBlock') or mc.dyn_isa(d.chain, 'WallBannerBlock') as wallsign,
           mc.dyn_isa(d.chain, 'FaceAttachedHorizontalDirectionalBlock') and (mc.dyn_isa(d.chain, 'ButtonBlock') or mc.dyn_isa(d.chain, 'LeverBlock')) as button,
           mc.dyn_isa(d.chain, 'CropBlock') and not mc.dyn_isa(d.chain, 'PitcherCropBlock') as crop,
           mc.dyn_isa(d.chain, 'DryVegetationBlock') as dry, mc.dyn_isa(d.chain, 'AzaleaBlock') as azalea, mc.dyn_isa(d.chain, 'NetherSproutsBlock') as sprouts,
           mc.dyn_isa(d.chain, 'NetherWartBlock') as wart, mc.dyn_isa(d.chain, 'WitherRoseBlock') as wrose,
           mc.dyn_isa(d.chain, 'VegetationBlock')
             and not (mc.dyn_isa(d.chain, 'AttachedStemBlock') or mc.dyn_isa(d.chain, 'StemBlock') or mc.dyn_isa(d.chain, 'LilyPadBlock') or mc.dyn_isa(d.chain, 'MangrovePropaguleBlock')
                      or mc.dyn_isa(d.chain, 'MushroomBlock') or mc.dyn_isa(d.chain, 'NetherFungusBlock') or mc.dyn_isa(d.chain, 'NetherRootsBlock') or mc.dyn_isa(d.chain, 'PitcherCropBlock')
                      or mc.dyn_isa(d.chain, 'SeaPickleBlock') or mc.dyn_isa(d.chain, 'SeagrassBlock') or mc.dyn_isa(d.chain, 'TallSeagrassBlock') or mc.dyn_isa(d.chain, 'SmallDripleafBlock')
                      or mc.dyn_isa(d.chain, 'FrogspawnBlock') or mc.dyn_isa(d.chain, 'TorchflowerCropBlock') or mc.dyn_isa(d.chain, 'FireflyBushBlock') or mc.dyn_isa(d.chain, 'SweetBerryBushBlock')) as vegetation,
           mc.dyn_isa(d.chain, 'LeavesBlock') as leaves, mc.dyn_isa(d.chain, 'SugarCaneBlock') as cane, mc.dyn_isa(d.chain, 'CactusBlock') as cactus, mc.dyn_isa(d.chain, 'SpreadingSnowyBlock') as spreading, mc.dyn_isa(d.chain, 'SaplingBlock') and not mc.dyn_isa(d.chain, 'MangrovePropaguleBlock') as sapling,
           coalesce((select sum(1::int8 << (t.i - 1)) from generate_series(1, array_length(tags, 1)) t(i)
                      where exists (select 1 from ref.dp_tag_member m where m.registry = 'minecraft:block' and m.tag = 'minecraft:' || tags[t.i] and m.member = d.block)), 0)::int8 as tagbits
      from (select distinct block, chain from mc.dyn_state) d join mc.dyn_block b on b.name = d.block;
    create index on _rb (block);
    update mc.dyn_vec v set
        tagbits = (select array_agg(coalesce(r.tagbits, 0) order by s.sid) || array[0::int8] from mc.dyn_state s join _rb r on r.block = s.block),
        rule = (select array_agg(q.rule order by q.sid) || array[0] from (
            select s.sid,
                   case
                     when r.attach_full then 3 | (coalesce(mc.dyn_dir_index(case b.properties->>'facing' when 'north' then 'south' when 'south' then 'north' when 'west' then 'east' when 'east' then 'west' end), 0) << 8)
                     when r.torch then 2
                     when r.door then (case when b.properties->>'half' = 'upper' then 5 | (r.bid << 8) else 6 end)
                     when r.dplant then (case when b.properties->>'half' = 'upper' then 5 | (r.bid << 8) else 1 end)
                     when r.carpet then 7
                     when r.rigid then 8
                     when r.standing then 9
                     when r.wallsign then 10 | (coalesce(mc.dyn_dir_index(case b.properties->>'facing' when 'north' then 'south' when 'south' then 'north' when 'west' then 'east' when 'east' then 'west' end), 0) << 8)
                     when r.button then
                          -- canAttach(level, pos, connectedDirection.opposite): the support lies on the side the button does not point to (wall: behind it, ceiling: above, floor: below)
                          3 | ((case b.properties->>'face' when 'wall' then mc.dyn_dir_index(case b.properties->>'facing' when 'north' then 'south' when 'south' then 'north' when 'west' then 'east' when 'east' then 'west' end)
                                                            when 'ceiling' then 1 else 0 end) << 8)
                     when r.crop then 1 | (1 << 8)
                     when r.dry then 1 | (2 << 8)
                     when r.azalea then 1 | (3 << 8)
                     when r.sprouts then 1 | (4 << 8)
                     when r.wart then 1 | (5 << 8)
                     when r.wrose then 1 | (6 << 8)
                     when r.vegetation then 1
                     else 0 end as rule
              from mc.dyn_state s join ref.block_state b on b.state_id = s.sid join _rb r on r.block = s.block) q)
        where true;
    -- the flags the rules need: HAS_RULE (262144), the lower half of a two-block plant or door (131072), the random-tick classes (sql/887)
    update mc.dyn_vec v set flags = (select array_agg(v.flags[i] | (case when v.rule[i] <> 0 then 262144 else 0 end) | (case when b.properties->>'half' = 'lower' then 131072 else 0 end)
                                                       | (case when r.spreading then 524288 else 0 end) | (case when r.crop then 1048576 else 0 end)
                                                       | (case when d.block = 'minecraft:farmland' then 2097152 else 0 end) | (case when r.sapling then 4194304 else 0 end) | (case when r.leaves then 8388608 else 0 end) | (case when r.cane then 16777216 else 0 end) | (case when r.cactus then 33554432 else 0 end) order by i)
                                       from generate_series(1, v.n + 1) i left join ref.block_state b on b.state_id = i - 1 left join mc.dyn_state d on d.sid = i - 1 left join _rb r on r.block = d.block),
        nextp = (select array_agg(coalesce(case when d.sid is null then -1
                                                when r.crop and b.properties ? 'age' then
                                                     (select n.state_id from ref.block_state n where n.block = d.block and n.properties = b.properties || jsonb_build_object('age', ((b.properties->>'age')::int + 1)::text))
                                                when r.sapling and b.properties ? 'stage' and b.properties->>'stage' = '0' then
                                                     (select n.state_id from ref.block_state n where n.block = d.block and n.properties = b.properties || jsonb_build_object('stage', '1'))
                                                else -1 end, -1) order by i)
                   from generate_series(1, v.n + 1) i left join ref.block_state b on b.state_id = i - 1 left join mc.dyn_state d on d.sid = i - 1 left join _rb r on r.block = d.block);
    -- leaves (LeavesBlock): per state distance | persistent << 3 | waterlogged << 4 | (the state with distance = 1 and the same other properties) << 5
    update mc.dyn_vec v set leaf = (select array_agg(coalesce(case when r.leaves then (b.properties->>'distance')::int | (case when b.properties->>'persistent' = 'true' then 8 else 0 end)
                                                                                | (case when b.properties->>'waterlogged' = 'true' then 16 else 0 end)
                                                                                | ((select n.state_id from ref.block_state n where n.block = d.block and n.properties = b.properties || jsonb_build_object('distance', '1')) << 5) end, 0) order by i)
                                      from generate_series(1, v.n + 1) i left join ref.block_state b on b.state_id = i - 1 left join mc.dyn_state d on d.sid = i - 1 left join _rb r on r.block = d.block);
    -- age plants: age | the state of age 0 of the block << 5
    update mc.dyn_vec v set plant = (select array_agg(coalesce(case when r.cane or r.cactus then (b.properties->>'age')::int
                                                                                   | ((select n.state_id from ref.block_state n where n.block = d.block and n.properties = b.properties || jsonb_build_object('age', '0')) << 5) end, 0) order by i)
                                       from generate_series(1, v.n + 1) i left join ref.block_state b on b.state_id = i - 1 left join mc.dyn_state d on d.sid = i - 1 left join _rb r on r.block = d.block);
    drop table _rb;
end $$;

create or replace function mc.dyn_rebuild() returns void language plpgsql volatile as $$
begin
    perform mc.dyn_rebuild_base();
    if exists (select 1 from mc.dyn_vec) then perform mc.dyn_rebuild_rules(); end if;
    -- the two per-state facts the event trigger (sql/885) and the random-tick lists (sql/887) test by name, without reading the big arrays
    update mc.dyn_state s set react = (v.flags[s.sid + 1] & (4 | 8 | 4096 | 65536 | 262144 | 8388608 | 16777216 | 33554432)) <> 0, tickc = (v.flags[s.sid + 1] & (524288 | 1048576 | 2097152 | 4194304 | 8388608 | 16777216 | 33554432)) <> 0
      from mc.dyn_vec v where s.sid < v.n;
end $$;

-- Block.canSurvive of a block with rule p_rule at (qx, qy, qz): see the header
create or replace function mc.dyn_survives(p_secs int4[], p_gm int4[], p_fl int4[], p_stv int4[], p_tg int8[], p_bid int4[], qx int, qy int, qz int, p_rule int) returns boolean language plpgsql immutable parallel safe as $$
declare t int := p_rule & 255; prm int := p_rule >> 8; b int; n int;
begin
    if t = 3 or t = 10 then
        n := mc.dyn_at(p_secs, p_gm, qx + mc.dyn_dx(prm), qy + mc.dyn_dy(prm), qz + mc.dyn_dz(prm));
        if t = 10 then return (p_fl[n + 1] & 2) <> 0; end if;
        return ((p_stv[n + 1] >> mc.dyn_opp(prm)) & 1) = 1;
    end if;
    b := mc.dyn_at(p_secs, p_gm, qx, qy - 1, qz);
    return case t when 1 then ((p_tg[b + 1] >> prm) & 1) = 1
                  when 2 then ((p_stv[b + 1] >> 7) & 1) = 1
                  when 5 then p_bid[b + 1] = prm and (p_fl[b + 1] & 131072) <> 0
                  when 6 then ((p_stv[b + 1] >> 1) & 1) = 1
                  when 7 then (p_fl[b + 1] & 1) = 0
                  when 8 then ((p_stv[b + 1] >> 13) & 1) = 1
                  when 9 then (p_fl[b + 1] & 2) <> 0
                  else true end;
end $$;

-- Block.canSurvive of sugar cane (p_cactus = false) and cactus (true) at (qx, qy, qz), whose block ordinal is p_self:
--   SugarCaneBlock: the block below is sugar cane, or is in the tag supports_sugar_cane and has water (the fluid tag supports_sugar_cane_adjacently) or frosted ice next to it (the four sides of the block below)
--   CactusBlock:    none of the four sides is solid or has lava, and the block below is cactus or in the tag supports_cactus, and the block above is not a liquid
create or replace function mc.dyn_plant_ok(p_secs int4[], p_gm int4[], p_fl int4[], p_tg int8[], p_bid int4[], qx int, qy int, qz int, p_self int, p_cactus boolean) returns boolean language plpgsql immutable parallel safe as $$
declare b int; n int; k int; dx int[] := array[0, 0, -1, 1]; dz int[] := array[-1, 1, 0, 0];
begin
    if p_cactus then
        for k in 1 .. 4 loop
            n := mc.dyn_at(p_secs, p_gm, qx + dx[k], qy, qz + dz[k]);
            if (p_fl[n + 1] & 2) <> 0 or (p_fl[n + 1] & 16) <> 0 then return false; end if;
        end loop;
        b := mc.dyn_at(p_secs, p_gm, qx, qy - 1, qz);
        if p_bid[b + 1] <> p_self and ((p_tg[b + 1] >> 13) & 1) = 0 then return false; end if;
        n := mc.dyn_at(p_secs, p_gm, qx, qy + 1, qz);
        return (p_fl[n + 1] & 4) = 0;
    end if;
    b := mc.dyn_at(p_secs, p_gm, qx, qy - 1, qz);
    if p_bid[b + 1] = p_self then return true; end if;
    if ((p_tg[b + 1] >> 11) & 1) = 0 then return false; end if;
    for k in 1 .. 4 loop
        n := mc.dyn_at(p_secs, p_gm, qx + dx[k], qy - 1, qz + dz[k]);
        if (p_fl[n + 1] & 8) <> 0 or ((p_tg[n + 1] >> 12) & 1) = 1 then return true; end if;
    end loop;
    return false;
end $$;

-- LeavesBlock.updateDistance for a cell of the stored world (placement of leaves, sql/890): the smallest of the six neighbours' distance + 1, 7 at most; a neighbour that is a block of the tag
-- prevents_nearby_leaf_decay counts as 0, leaves as their own distance, anything else as 7.  (The engine does the same on its arrays: mc.dyn_run, block tick of leaves.)
create or replace function mc.leaf_distance_at(p_dim text, x int, y int, z int) returns int language plpgsql stable as $$
declare d text; nb text; best int := 7; dd int;
begin
    foreach d in array array['down', 'up', 'north', 'south', 'west', 'east'] loop
        nb := mc.nb(p_dim, x, y, z, d);
        dd := case when nb is null then 7
                   when exists (select 1 from ref.dp_tag_member m where m.registry = 'minecraft:block' and m.tag = 'minecraft:prevents_nearby_leaf_decay' and m.member = split_part(nb, '[', 1)) then 0
                   when nb like '%leaves[%' and nb like '%distance=%' then substring(nb from 'distance=([0-9]+)')::int
                   else 7 end;
        best := least(best, dd + 1);
        exit when best = 1;
    end loop;
    return best;
end $$;
