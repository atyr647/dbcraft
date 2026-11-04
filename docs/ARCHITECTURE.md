# dbcraft architecture

A Minecraft: Java Edition 26.3 (protocol 777) server whose state and logic live in PostgreSQL.  Everything that can be a row is a readable row; everything that
can be SQL is SQL.  This page is the map of how the three modules (connection `net`, world `mc` 2xx, game `mc` 3xx) fit together; the module documents have the detail:
[NET.md](NET.md), [WORLD.md](WORLD.md), [GAME.md](GAME.md), [SQL-GATEWAY.md](SQL-GATEWAY.md) (the gateway as database code), [COMPRESSION.md](COMPRESSION.md),
and the measurements behind the design choices ([EVALUATION.md](EVALUATION.md), [DATABASE-COMPARISON.md](DATABASE-COMPARISON.md), the language evaluations).

```
 Minecraft client ──TCP──▶  gateway  ──── net.inbox (COPY) ────▶ ┌─────────────── PostgreSQL ───────────────┐
 (real 26.3 client)         (bytes only: sockets,                 │ select mc.server_tick()   once per 50 ms  │
                             frame split, [AES, zlib])  ◀── net.drain_outbox() ◀── net.outbox               │
                                                                  │  1 net.process      handshake..join, protocol packets
                                                                  │  2 feed game queue  play packets + keep-alive/teleport answers
                                                                  │  3 mc.tick          clock, movement, input, chat/commands, visibility
                                                                  │  4 block actions    player_action / use_item_on -> mc.set_block
                                                                  │  5 block broadcast  block_update / level_event / acks
                                                                  │  6 chunk streaming  centre, forget, new chunks
                                                                  │  7 kicks, leavers   close + mc.on_leave
                                                                  │  8 drain            mc.play_out -> net.outbox
                                                                  └───────────────────────────────────────────┘
```

The gateway holds no game state and parses no packets.  Two gateways exist: the **development gateway**, a PL/Python stored procedure
(`sql/optional/dev_gateway.sql`, `call net.run(25565)`; offline mode, no compression), which is what the end-to-end tests use; and the production gateway
(Rust, evaluated in `docs/*-EVALUATION.md`), which must add AES-CFB8, the Mojang session check and deflate, and is **not built**.

## Schemas and files

| Schema / files | Contents |
|---|---|
| `ref` — `010_ref.sql`, `140_registry.sql` | generated reference data (blocks, block states, items, packet ids) and the datapack registries and tags as rows (`ref.dp_*`) |
| `proto` — `020_proto.sql` | wire codec: VarInt/VarLong, numbers, strings, UUID, positions, framing (pure functions) |
| `net` — `100`-`195` | connections, queues, handshake/status/login/configuration/entry, keep-alive, dispatcher `net.process()` |
| `mc` world — `200`-`240` | chunks and sections in wire format, `get_block`/`set_block`, the readable `mc.blocks` view, chunk packets and their cache, flat generator |
| `mc` game — `300`-`360` | settings, ops/whitelist/bans, players, inventory, movement, chat, commands, `mc.tick()` |
| integration — `400`, `410`, `420` | the wiring (this document) |
| `sql/optional/dev_gateway.sql` | `net.run`, the gateway as a stored procedure (`tools/migrate.sh --dev-gateway`) |

Persistent: the world (`mc.chunk*`, `mc.block_entity`), players, inventories, settings, bans.  Unlogged (rebuilt after a crash): `net.conn`, the queues,
`mc.visible`, `mc.block_event`.

## How the three modules were joined: decisions

| # | Overlap | Decision |
|---|---|---|
| 1 | two outbound queues (`net.outbox` from the connection layer, `mc.play_out` from the game) | the game and the integration write `mc.play_out` (uncompressed frames); **once per tick, at the end**, it is moved into `net.outbox` in generation order. So per connection `net.outbox` is: what the connection layer wrote while processing input (login ... join burst), then what the game produced this tick. A connection with compression gets its game frames re-framed (`net.reframe`); a frame at or above the threshold would need deflate (not in SQL), so that connection is closed and the error logged. The dev server runs with compression off |
| 2 | two entity-id sequences | the player row is created while the join record is built (`net.hook_join_info` calls `mc.on_join`), so the id in the `login` packet is the one `mc.player` holds and every `add_entity`/movement packet uses. `net.entity_id_seq` is unused in the integrated server; a test checks both layers agree |
| 3 | two settings sources | `mc.server_property` (vanilla's keys) is authoritative; a trigger copies the mapped keys (`net.setting_map`) into `net.setting`, which the connection layer reads. `mc.configure_dev_server()` sets what the dev server needs (offline, no compression, flat, spawn from the world) |
| 4 | duplicate join behaviour | the joiner's burst is the connection layer's (byte-identical to vanilla). `mc.on_join` also queued the joiner's own join message and tab entries: those are dropped (vanilla does not send a joiner its own join message). Everyone else gets, in vanilla's order, the join message, then the tab entry (`mc.on_join`), then the entity (visibility, same tick). `net.play_begin` is overridden so the connection layer's own broadcast of the tab entry only happens when no game player exists (its standalone tests) |
| 5 | keep-alive | the game owns scheduling and timeouts (set-based, first one 15 s after joining like vanilla); the connection layer forwards the client's answers. `net.keepalive_tick()` is not called |
| 6 | teleport confirmations | forwarded to the game (it tracks `awaiting_teleport` after a correction); the connection layer still records it |
| 7 | keep-alive/teleport/movement packets reach the game | `mc.server_tick` copies play packets from `net.play_inbox` and the answers it finds in the batch (`net.batch`) into the game's queue in arrival order, instead of overriding `net.h_play` (which its own tests pin) |

Overridden functions (create-or-replace copies with one marked change each, in `sql/400`): `net.h_login` (adds the login check: whitelist, bans, server full,
before login_finished) and `net.play_begin` (decision 4).  Hooks filled in: `net.hook_join_info`, `hook_on_join`, `hook_player_loaded`, `hook_disconnect`,
`hook_chunks`, `hook_login_check`.  Edits made to other modules' files, each because a real bug against vanilla was found by the integrated probes:
`sql/330_game_players.sql` (`mc.on_leave` sends the leave message before the entity removal; `mc.on_join` resets the per-session chat index), and the tooling
(`tools/pg-dev.sh` start is idempotent, `tools/migrate.sh --dev-gateway`, `tests/sql/run.sh` shows psql errors).

Block interaction (`sql/410`): `player_action` and `use_item_on` become `mc.set_block`; creative breaks on start, survival on stop; reach 5.5/6.0 (+1.0 slack over the
interaction range, read from the classes, not measured); no bedrock/barrier/command-block breaking in survival; placing needs a block item and a replaceable
target, no overlap with the placer, default state only; survival consumes the item and tells the client.  Changes are broadcast per position (net change per
tick) to every player whose client has the chunk (`net.conn.view_cx/view_cz`): `block_update`, the break effect `level_event` 2001 to everybody but the
breaker, and `block_changed_ack` last.  Chunk streaming: a player in another chunk gets `set_chunk_cache_center`, one `forget_level_chunk` per dropped chunk
(z first, then x), then the new chunks nearest first, in one batch.

## Verified against the real vanilla 26.3 server

Vanilla was run (jar SHA-1 `33680f5f...`, offline, flat, view distance 2) and a scripted client recorded what it sends; the same client then talked to dbcraft
over TCP and `tests/e2e/compare_*.py` compared the two (`tests/e2e/run_all.sh`, about two minutes; 47 comparisons, all passing):

| Scenario | Compared | Result |
|---|---|---|
| login + configuration | 38 packets | byte-identical, except 3 packets whose entries vanilla orders by hash (its own runs differ the same way): same bytes, any order; brand is a setting |
| entry burst (27 packets to `set_experience`) | order, and byte for byte where nothing can legitimately differ | same packets, same order; 15 packets byte-identical, recipes same content, entity/seed/position/time/spawn/motd fields masked |
| 49 chunks | each chunk | all 49 equal a vanilla chunk form (vanilla alternates 5 forms: heightmap entry order, a transient light layer) |
| block break, place, break again | actor and observer, per step | break: actor `[block_update, ack]`, observer `[level_event 2001, block_update]`; place: actor `[clicked, target, target, ack]`, observer `[target]`: identical |
| walking across chunk borders | centre, forgets, new chunks | 3 crossings identical (forget bodies z-first; new chunks nearest first; vanilla batches 6+1, dbcraft 7 in one) |
| two players: join, chat, leave | tab entries, join/leave messages, chat | `system_chat`, `player_info_update`, `player_info_remove` byte-identical; `player_chat` identical up to the text; `add_entity` same uuid and length; the joiner gets no join message |

Also: `tests/sql/410_integration_replay.sql` replays the recorded session through the whole tick with the real hooks: all 65 clientbound packets from `login_finished`
to `set_experience` byte-for-byte, then 49 chunks (46 byte-identical, the other 3 are vanilla's transient light form), the batch framing, nothing else sent.  The game module's own
replays still pass in the integrated database: 17/17 scenarios, 20/20 packets.  `tests/sql/420_integration_behaviour.sql` (66 checks) drives logins, joins, keep-alive,
teleports, block actions, streaming, kicks and compression through `net.inbox` and `mc.server_tick`.  The whole suite: **16 files, 724 checks**.

Two game-module bugs were found only by this integrated comparison (the per-kind checks of the module could not see them) and fixed: the leave sequence order and the
chat message index surviving across sessions.

## Not verified, not built

* **Not compared with vanilla**: the follow-up packets of block changes (`block_entity_data` for a block with a block entity, `light_update`), survival break timing (the client's word is trusted), `teleport_entity`, several command feedback keys
  (`docs/GAME.md`), keep-alive timing, two real clients' chunk batching, behaviour with a real vanilla client (the test client is a scripted one that answers like a real one).
* **A first-time player** gets a different burst from a returning one in vanilla; since `sql/906` dbcraft generates both (compared with the real server, [PLAYER-VISIBILITY.md](PLAYER-VISIBILITY.md)).  The recipes themselves and the advancement update are still captured bytes.
* **Opaque rows**: the `update_recipes` and `recipe_book_add` packets (the recipes themselves are rows now, [CONTAINERS.md](CONTAINERS.md)), the command tree (`commands`) and advancements are stored as captured bytes
  (`net.static_packet`), correct for a flat world, not generated from rows.  A player's own entity data, attributes and equipment are generated from rows (`sql/900`-`910`).
* **Online mode** (RSA, session check, AES-CFB8) and **deflate**: none in SQL; the production gateway has to do them. Without deflate, no packet can be compressed, so
  the dev server runs uncompressed (a join is about 3.3 MB at view distance 9).
* **World**: flat by default; `dbcraft.generator = dbcraft:noise` selects a seeded terrain generator that is not vanilla's (docs/WORLD.md "Terrain generator": no caves, ores, trees or structures).
  Light is the straight-down model (exact for flat worlds; 76% of sky layers on real terrain). No block light, no biomes API, no
  structures, block entity data is raw bytes.
* **Gameplay**: no mobs or other entities beyond players (the player-side survival core -- health, hunger, falls, the void, death, respawn, eating, experience -- is in [SURVIVAL.md](SURVIVAL.md)), no redstone or block ticks (grass does not spread), placement uses default states only, no
  containers beyond chests, barrels, ender chests, the crafting table and furnaces ([CONTAINERS.md](CONTAINERS.md)), no sounds, entity data of players, equipment, attributes and the locator bar exist (PLAYER-VISIBILITY.md), chat and command rate limits exist (SQL-tested only), no chat signing; about 70 of vanilla's commands answer "not implemented".
* **Operations**: (per-client view distance and tracking range exist for players, see PLAYER-VISIBILITY.md; mobs still use the server's) idle-socket timeouts in the dev gateway, a write-buffer limit, autosave policy (the world is persisted by the database; the queues are unlogged)
  several dimensions, chunk generation off the tick (below).
* **Parallelism**: one connection runs the tick. Region sharding (one connection per region) was measured to scale poorly on this machine ([DATABASE-COMPARISON.md](DATABASE-COMPARISON.md)) and is unproven.

## Performance (4 cores shared with the load generator, PostgreSQL 16, `jit=off`; `tests/bench/integration/`)

The 50 ms budget is **not met** by the whole tick at 500 players who all move; it is met on average at 500 players with 20% moving.

500 simulated players over 100 x 100 chunks (about 19 viewers each), view distance 10, a warm world (every chunk generated and cached), each tick through
`net.inbox` -> `mc.server_tick` -> `net.drain_outbox`:

| Scenario | tick avg | p50 | p95 | p99 | max | of which: process / game (moves, visibility) / blocks / chunk streaming / drain |
|---|---|---|---|---|---|---|
| 100% moving | **81.8 ms** | 79.3 | 107.2 | 120.8 | 130.7 | 5.7 / 44.5 (28.3, 10.8) / 2.0 / 24.8 / 4.8 |
| 20% moving | **48.5 ms** | 46.7 | 73.2 | 106.1 | 142.8 | 4.6 / 25.7 (15.3, 6.3) / 2.0 / 13.3 / 2.9 |

* The synthetic walk makes players dither across chunk borders: about 420 chunk frames (1.1 MB) per tick at 100% moving, which is why chunk streaming is a quarter of the tick.
  A world not yet generated is far worse: **358 ms** average for the same load (chunk streaming 294 ms), because a never-visited chunk costs about **5 ms** (3.9 ms to generate, 1.1 ms for its
  first packet) while a cached one costs about **15 us**.  Chunk generation happens on the tick, so exploring blocks everybody; it should move to background workers (not done).
* The game module's own tick at 500 sparse moving players was 40 ms (`docs/GAME.md`); the integration adds the connection layer (6 ms), chunk streaming and the queue drain.

Join (a real login through `net.inbox`, one tick):

| View distance | chunks | empty world (generated on demand) | chunks exist (cache) | sent to the joiner |
|---|---|---|---|---|
| 2 | 49 | 646 ms | 129 ms | 0.55 MB |
| 9 | 441 | 4.7 s | 298 ms | 3.27 MB |
| 10 | 529 | 6.3 s | 379 ms | 3.88 MB |

A join into an existing world stalls the tick for 0.1 to 0.4 s; into an unexplored one for seconds.

Storage of a 441-chunk flat area (view distance 9), compacted: **4.3 MB in all, about 10 KB per chunk**: `mc.chunk` 1.9 MB, `mc.chunk_section` 1.9 MB (one section row per flat chunk), `mc.chunk_light`
0.33 MB (3 layers), `mc.chunk_cache` 0.26 MB (441 cached packets of about 7.3 KB each fit in 0.26 MB, so Postgres stores them compressed; I did not inspect the TOAST storage directly).  Note: before a
`VACUUM FULL` the same tables read 88 MB, because deleting thousands of chunks earlier in the session does not shrink the files.

## Running it

```
tests/e2e/setup.sh                      # cluster :54399, schema + dev gateway, reference data, dev-server settings (needs one vanilla capture, see tests/e2e/README.md)
tests/e2e/gateway.sh start 25565        # call net.run(25565); stop with: update net.gateway_control set stop = true
tests/e2e/run_all.sh                    # all end-to-end comparisons (after tests/e2e/record_vanilla.sh)
tests/sql/run.sh                        # the SQL suite in a fresh database (DBCRAFT_TESTDB=name to keep runs apart)
tests/bench/integration/run.sh 500 100 1.0 100;  tests/bench/integration/join.sh      # the measurements above
```
The development gateway needs superuser (`plpython3u`), a raised open-file limit for more than ~1,000 connections (`tools/pg-dev.sh` sets `ulimit -n 20000`; use `LimitNOFILE`
in a service file), `online-mode=false` and `network-compression-threshold=-1` (it refuses to start otherwise: `select mc.configure_dev_server()`).
