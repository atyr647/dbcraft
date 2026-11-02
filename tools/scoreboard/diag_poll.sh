#!/usr/bin/env bash
# Sample the dbcraft server every 20 s while a long run is going: connections in play, kick reasons, errors, tick log size.  usage: diag_poll.sh SECONDS
cd "$(dirname "$0")/../.."
END=$(( $(date +%s) + ${1:-420} ))
: > /tmp/scoreboard/diag_poll.log
while [ "$(date +%s)" -lt "$END" ]; do
  {
    echo "== $(date +%H:%M:%S)"
    tools/scoreboard/dbcraft.sh psql -At -f tools/scoreboard/diag_poll.sql 2>&1
  } >> /tmp/scoreboard/diag_poll.log
  sleep 20
done
