-- Tables for the raw scaling measurement (docs/PERF-MULTICORE.md, part 1a).
--   w_i   private LOGGED hot table of client i (10,000 rows, fillfactor 60, no index on the updated columns: HOT updates)
--   wu_i  the same, UNLOGGED (no WAL): isolates what the WAL costs
--   q_i   private UNLOGGED queue of client i (emptied with TRUNCATE like the tick does)
--   w_s   one LOGGED hot table shared by all clients, each client updating its own block of 10,000 rows
drop table if exists w_s;
create table w_s (id int primary key, x float8, y float8, z float8, tick bigint, pad text) with (fillfactor = 60);
insert into w_s select g, g, 64, g, 0, repeat('x', 40) from generate_series(1, 80000) g;
do $$ begin for i in 0..7 loop
  execute format('drop table if exists w_%s, wu_%s, q_%s, q_s', i, i, i);
  execute format('create table w_%s (id int primary key, x float8, y float8, z float8, tick bigint, pad text) with (fillfactor = 60)', i);
  execute format('insert into w_%s select g, g, 64, g, 0, repeat(''x'', 40) from generate_series(1, 10000) g', i);
  execute format('create unlogged table wu_%s (id int primary key, x float8, y float8, z float8, tick bigint, pad text) with (fillfactor = 60)', i);
  execute format('insert into wu_%s select g, g, 64, g, 0, repeat(''x'', 40) from generate_series(1, 10000) g', i);
  execute format('create unlogged table q_%s (conn int, seq int, data bytea)', i);
end loop; end $$;
vacuum analyze;
