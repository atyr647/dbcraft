-- pgbench script: one set_block per transaction (the shape of a player's break/place), on a row of generated overworld chunks.
-- Prepare once:  select mc.generate_flat_area('minecraft:overworld', 40000, 0, 40019, 0);
--   pgbench -n -f tests/bench/world/pgbench_set_block_overworld.sql -c 1 -T 8 dbcraft_world
-- Each client keeps to its own band of chunks so clients never contend for a row.
\set x 40000 * 16 + (:client_id % 4) * 80 + random(0, 79)
\set y random(-64, -45)
\set z random(0, 15)
\set b random(1, 4)
select mc.set_block('minecraft:overworld', :x, :y, :z, (array['minecraft:stone','minecraft:dirt','minecraft:gravel','minecraft:sand'])[:b]);
