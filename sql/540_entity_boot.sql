-- Entity module boot helpers.
-- mc.block_class (sql/500) is filled by an INSERT ... SELECT FROM ref.block that runs at migration time; on a fresh database the reference data is loaded AFTER the
-- migration (tools/load_reports.py), so the table stayed empty and every entity fell through the floor (found by the MOB-PERF worker: the first benchmark on a fresh
-- database showed all mobs at y = -62.15).  This function is the same statement, callable after the reference data is loaded; run it after tools/load_reports.py.
create or replace function mc.block_class_refresh() returns int language plpgsql volatile as $$
declare n int;
begin
    insert into mc.block_class (name, solid, friction)
    select b.name,
           not (b.name ~ '^minecraft:(air|cave_air|void_air|water|lava|bubble_column|light|structure_void|short_grass|tall_grass|fern|large_fern|dead_bush|seagrass|tall_seagrass|kelp|kelp_plant|vine|glow_lichen|sculk_vein|hanging_roots|fire|soul_fire|snow|rail|powered_rail|detector_rail|activator_rail|redstone_wire|tripwire|tripwire_hook|lever|string|cobweb_unsolid|dandelion|poppy|blue_orchid|allium|azure_bluet|oxeye_daisy|cornflower|lily_of_the_valley|wither_rose|sunflower|lilac|rose_bush|peony|torchflower|pitcher_plant|brown_mushroom|red_mushroom|crimson_roots|warped_roots|nether_sprouts|spore_blossom|sweet_berry_bush|wheat|carrots|potatoes|beetroots|nether_wart|sugar_cane|bamboo_sapling|torch|wall_torch|soul_torch|soul_wall_torch|redstone_torch|redstone_wall_torch|end_rod|ladder|cobweb|scaffolding_unsolid)$'
                or b.name ~ '(_sapling|_carpet|_sign|_wall_sign|_hanging_sign|_banner|_wall_banner|_button|_pressure_plate|_tulip|_orchid|_mushroom_unsolid|_propagule|_pressure_plate)$'),
           case when b.name in ('minecraft:ice', 'minecraft:packed_ice', 'minecraft:frosted_ice') then 0.98::real
                when b.name = 'minecraft:blue_ice' then 0.989::real
                when b.name = 'minecraft:slime_block' then 0.8::real
                else 0.6::real end
    from ref.block b
    on conflict (name) do nothing;
    get diagnostics n = row_count;
    -- masks built while the table was empty describe a world without collision: drop them so they are rebuilt
    if n > 0 then delete from mc.solid_mask; end if;
    return n;
end $$;
