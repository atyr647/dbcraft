\timing on
select count(*) as sections, count(*) filter (where bits = 0) as single_value, count(*) filter (where bits = 4) as bits4,
       count(*) filter (where bits between 5 and 8) as bits5_8, count(*) filter (where bits = 16) as global_palette
  from mc.chunk_section where dimension = 'minecraft:overworld';
update mc.chunk_section set block_count = -1 where dimension = 'minecraft:overworld';
select mc.import_recount('minecraft:overworld') as counted;
