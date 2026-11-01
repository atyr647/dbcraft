-- pgbench script: one set_block per transaction, each client in its own 32-wide band of the 'dbcraft:bench' flat area (no row contention between clients).
--   pgbench -n -f tests/bench/world/pgbench_set_block.sql -c 4 -j 4 -T 10 dbcraft_world
\set x random(0, 31) + (:client_id % 4) * 32
\set y random(-64, -45)
\set z random(0, 127)
\set b random(1, 4)
select mc.set_block('dbcraft:bench', :x, :y, :z, (array['minecraft:stone','minecraft:dirt','minecraft:gravel','minecraft:sand'])[:b]);
