-- sampled every 100 ms while pgbench runs; aggregate with: sort | uniq -c | sort -rn
\pset tuples_only on
\pset format unaligned
select coalesce(wait_event_type || ':' || wait_event, 'CPU') from pg_stat_activity where datname = 'pgb' and pid <> pg_backend_pid() and state = 'active' and backend_type = 'client backend'
\watch 0.1
