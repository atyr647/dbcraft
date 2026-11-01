-- Experiment: the database-level defaults of sql/450_tuning.sql (they apply to new sessions, i.e. to the harness's own connections).
do $$ begin
  execute format('alter database %I set jit = off', current_database());
  execute format('alter database %I set synchronous_commit = off', current_database());
  execute format('alter database %I set max_parallel_workers_per_gather = 0', current_database());
end $$;
