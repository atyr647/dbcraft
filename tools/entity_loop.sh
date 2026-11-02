#!/usr/bin/env bash
# usage: tools/entity_loop.sh [ticks-per-call]        env: the usual PG* variables (PGHOST, PGPORT, PGUSER, PGDATABASE)
# The second connection of the split entity mode (docs/PERF-MULTICORE.md): runs `call mc.entity_loop(N)` over and over, so the entity simulation of the 20 Hz tick runs next to
# the player tick instead of inside it.  Needs `dbcraft.entity-mode` = split on the server (update mc.server_property set value = 'split' where key = 'dbcraft.entity-mode');
# without it the entity tick would also run in nobody's tick at all (off) or twice (inline).  Restarts itself when the database connection drops.  Stop it with Ctrl-C.
# In split mode mc.play_out is no longer TRUNCATEd by the tick (a second writer holds row locks on it): let autovacuum have it (it does by default), or add it to the gateway's
# maintenance_tables.
set -u
N=${1:-200}
while true; do
  psql -X -q -At -v ON_ERROR_STOP=1 -c "call mc.entity_loop($N)" > /dev/null || { echo "[entity_loop] call failed, retrying in 1 s" >&2; sleep 1; }
done
