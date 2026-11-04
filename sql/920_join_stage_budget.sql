-- Join stage budget: settings of the time budget that bounds how many logins enter play in one tick.  Why, how and what it measured: docs/PERF-STORM.md.
--
-- The code is in two places that were edited in place (nothing overrides them later): net.process_fast (sql/430_tick_perf.sql: puts back the entry packets that do not fit in the
-- tick's budget) and net.hook_chunks / mc.deliver_ready_chunks (sql/430_chunk_queue.sql, sql/791_join_chunk_budget.sql: a joiner's square is sent over several ticks).  This file
-- holds the settings.

insert into mc.server_property (key, value, default_value, note) values
    ('dbcraft.join-entry-budget-ms', '10', '10', 'dbcraft: login storms: once a tick has spent this many ms in net.process_fast, further connections entering play (finish_configuration: mc.on_join, entry burst) wait for the next tick; off = never'),
    ('dbcraft.join-entry-free',      '1',  '1',  'dbcraft: login storms: connections entering play per tick that are never held back by dbcraft.join-entry-budget-ms')
on conflict (key) do nothing;
