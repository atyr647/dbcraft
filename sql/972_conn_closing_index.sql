-- net.gateway_pending, net.drain_outbox and the tick's drain ask "is any connection closing?" once per tick.  With 200 players that was a scan of net.conn (30 pages: the rows are
-- updated by the keep-alive and activity bookkeeping, so the heap carries dead versions between vacuums), 0.1-0.3 ms of every idle tick (docs/PERF-IDLE2.md).  A partial index on the
-- rows that ARE closing makes the question one index probe; the index only changes when a connection starts closing (the column is not touched by the per-tick updates, which stay HOT).
create index if not exists conn_closing on net.conn (conn_id) where closing;

-- The tick truncates mc.play_in_work and net.batch (game time 19 mod 20) and mc.play_out (0 mod 20) once a second when they were written (sql/435).  A TRUNCATE invalidates every cached plan that
-- mentions the table, and the next tick plans them again: with 200 players online the tick after it is 2-3 times the others (docs/PERF-IDLE2.md "The tail of the tick").
-- dbcraft.tick-truncate-bytes: truncate only when the table is bigger than this many bytes (the heap, no TOAST); 0 is the old behaviour (whenever written).  Default 1 MiB: measured with 200 idle
-- players (3 repetitions each, alternating): the p99 of the tick as the gateway saw it fell from 30.5 to 19.4 ms (SQL tick p99 20.6 -> 13.0, mean 5.6 -> 4.5 ms) and the slowest ticks, all of them
-- the first of a second (net.process replanned after the truncate: 8-26 ms), are gone.  The tables stay at most about 1 MiB of dead rows between truncates.
insert into mc.server_property (key, value, default_value, note)
values ('dbcraft.tick-truncate-bytes', '1048576', '1048576', 'dbcraft: the tick truncates its own queues (mc.play_out, mc.play_in_work, net.batch) once a second only when they are bigger than this many bytes; 0 = whenever written (docs/PERF-IDLE2.md)')
on conflict (key) do nothing;
