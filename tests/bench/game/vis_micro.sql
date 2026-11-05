-- psql -v fn=mc.refresh_visibility_vis -v frac=0.27 -v step=4.6 -v reps=10 -f vis_micro.sql  (tests/bench/game/vis_micro.sh)
-- Times the function on a dirty set built by moving a fraction of the players `step` blocks along their heading; every run is rolled back.  CPU time of the backend (/proc/<pid>/schedstat, superuser)
-- and wall time: other processes on the machine inflate the second, hardly the first.
create or replace function pg_temp.cpu_ns() returns bigint language sql as $$ select split_part(pg_read_file('/proc/' || pg_backend_pid() || '/schedstat'), ' ', 1)::bigint $$;
create or replace function pg_temp.micro(fn text, frac float8, step float8, reps int) returns text language plpgsql as $$
declare t0 timestamptz; c0 bigint; tot float8 := 0; cpu float8 := 0; i int; r record; ad bigint := 0; rm bigint := 0; nd int;
begin
  for i in 1..reps loop
    begin
      perform setseed(i / 100.0);
      update mc.player set x = x - sin(radians(yaw)) * step, z = z + cos(radians(yaw)) * step, chunk_x = floor((x - sin(radians(yaw)) * step) / 16)::int, chunk_z = floor((z + cos(radians(yaw)) * step) / 16)::int, vis_dirty = true
       where conn_id is not null and random() < frac;
      get diagnostics nd = row_count;
      t0 := clock_timestamp(); c0 := pg_temp.cpu_ns();
      execute format('select added, removed from %s()', fn) into r;
      cpu := cpu + (pg_temp.cpu_ns() - c0) / 1e6; tot := tot + extract(epoch from clock_timestamp() - t0) * 1000; ad := ad + r.added; rm := rm + r.removed;
      raise exception 'rollback';
    exception when raise_exception then null;
    end;
  end loop;
  return format('%s: cpu %s ms wall %s ms avg over %s runs (%s dirty): added %s removed %s per run', fn, round((cpu / reps)::numeric, 2), round((tot / reps)::numeric, 2), reps, nd, ad / reps, rm / reps);
end $$;
select pg_temp.micro(:'fn', :frac::float8, :step::float8, :reps::int);
