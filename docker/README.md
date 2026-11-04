# Running dbcraft in a container

PostgreSQL 16 with PL/Python, the dbcraft schema, the recommended server configuration (`docker/postgresql.conf`, explained in [docs/TUNING.md](../docs/TUNING.md)) and,
optionally, the **development gateway** (the PL/Python procedure `net.run`, offline mode, no compression) listening on port 25565.

The container uses the PL/Python development gateway (offline mode only).  The Rust gateway (online mode, encryption, deflate) is built on the host with `make gateway`
and is not part of this image (the Debian base image's `rustc` is too old to rely on; building it in a container is a follow-up).

```
export DBCRAFT_PASSWORD=choose-one
docker compose up --build
```

That is all: the first run starts a one-shot job (`mojang-data`, `docker/Dockerfile.data`) that runs `tools/bootstrap.sh --data-only` into the volume `dbcraft-mojang`.
It downloads the pinned vanilla server jar from Mojang (SHA-1 verified), runs the official data generator from it and records a capture of a throwaway vanilla server
(about two minutes, needs Internet access; by running Mojang's server it accepts Mojang's EULA for you, <https://aka.ms/MinecraftEULA>).  `dbcraft` starts after it
has finished, mounts the volume read-only at `/data` and initialises the database from it.  Later runs find the finished volume and skip the job.

## Mojang data

None of it is in an image or in git.  It lives in the volume `dbcraft-mojang`, which the job fills on your machine:

| Path in the volume | Made by | Needed for | Without it |
|---|---|---|---|
| `/data/reports` | the official data generator, run from the downloaded jar | block states, items, packet ids (`ref.*`) | the server cannot run; the init script says so |
| `/data/captures/play_nocomp.jsonl` (+ a few more) | `tools/capture_vanilla.py` against a throwaway vanilla server | datapack registries, tags, a few opaque packets, world reference data | logins stop in the configuration phase |
| `/data/captures/play_op4.jsonl` (and `play_op1` .. `play_op3` for the tests) | the same, with an operator of that level joining | the command graph (`tools/load_command_tree.py`, run by `load_static_packets.py`) | every player gets the static level-0 command tree |

You can still mount your own reports and captures instead (replace the volume by bind mounts of `/data/reports` and `/data/captures`).

## What happens on first start

The official image initialises an empty data directory and then runs `docker/initdb.d/10-dbcraft.sh`: migrate (`tools/migrate.sh`, with `--dev-gateway` when
`DBCRAFT_DEV_GATEWAY=1`), load the reports, load the datapack from the capture, `mc.configure_dev_server()`.  `docker/entrypoint.sh` then starts PostgreSQL with
`-c config_file=/etc/dbcraft/postgresql.conf` and keeps `call net.run(25565)` running next to it (restarting it if it ends; `update net.gateway_control set stop = true`
stops it for good) and `tools/janitor.sh`, which vacuums and analyses the hot tables every 5 s: the gateway is one long `CALL` that never goes idle, so autovacuum cannot see its churn (docs/TUNING.md).  Later starts skip initialisation.

## Settings that matter (compose file)

* `ulimits.nofile` 65536: the gateway backend holds one socket per player; the default 1024 caps it near 1,000 players.
* `shm_size` 256 MB: `shared_buffers` is deliberately small, 128 MB (a larger one makes every tick's commit slower, docs/TUNING.md); 64 MB of Docker's default shared memory would be too little.
* Port 5432 is published on 127.0.0.1 only: a SQL session is the admin console of the whole server (it can edit the world and ban players).
* Durability: the world (`mc.chunk*`, players, inventories, settings, bans) is WAL-logged with `fsync = on`.  `synchronous_commit = off` can lose the last
  few hundred milliseconds of ticks after an operating-system crash, never corrupt the cluster.  The per-tick queues are `UNLOGGED` (rebuilt empty after a crash).
  Put the data volume on real storage, not on tmpfs.

## What was and was not verified

Docker is not available in the environment this was written in (a client but no daemon), so **the image was not built and the compose file was not run**.  What was run:
the configuration file was used to start a real PostgreSQL 16 cluster and the benchmark loop ran against it; `docker/initdb.d/10-dbcraft.sh` was run against that
cluster with the same environment variables the image sets; `bash -n` on the entrypoint scripts.  See the end of docs/TUNING.md for the exact commands.

The setup-time data job (`docker/Dockerfile.data`) runs `tools/bootstrap.sh --data-only --no-apt`.  That exact command was run on the host in an empty directory
(`DBCRAFT_HOME=...`, about 70 s: jar download and SHA-1 check, generator, recordings; exit 0); the image build and `docker compose up` themselves were **not** run.
Known limits: the image uses the PL/Python development gateway (the Rust gateway is built on the host), and `ubuntu:24.04` must provide `openjdk-25-jre-headless`
(it does on the machine this was tested on; the package comes from the `noble-updates` pocket).
