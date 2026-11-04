-- calls and times of the functions of the lane tick over 96 consecutive ticks on the population a bench left behind (track_functions)
select coalesce(last_tick, 0) + 1 as t from mc.entity_clock \gset
select set_config('x.t', :'t', false);
set track_functions = 'all';
select pg_stat_reset_single_function_counters(oid) from pg_proc where pronamespace = 'mc'::regnamespace and proname like 'entity%';
do $$ declare t1 bigint := current_setting('x.t')::bigint; begin
 for tk in t1 .. t1 + 95 loop perform mc.entity_auto_tick(tk); commit; end loop;
end $$;
select pg_stat_force_next_flush();
select funcname, calls, round(total_time::numeric, 1) as total_ms, round(self_time::numeric, 1) as self_ms, round((self_time * 1000 / calls)::numeric, 1) as self_us_per_call from pg_stat_user_functions where schemaname = 'mc' and calls > 0 order by self_time desc limit 12;
