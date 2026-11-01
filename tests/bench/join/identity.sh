#!/usr/bin/env bash
# usage: tests/bench/join/identity.sh DB_A DB_B      (both on the cluster given by PGHOST/PGPORT, default /tmp:54466; jbench loaded in both)
# Runs the SAME login storms on two databases and compares, for every connection, the md5 and length of everything it was sent (the random session id in
# login_finished is masked).  Scenarios: a storm into an empty server, into a populated one, spread over several ticks, a reconnect with the old
# connections still open (duplicate login) and after they were closed.  Exit 1 on any difference.
set -euo pipefail
A=$1; B=$2
export PGHOST=${PGHOST:-/tmp} PGPORT=${PGPORT:-54466} PGUSER=${PGUSER:-postgres}
run() {  # db
  psql -X -q -At -v ON_ERROR_STOP=1 -d "$1" <<'SQL'
select 'S1 storm of 40 into an empty server';
select jbench.reset();
select * from jbench.tick_digest(1, 40);
select 'S2 storm of 30 into 40 online';
select * from jbench.tick_digest(101, 30);
select 'S3 three ticks of 10 into 70 online';
select * from jbench.tick_digest(201, 10);
select * from jbench.tick_digest(211, 10);
select * from jbench.tick_digest(221, 10);
select 'S4 idle tick';
select * from jbench.tick_digest(0, 0);
select 'S5 duplicate login: 5 names come back while their old connections are open';
select * from jbench.reconnect_tick(1, 5, 301, 'J', 'dup');
select 'S5 digests';
select conn_id, md5, bytes from jbench.digest();
select 'S6 reconnect after disconnect';
select * from jbench.reconnect_tick(21, 5, 401, 'J', 'gone');
select 'S7 online players at the end';
select count(*) from net.conn where state = 'play';
select count(*) from mc.player where conn_id is not null;
select name, entity_id from mc.player where conn_id is not null order by entity_id limit 200;
SQL
}
# reconnect_tick returns timings, which differ: keep only the columns that must match (frames, mb)
norm() { awk -F'|' '/^[0-9.]+\|[0-9]+\|[0-9.]+$/ {print "reconnect frames=" $2 " mb=" $3; next} {print}'; }
run "$A" | norm > "/tmp/identity_$A.txt"
run "$B" | norm > "/tmp/identity_$B.txt"
if cmp -s "/tmp/identity_$A.txt" "/tmp/identity_$B.txt"; then
  echo "IDENTICAL: $(wc -l < /tmp/identity_$A.txt) lines, $(grep -c '^[0-9]*|[0-9a-f]\{32\}|' /tmp/identity_$A.txt) connection digests"
else
  echo "DIFFERENT:"; diff "/tmp/identity_$A.txt" "/tmp/identity_$B.txt" | head -20; exit 1
fi
