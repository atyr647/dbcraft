-- pgbench script: point reads, to compare with pgbench_set_block.sql.
\set x random(0, 127)
\set y random(-64, -45)
\set z random(0, 127)
select mc.get_block('dbcraft:bench', :x, :y, :z);
