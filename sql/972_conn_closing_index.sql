-- net.gateway_pending, net.drain_outbox and the tick's drain ask "is any connection closing?" once per tick.  With 200 players that was a scan of net.conn (30 pages: the rows are
-- updated by the keep-alive and activity bookkeeping, so the heap carries dead versions between vacuums), 0.1-0.3 ms of every idle tick (docs/PERF-IDLE2.md).  A partial index on the
-- rows that ARE closing makes the question one index probe; the index only changes when a connection starts closing (the column is not touched by the per-tick updates, which stay HOT).
create index if not exists conn_closing on net.conn (conn_id) where closing;
