# dbcraft

A Minecraft: Java Edition **26.3** server whose state and logic live in **PostgreSQL**.  The world, the players, their inventories, the settings and even the
network protocol state machine are rows in tables and SQL functions; a small gateway only moves bytes between sockets and the database, once per tick (20 Hz).
Because it is a database, you can look at the server with `psql` and change it with `UPDATE`: a block placed from SQL appears in the game on the next tick.

This is a hobby project and an experiment.  It is **not** a replacement for a survival server yet (see [Status](#status)).

## Quickstart

On Ubuntu 24.04, as a normal user with `sudo` (or as root):

```
git clone <this repository> dbcraft && cd dbcraft
make setup        # packages, vanilla jar from Mojang, generator reports, a recorded capture, the database, the Rust gateway   (about a minute or two)
make up           # starts PostgreSQL and the gateway, prints the address
# connect a Minecraft Java 26.3 client to  localhost:25565   (offline mode: any name)
make status       # what is running
make down         # stop
```

`make setup` is idempotent (every finished step is skipped) and `tools/bootstrap.sh --check` reports what is missing without changing anything.
Nothing of Mojang's is in this repository: the **pinned server jar** is downloaded from Mojang's own launcher metadata and verified against its SHA-1
(`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`, Minecraft 26.3, protocol 777); the **data generator reports** are produced by running that jar's official generator;
a **capture** of a throwaway vanilla server (started and stopped by the script) supplies the datapack registries, tags and a few opaque packets the configuration
phase replays.  All of it lives under `~/.cache/dbcraft` (`$DBCRAFT_HOME`).  By running Mojang's server the script accepts Mojang's EULA on your behalf:
read <https://aka.ms/MinecraftEULA> first.

Requirements (installed by `make setup` through `apt`): `postgresql-16`, `libpq5`, `libpq-dev`, `libssl-dev`, `libcurl4t64`, `zlib1g-dev`,
`openjdk-25-jre-headless` (setup time only: the generator and the capture), `python3` (standard library only), `curl`, `unzip`, `ca-certificates`; `rustc`
to build the gateway (it builds with plain `rustc`, no cargo and no crates: `gateway/build.sh`; **tested only with rustc 1.97 from rustup**: Ubuntu 24.04's packaged
`rustc` is much older and has not been tried: if it fails, the build is skipped with a note and the PL/Python gateway is used); optionally `postgresql-plpython3-16` for the PL/Python
development gateway (offline mode only; it is the fallback when `rustc` is missing).  Docker is also supported, see [docker/README.md](docker/README.md).

## Edit the world with SQL

```
psql -h /tmp -p 54329 -U postgres dbcraft            # (the port is $DBCRAFT_PGPORT; see `make status`)

select name, gamemode, health, conn_id is not null as online from mc.player;
select mc.get_block('minecraft:overworld', 0, -61, 0);                       -- the grass block under the spawn
select mc.set_block('minecraft:overworld', 0, -60, 0, 'minecraft:gold_block');   -- appears in the game on the next tick
select mc.fill('minecraft:overworld', -5, -60, -5, 5, -58, 5, 'minecraft:stone');  -- a whole region, fast
update mc.blocks set block = 'minecraft:diamond_block'
 where dimension = 'minecraft:overworld' and x = 1 and y = -61 and z = 2;          -- the readable one-block-per-row view over the packed sections
select * from mc.chat_log limit 10;
select key, value from mc.server_property;                                        -- vanilla's server.properties, as rows
```

The world is stored in Minecraft's own wire format (palette + packed longs per 16x16x16 section) so a chunk packet is a lookup, and `mc.blocks` decodes it for you.

## Status

**What works** (and how it was checked; details and measurements in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)):

* A **real vanilla 26.3 client** joins, walks, builds and breaks blocks, chats, runs commands and stays connected for soak tests ([docs/REAL-CLIENT.md](docs/REAL-CLIENT.md)).
* The traffic matches the real vanilla server **byte for byte** where the bytes are deterministic: status, login, all 32 registry packets and the tags, the play
  entry burst, 49 of 49 recorded flat-world chunk packets and 49 of 49 real-terrain chunks re-encoded from rows, block updates, chat, tab list, teleports.
  Scripts compare dbcraft against recordings of a real server: `tests/sql/` (1,600+ checks) and `tests/e2e/`.
* Chunks and blocks in SQL (flat world generator, asynchronous generation queue, cached packets, `set_block`, the readable `mc.blocks` view), ops, whitelist, bans,
  inventories, movement validation, commands (`/tp /gamemode /give /time /weather /difficulty /op /deop /whitelist /list`), a set-based 20 Hz tick, an optional batched tick.
* A Rust gateway with **zero crates.io dependencies** (std + libpq/libcrypto/libcurl through hand-written FFI): epoll loop, AES-128-CFB8, RSA, the Mojang session
  check, inflate, per-IP limits ([docs/GATEWAY.md](docs/GATEWAY.md)).
* **Online mode**: the design and the login flow are verified end to end against a stub of Mojang's session server with an encrypting client (27 checks, with and
  without compression).  A real client in online mode has **not** been tested (it needs a Mojang account).
* An entity prototype (items and simple mobs as rows, physics checked against recorded vanilla trajectories with zero deviation): [docs/ENTITY.md](docs/ENTITY.md).

**What is missing:** survival gameplay (damage, death, hunger rules, crafting), terrain generation beyond flat worlds, importing/exporting vanilla worlds,
vanilla mob AI and pathfinding, redstone, fluids, a full light engine (sky light matches vanilla on about 76% of recorded layers), advancements and recipes
(replayed from a capture, not generated), the first-time-player join sequence, a real-client test of online mode.

**Performance, honestly:** the tick is one transaction on one core.  500 moving players fit roughly in the 50 ms budget with the batched tick; a crowded spawn
with 500 players does not, and 2,000 players do not.  Details, and what was tried and rejected, in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and `docs/PERF-*.md`.

## How it fits together

```
 Minecraft client ──TCP──▶ gateway (Rust, tiny, no game state) ──SQL, once per tick──▶ PostgreSQL
   (AES-CFB8, zlib)          epoll · AES · RSA · Mojang session check · inflate        net.inbox ─▶ net.process ─▶ mc.server_tick ─▶ net.outbox
                                       ▲                                                   │ players · chunks · blocks · entities · chat · rules
                                       └──────────── bytes to every socket, once per tick ◀┘   (everything is rows; the logic is SQL functions)
```

* `net.*` the connection state machine (handshake, status, login, configuration, play) and the byte queues; `mc.*` the game; `proto.*` the wire codec (VarInt,
  strings, positions, framing); `ref.*` the generated reference data (35,723 block states, items, registries, packet ids).
* The gateway only does what SQL cannot (sockets, AES, RSA, HTTPS, inflate).  The contract between it and the database is in [docs/GATEWAY.md](docs/GATEWAY.md).

## Repository layout

```
sql/          the whole server: numbered files applied in order (000 schemas, 010 ref, 020 proto, 1xx net, 2xx world, 3xx game, 4xx integration, 5xx entities, 6xx gateway)
              sql/OVERRIDES.txt lists every function defined twice and which file wins; sql/optional/ the PL/Python development gateway
gateway/      the Rust gateway (build.sh, README.md)         native/dbcraft_zlib/  optional C extension: fast deflate for chunk packets (SQL fallback exists)
tools/        bootstrap.sh, dev-up/down/status.sh, setup-db.sh, migrate.sh, loaders, capture_vanilla.py, pg-dev.sh, guards (check_*.sh/py)
tests/        sql/ (the suite), e2e/ (against recordings of vanilla), gateway/ (online-mode tests with a stub session server), corpus/ (adacraft's byte-exact scenarios), bench/
docs/         ARCHITECTURE.md (start here), per-module docs (NET, WORLD, GAME, GATEWAY, ENTITY), TUNING.md, REAL-CLIENT.md, PERF-*.md, *-EVALUATION.md
docker/       Dockerfile, Dockerfile.data (the setup-time Mojang data job), postgresql.conf, README.md        Makefile, docker-compose.yml
```

## Tests

```
make test          # tests/sql/prun.sh: builds one migrated template database, clones it per test file, runs 4 files at a time (about 5 minutes)
tests/sql/run.sh   # the same files one after another in one database
tests/e2e/run_all.sh   # end to end over TCP against recordings of the real vanilla server (see tests/e2e/README.md: needs `tests/e2e/record_vanilla.sh` once)
gateway/build.sh test  # the gateway's unit tests
```

The suite needs the data `make setup` creates (`$DBCRAFT_HOME`); tests that need extra recordings (e.g. `entity_traj_*.json` from `tools/entity/rcon.py record`, the
real-terrain chunk captures) **skip with a notice** when they are absent.  `tools/check_overrides.py`, `tools/check_inlining.sh` and `tools/check_fresh_migration.sh`
run at the end of the suite: they catch a later SQL file silently undoing an earlier one, which unit tests that re-include single files cannot see.

## Connecting a real client

Start `make up`, then in the Minecraft Java Edition 26.3 launcher add a server `localhost:25565`.  The default server is offline mode, creative, view distance 8.
To try the real-client flow headlessly (Xvfb, software rendering) see [docs/REAL-CLIENT.md](docs/REAL-CLIENT.md) and `tools/realclient/`.

## License and provenance

* **No licence has been chosen for dbcraft yet**; until the author adds one, all rights are reserved by default.
* **Mojang's data is not included** and must not be committed: the server jar, generator reports, captures and recordings are fetched or produced on your machine
  (`$DBCRAFT_HOME`, `tests/fixtures/captured/` is gitignored).  Minecraft is a trademark of Mojang AB; this project is not affiliated with Mojang or Microsoft.
* **adacraft** (the author's earlier Ada server) contributed: the version pin (26.3, protocol 777, SHA-1 of the jar), the strict framing rules the gateway
  follows (VarInt limits, 30 s read timeout), and the byte-exact scenario corpus in `tests/corpus/` (copied verbatim; hand-written transcripts, no Mojang data), plus
  copies of some Ada packages under `tests/bench/ada/adacraft/` used only for the language benchmark.  adacraft has no licence file either.
* **tcl-aot** (the author's project) is only referenced by the Tcl evaluation in `docs/`; none of its code is copied here.
