select coalesce(max(goal_until), 0) as t from mc.entity_lane \gset
select coalesce(last_tick, 0) + 1 as t from mc.entity_clock \gset
select set_config('x.t', :'t', false);
do $$ declare t1 bigint := current_setting('x.t')::bigint; r record; due int; i int; begin
 for tk in t1 .. t1 + 33 loop
   i := 0;
   loop
     select count(*) into due from mc.entity_lane l where l.auto and ((l.lazy and l.id % 32 = (tk % 32)::int) or not l.lazy) and l.goal_until <= tk;
     exit when due = 0 or i >= 8;
     select * into r from mc.entity_auto_run(tk, false, null);
     i := i + 1;
     raise notice 'tick % pass % due % more %', tk, i, due, r.more;
   end loop;
 end loop;
end $$;
