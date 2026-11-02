#!/usr/bin/env bash
# Vacuum and analyze dbcraft's hot tables from a session of their own, every few seconds.
#
# Why: autovacuum decides from the table statistics the backends report, and a backend reports them when it goes IDLE.  The development gateway (`call net.run`) and any
# other long-running procedure that COMMITs every tick never goes idle inside its CALL, so autovacuum and autoanalyze see none of its inserts and deletes: the per-tick queue
# tables grow without bound (12 MB in 75 s in tests/bench/tuning, docs/TUNING.md) and the statistics of net.conn / mc.player go stale (a stale plan once cost a 4 s tick).
# An external gateway that sends one statement per tick is idle between statements and does not need this.
#
# usage: tools/janitor.sh [INTERVAL_SECONDS=5]      loop until killed (connection from the usual PG* variables)
#        tools/janitor.sh once                       one pass, then exit
set -u
INTERVAL=${1:-5}
# NEVER list a table the tick TRUNCATEs: a VACUUM holds a lock that makes the tick's TRUNCATE wait, and under load that wait was 5 seconds (tick 10900 of the soak run, docs/SOAK.md).
# Those are mc.play_out, mc.play_in_work, net.batch, mc.pending_ack and mc.block_actor (and mc.play_in on its error path).  net.inbox, net.outbox and mc.play_in are not in the list
# either: net.drain_outbox() truncates them when they are big and empty (sql/780); a vacuum of a queue that is empty at that moment would only store reltuples = 0 (sql/435).
# mc.chunk_wanted, mc.chunk_request, mc.visible and the tick logs grow by DELETE under load (measured in docs/SOAK.md).
TABLES="net.play_inbox mc.kick mc.block_event mc.visible net.conn mc.player mc.game_state mc.chunk_wanted mc.chunk_request mc.server_tick_log mc.tick_log net.gateway_control"
pass() {
  # one VACUUM statement for the tables that exist; skip_locked: never wait behind a tick that has a table locked
  psql -X -q -At -c "select format('vacuum (analyze, skip_locked) %s', string_agg(t, ', ')) from unnest(string_to_array('$TABLES', ' ')) t where to_regclass(t) is not null" \
    | psql -X -q >/dev/null 2>&1
}
if [ "$INTERVAL" = once ]; then pass; exit 0; fi
while true; do pass; sleep "$INTERVAL"; done
