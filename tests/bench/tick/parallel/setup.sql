-- Tables for the parallel-writer scaling experiment (tests/bench/tick/parallel/run.sh).  One schema, many shapes:
--   pw_sep_N  (logged)    one table per client: no shared relation at all
--   pw_shared (logged)    one table, every client updates its own disjoint block of rows (like regions of players in mc.player)
--   pu_sep_N  (unlogged)  the same as pw_sep_N without WAL
--   pu_shared (unlogged)  the same as pw_shared without WAL
-- Every row is as wide as an mc.player row (about 190 bytes) and every statement updates 500 rows, like the movement update of one tick.
drop schema if exists par cascade;
create schema par;
do $$
declare i int;
begin
  for i in 0 .. 7 loop
    execute format('create table par.pw_sep_%s (id int primary key, a float8, b float8, c float8, d int, e int, pad text) with (fillfactor = 60)', i);
    execute format('create unlogged table par.pu_sep_%s (id int primary key, a float8, b float8, c float8, d int, e int, pad text) with (fillfactor = 60)', i);
    execute format('insert into par.pw_sep_%s select g, random(), random(), random(), 0, 0, repeat(''x'', 120) from generate_series(1, 500) g', i);
    execute format('insert into par.pu_sep_%s select g, random(), random(), random(), 0, 0, repeat(''x'', 120) from generate_series(1, 500) g', i);
  end loop;
end $$;
create table par.pw_shared (id int primary key, a float8, b float8, c float8, d int, e int, pad text) with (fillfactor = 60);
create unlogged table par.pu_shared (id int primary key, a float8, b float8, c float8, d int, e int, pad text) with (fillfactor = 60);
insert into par.pw_shared select g, random(), random(), random(), 0, 0, repeat('x', 120) from generate_series(1, 4000) g;
insert into par.pu_shared select g, random(), random(), random(), 0, 0, repeat('x', 120) from generate_series(1, 4000) g;
vacuum analyze;
