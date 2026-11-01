# Running dbcraft in a container

PostgreSQL 16 with PL/Python, the dbcraft schema, the recommended server configuration (`docker/postgresql.conf`, explained in [docs/TUNING.md](../docs/TUNING.md)) and,
optionally, the **development gateway** (the PL/Python procedure `net.run`, offline mode, no compression) listening on port 25565.

The production gateway (online mode, encryption, deflate) is not built; this container is for development and for trying the server with a real client.

```
export DBCRAFT_PASSWORD=choose-one
export DBCRAFT_REPORTS_DIR=/path/to/generator/reports            # your own output of the Minecraft data generator (blocks.json, registries.json, packets.json ...)
export DBCRAFT_CAPTURES_DIR=/path/to/tests/fixtures/captured     # play_nocomp.jsonl from tools/capture_vanilla.py (registries, tags, opaque packets)
docker compose up --build
```

## Mojang data

None of it is in the image or in git.  Two read-only mounts supply it:

| Mount | Needed for | Without it |
|---|---|---|
| `/data/reports` (`DBCRAFT_REPORTS_DIR`) | block states, items, packet ids (`ref.*`) | the server cannot run; the init script says so |
| `/data/captures` (`DBCRAFT_CAPTURES_DIR`), file `play_nocomp.jsonl` | datapack registries, tags, a few opaque packets, world reference data | logins stop in the configuration phase |

## What happens on first start

The official image initialises an empty data directory and then runs `docker/initdb.d/10-dbcraft.sh`: migrate (`tools/migrate.sh`, with `--dev-gateway` when
`DBCRAFT_DEV_GATEWAY=1`), load the reports, load the datapack from the capture, `mc.configure_dev_server()`.  `docker/entrypoint.sh` then starts PostgreSQL with
`-c config_file=/etc/dbcraft/postgresql.conf` and keeps `call net.run(25565)` running next to it (restarting it if it ends; `update net.gateway_control set stop = true`
stops it for good).  Later starts skip initialisation.

## Settings that matter (compose file)

* `ulimits.nofile` 65536: the gateway backend holds one socket per player; the default 1024 caps it near 1,000 players.
* `shm_size` 1 GB: `shared_buffers` is 1 GB (Docker's default 64 MB shared memory would make PostgreSQL refuse to start).
* Port 5432 is published on 127.0.0.1 only: a SQL session is the admin console of the whole server (it can edit the world and ban players).
* Durability: the world (`mc.chunk*`, players, inventories, settings, bans) is WAL-logged with `fsync = on`.  `synchronous_commit = off` can lose the last
  few hundred milliseconds of ticks after an operating-system crash, never corrupt the cluster.  The per-tick queues are `UNLOGGED` (rebuilt empty after a crash).
  Put the data volume on real storage, not on tmpfs.

## What was and was not verified

Docker is not available in the environment this was written in (a client but no daemon), so **the image was not built and the compose file was not run**.  What was run:
the configuration file was used to start a real PostgreSQL 16 cluster and the benchmark loop ran against it; `docker/initdb.d/10-dbcraft.sh` was run against that
cluster with the same environment variables the image sets; `bash -n` on the entrypoint scripts.  See the end of docs/TUNING.md for the exact commands.
