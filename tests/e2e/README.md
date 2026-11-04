# End-to-end tests

A complete dbcraft server (a PostgreSQL cluster, the schema, and the gateway running as a stored procedure in that database) is built, real clients connect
over TCP, and everything they receive is compared with what the **real vanilla 26.3 server** sent the same clients.

```
tests/e2e/record_vanilla.sh     # once: records the vanilla baselines (starts its own vanilla server in /tmp/vanilla-int, port 25611)
tests/e2e/run_all.sh            # builds the database, starts the gateway, runs the probes, compares, stops the gateway
```

## What it needs

| Need | Where it is used |
|---|---|
| PostgreSQL 16 with `plpython3u` (`postgresql-plpython3-16`), run as the `postgres` OS user by `tools/pg-dev.sh` | the database and the gateway procedure |
| the official 26.3 `server.jar` (SHA-1 `33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`) and Java 25 | `record_vanilla.sh` only |
| the data generator reports (`DBCRAFT_REPORTS`, default the adacraft checkout) | block, item and packet ids |
| one vanilla capture with the configuration phase: `tests/fixtures/captured/play_nocomp.jsonl` (`tools/capture_vanilla.py`) | `setup.sh` loads the datapack registries, tags and a few opaque packets from it |

Recordings and captures contain Mojang data and are never committed.

## The pieces

| File | What it does |
|---|---|
| `setup.sh` | cluster on port 54399, migrate with `--dev-gateway`, load reference data, `mc.configure_dev_server()`; view distance 2 |
| `gateway.sh start|stop|status|log` | `call net.run(25621)` in the background; `net.gateway_control` holds the stop flag and tick statistics |
| `mcclient.py` | a small 26.3 client: offline login, configuration, play, with the replies a real client sends (keep-alive, teleport confirm, chunk batch) |
| `block_probe.py` `move_probe.py` `join_probe.py` `fill_probe.py` | the scripted scenarios; they work against either server (`fill_probe.py` runs `/fill` and `/setblock` batches over RCON on vanilla and SQL on dbcraft) |
| `compare_join.py` | login, configuration, the 27-packet entry burst, the 49 chunks |
| `compare_block.py` | block_update / level_event / block_changed_ack for the actor and an observer |
| `compare_move.py` | set_chunk_cache_center, forget_level_chunk and new chunks while walking |
| `compare_social.py` | join message, tab list, entity, chat, leave message, for two players |
| `compare_fill.py` | `block_update` / `section_blocks_update` for 32 steps: sizes 24 .. 4096 around every rehash threshold of vanilla's position set, overlapping fills, no-op fills, batches in one tick; every `section_blocks_update` compared byte for byte (see docs/WORLD.md "Block change packets") |
| `dyn_probe.py` | world dynamics: fluids, falling blocks, block support, tick by tick (vanilla: `/tick freeze` + `/tick step 1` over RCON and a scripted client; dbcraft: SQL, the clock moved by hand); `compare` requires every tick's packets equal; see docs/WORLD-DYNAMICS.md.  `dyn_probe.py vanilla --port P --rcon R --out v.json`, `dyn_probe.py dbcraft --psql '...' --out o.json`, `dyn_probe.py compare v.json o.json` |
| `survival_probe.py`, `compare_survival.py`, `survival.sh` | survival (fall, /kill and respawn, the void, eating): two scripted clients against vanilla and dbcraft, the packets the survival rules produce compared in order (docs/SURVIVAL.md); `survival.sh record PORT` records vanilla, `survival.sh compare PORT` replays against dbcraft |

## What the comparisons allow to differ (and why)

* **Order inside two packets** (a registry and the tags): vanilla orders them by hash and two runs of vanilla differ from each other the same way.  They are
  compared as the same bytes in any order; the byte-exact proof against one capture is in `tests/sql/130_net_config_play.sql` and `410_integration_replay.sql`.
* **Per-server values**: entity ids, the hashed seed, spawn position (vanilla spreads spawns at random), game time, MOTD, brand: masked.
* **Player state replayed from the capture**: advancement dates and saturation: length only.
* **Chunk batches**: vanilla splits a join into several batches and orders equally distant chunks differently each time; dbcraft sends one batch, nearest
  first.  The chunks' bytes are compared (after putting the heightmap entries in one order, which vanilla also varies).
* **What vanilla sends and dbcraft does not**: waypoints, sounds, entity metadata and attributes, swing animations, other entities' movement, random-tick
  block changes, `light_update` after block changes (no light engine; `compare_fill.py` lists it).  Listed by the comparisons, not failures.
* **A first-time player** gets a different burst from a returning one (a `recipe_book_add` instead of `update_attributes`); dbcraft emulates the returning
  player and the comparison uses a returning baseline.
