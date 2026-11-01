-- Tick performance, part 5: keeping the per-tick queues small.  See docs/PERF-TICK.md ("queues that are emptied with DELETE").
--
-- Every queue is filled and emptied each tick.  Emptied with DELETE, a table keeps the dead rows until a vacuum removes them and every later scan walks them:
-- with the default autovacuum (a look every minute, 20% dead rows) the tick time of a 500-player run grew from 47 ms to 96 ms within 500 ticks and mc.play_out
-- reached 15,478 pages (121 MB) holding no row.  Vacuuming them aggressively cures the bloat but creates a second problem: a vacuum of a table that is empty
-- at that moment stores reltuples = 0, and the planner then believes the table has ONE row for as long as the statistic stays (measured: nested loops that
-- re-run a sort 500 times, a 17 ms decode and a 76 ms movement statement for 500 packets).  A TRUNCATE instead leaves the statistic unset and the planner
-- falls back to the real size of the table, which is what these queues need.  So:
--
--   * mc.play_in_work, net.batch, mc.play_out  (written and read only by the tick): autovacuum OFF; mc.server_tick() TRUNCATEs them once a second (every 20th
--     tick, at a moment when they are empty).  A truncate invalidates the cached plans that mention the table, so doing it every tick would cost 3-5 ms of
--     planning; once a second it costs about 0.5 ms per tick on average.
--   * net.inbox, net.outbox, mc.play_in  (shared with the gateway, so the tick cannot truncate them safely): autovacuum stays ON with a hot setting (vacuum as soon as
--     500 rows are dead, unthrottled).  Their statistics may read "empty" at times; the statements that read them do not depend on the row count.
--   Set  autovacuum_naptime = 1s  in postgresql.conf (the smallest value) for the second group to work.

alter table mc.play_in_work set (autovacuum_enabled = false);
alter table net.batch       set (autovacuum_enabled = false, toast.autovacuum_enabled = false);
alter table mc.play_out     set (autovacuum_enabled = false, toast.autovacuum_enabled = false);

alter table net.inbox  set (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 500, autovacuum_vacuum_cost_delay = 0, autovacuum_vacuum_cost_limit = 10000, toast.autovacuum_vacuum_scale_factor = 0, toast.autovacuum_vacuum_threshold = 500, toast.autovacuum_vacuum_cost_delay = 0);
alter table net.outbox set (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 500, autovacuum_vacuum_cost_delay = 0, autovacuum_vacuum_cost_limit = 10000, toast.autovacuum_vacuum_scale_factor = 0, toast.autovacuum_vacuum_threshold = 500, toast.autovacuum_vacuum_cost_delay = 0);
alter table mc.play_in set (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 500, autovacuum_vacuum_cost_delay = 0, autovacuum_vacuum_cost_limit = 10000);
