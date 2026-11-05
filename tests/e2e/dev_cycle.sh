#!/usr/bin/env bash
# Rebuild the private dev database from the tree (tests/e2e/vis_dev.sh cycle: migration, reference data, gateway), load the sound data and make the probe players operators.
# environment as vis_dev.sh (DBCRAFT_PGDATA, DBCRAFT_PGPORT, VIS_GWPORT, VIS_LOG, VIS_SETUP_LOG) and PGHOST/PGPORT/PGUSER/PGDATABASE for the psql calls; OPS="Surv Obs" (default).
cd "$(dirname "$0")/../.." || exit 1
tests/e2e/vis_dev.sh stop > /dev/null 2>&1
tests/e2e/vis_dev.sh setup || exit 1
python3 tools/load_sounds.py
for n in ${OPS:-Surv Obs}; do
  u=$(python3 -c "
import hashlib, sys, uuid
h = bytearray(hashlib.md5(('OfflinePlayer:' + sys.argv[1]).encode()).digest()); h[6] = (h[6] & 0x0f) | 0x30; h[8] = (h[8] & 0x3f) | 0x80; print(uuid.UUID(bytes=bytes(h)))" "$n")
  psql -X -q -c "insert into mc.op (uuid, name, level) values ('$u', '$n', 4) on conflict do nothing"
done
psql -X -q -c "update mc.server_property set value = 'survival' where key = 'gamemode'" -c "select net.sync_settings()" > /dev/null
tests/e2e/vis_dev.sh start
