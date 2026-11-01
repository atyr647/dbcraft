# The connection layer (`net.*`)

Everything between a socket and the game, in SQL: handshake, status, login (offline mode), configuration, entering play, keep-alive,
and the protocol-level packets of play.  The gateway only moves bytes; it parses no packets and holds no state.

Files: `sql/100_net.sql` (tables, helpers) · `110_nbt.sql` (text components) · `120_net_login.sql` · `130_net_config.sql` · `140_registry.sql`
(registry and tag rows + encoder) · `150_net_play_entry.sql` · `160_net_play.sql` · `190_net_hooks.sql` · `195_net_process.sql` (dispatcher).
Tools: `tools/load_datapack.py`, `tools/load_static_packets.py`, `tools/capture_to_tsv.py`, `tools/corpus_to_tsv.py`.  Tests: `tests/sql/1xx_net_*.sql`.

## Contract with the gateway

| Direction | What | How |
|---|---|---|
| in | one row per frame | `COPY net.inbox (conn_id, payload)`: payload = the frame **without its length prefix** = VarInt packet id ‖ body. If compression is on for the connection the gateway has already inflated it and stripped the data length. |
| in | a socket was accepted / closed | `select net.on_connect(conn_id)` / `select net.on_disconnect(conn_id)` |
| tick | do the work | `select net.process()` (returns the number of frames consumed), then the game's `mc.tick()`, `net.keepalive_tick()` about once a second |
| out | what to write | `select * from net.drain_outbox()` → `(conn_id, data, close)`. `data` is complete wire bytes (framed, and compressed below the threshold) in order; encrypt them if the connection is encrypted; when `close` is true close the socket after writing. Rows of closed connections are deleted by the drain. |

The gateway never has to know packet ids, layouts, states or the compression threshold (`net.conn.compression`) except to inflate inbound frames it
receives while compression is on.

## Tables

`net.conn` (one row per socket; unlogged, fillfactor 60, only the primary key indexed so updates stay in place) · `net.inbox`, `net.outbox`,
`net.play_inbox`, `net.batch` (unlogged queues, no indexes) · `net.setting` (motd, max players, brand, compression threshold ...; `net.default_settings()`
lists the defaults) · `net.config_cache` (finished configuration packets per known-pack combination) · `net.static_packet` (opaque packets, below) ·
`ref.dp_*` (data-driven registries and tags as rows, below).

Connection states: `handshake → status` or `handshake → login → login_ack → configuration → play`.

## What `net.process()` does

1. Takes every row out of `net.inbox` into `net.batch`.
2. **Hot path, set-based:** play-state packets that this layer does not handle (movement, chat, digging ...) and whose id exists are moved into
   `net.play_inbox (conn_id, seq, packet_id, body)` for `mc.tick()`.
3. **Everything else, one connection at a time in arrival order** (each packet can change the state that decides how the next is read): handshake, status,
   login, configuration, and the protocol-level play packets (`keep_alive`, `pong`, `accept_teleportation`, `chunk_batch_received`, `player_loaded`,
   `client_information`, `custom_payload`).  A failing packet (truncated, wrong state, unknown id) closes **that connection only**, inside its own
   subtransaction; its partial work is rolled back.  Unexpected packets close silently (as adacraft's corpus requires); malformed ones in login/configuration/play
   send vanilla's generic-reason disconnect first.

## Hooks (the game and world layers replace these)

`sql/190_net_hooks.sql`, all `create or replace`, all no-ops now:

| Hook | Replace with |
|---|---|
| `net.hook_join_info(conn) → net.join_info` | the player's real row: position, game mode, health, dimension, world time, border, spawn ... (`net.default_join_info` shows every field) |
| `net.hook_on_join(conn)` | `mc.on_join(conn_id, uuid, name)` (create/load the player) |
| `net.hook_player_loaded(conn)` | whatever should start when the client says it has loaded |
| `net.hook_disconnect(conn)` | save and remove the player |
| `net.hook_chunks(conn, cx, cz, radius) → setof bytea` | `level_chunk_with_light` **bodies** (no id, no frame), nearest first; the layer wraps them in `chunk_batch_start … chunk_batch_finished(count)` |

## Registries and tags are rows

`tools/load_datapack.py` reads the configuration phase of a vanilla server (a capture from `tools/capture_vanilla.py`) into:

* `ref.dp_registry` / `ref.dp_entry`: 32 registries, 432 entries (biomes, dimension types, damage types, enchantments, ...). `seq` is the order they are sent in
  and the numeric id other packets use.
* `ref.dp_node`: each entry's NBT as a tree, one row per tag (`type` is a readable generated column: `compound`, `string`, `float`, ...). Child order is kept
  (`idx`), and byte/short/int/long and float/double stay distinct, so nothing is lost: **re-encoding every packet from the rows is byte-identical** (tests).
* `ref.dp_tag_registry` / `ref.dp_tag` / `ref.dp_tag_member`: 15 tag registries, 773 tags, 19,662 members as names, resolved back to ids when encoding
  (data-driven registries count from their `seq`, built-in ones use the generated protocol ids in `ref.registry`).

Editing a biome is an `UPDATE` of one `ref.dp_node` row.  The edit clears the entry's `from_pack` mark (so even a client that has the core pack gets the new
data) and empties `net.config_cache`, which is rebuilt on next use.  A client that answers `select_known_packs` with `minecraft:core:26.3` gets the same entries
as names only (vanilla does exactly this, and it matches byte for byte); the registry part shrinks from about 153 KB to about 9 KB, the tags (58 KB) stay.

The datapack is **Mojang's data, read from your own server at load time; it is never committed.**  The bootstrap is: run a vanilla 26.3 server once, run
`tools/capture_vanilla.py`, run the two loaders.  A loader straight from the server jar's JSON is not written (JSON does not say whether `0.5` is a float or a
double and compound order matters to byte-exactness; the capture is lossless).

## What is verified against a real vanilla 26.3 server

Captures were made with `tools/capture_vanilla.py` against the official `server.jar` (SHA-1 `33680f5f...` as pinned in adacraft), offline mode.  Byte for byte:

* status response (JSON text, key order, no favicon) and pong
* `login_finished` (the last 16 bytes, a random session id, are masked), `login_compression`, the invalid-name disconnect, the incompatible-version disconnect
* the three configuration packets, all 32 `registry_data` packets in both variants (no known packs; core pack known), `update_tags`, `finish_configuration`
* **all 65 clientbound packets from `login_finished` to the end of the play-entry burst** replayed through `net.process()` (login, difficulty, abilities, held slot,
  recipes, entity event, commands, recipe book, position, server data, both player-info packets, border, time, spawn, game event, ticking, chunk center,
  post effects, container content, own entity data and attributes, advancements, health, experience)
* the play-state disconnect (NBT text component) vanilla sends for a malformed packet
* compressed framing below a threshold of 256 (`00` data length)

Also: adacraft's golden corpus (14 of its 20 scenarios apply to SQL; the other 6 test frame-level errors that belong to the gateway).

### Findings that differ from what we expected (worth knowing for adacraft)

* **`login_finished` has a 16-byte session UUID after the profile in 26.3.** adacraft's hand-written corpus bytes (`login-offline-happy`) end after the property count,
  so a client would reject them.  The test checks that our output equals the corpus bytes plus those 16 bytes.
* **`accept_teleportation` is `id VarInt + x y z (doubles) + yRot xRot (floats)`**, not just the id; a VarInt alone is a decode error that disconnects the client.
* Vanilla ignores the UUID in the client's `hello` in offline mode (we do too); adacraft's text says it must match.
* A wrong protocol version is refused with a `login_disconnect` immediately after the handshake (vanilla: `{"translate":"multiplayer.disconnect.incompatible","with":["26.3"]}`).
* Registry entries reference dimension types by registry index, and the `set_time` packet now carries world clocks (`[{id, totalTicks, partialTick, rate}]`).

## What is only structurally right (no vanilla oracle)

* `client_information` / brand parsing (layout read from the class; tested with bytes built here, not sent by a real client).
* Keep-alive: sending, answer matching, timeout kick (no keep-alive appears in a 6-second capture).
* The player-info packet for a second player and the broadcast to existing players (format is the verified one; two real players were never captured).
* `chunk_batch_start` / chunk framing / `chunk_batch_finished(count)`: the framing is the one seen in the capture; the chunk bodies themselves come from the world layer.
* Status JSON escaping of unusual characters in the MOTD (vanilla's Gson may escape `<`, `>`, `&`, `'`; we emit plain JSON).
* Name validation: 1 to 16 characters from `!` to `~` (vanilla accepts an empty name; adacraft and we do not).

## Not done

* **Online mode.** Hook design below.
* **Deflate.** Frames at or above the threshold call `net.deflate_frame`, which raises (the connection is dropped with that reason) until a native implementation
  is installed (`docs/COMPRESSION.md`).  The default threshold is -1 (off), where everything works.  Below-threshold framing is done and verified.
* **Opaque packets** (stored as captured bytes in `net.static_packet`, loaded by `tools/load_static_packets.py`): `update_recipes`, `commands`, `recipe_book_add`,
  `update_advancements`, and the player's own `set_entity_data` / `update_attributes`.  They are right for a creative player in a flat world and are **not** generated
  from rows yet.  `commands` should come from the command definitions in `mc`, recipes from the recipe tables, advancements from the advancement rows.
* Chunks, entities, movement, chat, inventory and everything else in play: the world and game layers.
* Transfer intent (3), cookies, resource packs, server links, the code-of-conduct screen, re-entering configuration from play, chat signing (the "initialize chat" action is always absent).
* The tick glue (`mc.tick`) is not here; `net.process()` and `net.keepalive_tick()` are the calls it should make.

## Online-mode design (the original sketch; implemented differently, see docs/GATEWAY.md)

> **Update.** Online mode is now implemented (`sql/600_gateway.sql`, `sql/601_online_login.sql`, `docs/GATEWAY.md`).  It differs from the sketch below in two ways: there is
> no `net.auth_job` table to poll (the database marks the connection `await_key` and the gateway learns it from `net.gateway_ctl()`, which also carries compression and
> state changes), and the verdict goes into `net.auth_result` and is applied by `net.apply_auth_results()` before the game tick.  The sketch is kept for its reasoning.

Needs RSA decryption, AES-CFB8 on the socket and an HTTPS call to Mojang's session server: none of that can be SQL, so the gateway does exactly that and nothing else.

1. `net.h_login` on `hello` with `online_mode = true`: SQL generates a 4-byte challenge, stores it on the connection, and queues `encryption_request`
   (`serverId` string, `publicKey` bytes, `challenge` bytes, `shouldAuthenticate` bool; the gateway publishes its DER public key once, into `net.setting`).
2. The client's `key` packet (`keybytes`, `encryptedChallenge`) cannot be handled in SQL, so `net.h_login` copies it into a new `net.auth_job (conn_id, name, keybytes,
   encrypted_challenge, ip)` table instead.
3. The gateway watches `net.auth_job` (poll, or `LISTEN`): decrypts both with its private key, checks the challenge, switches that socket to AES-CFB8 with the shared secret,
   computes Minecraft's signed SHA-1 server hash, asks Mojang `hasJoined`, and writes `net.auth_result (conn_id, ok, uuid, name, properties jsonb)`.
4. SQL reads the result: on success it sets `net.conn.encrypted`, stores the real UUID and sends `login_finished` with the real profile properties (skins); on failure a
   `login_disconnect` with `multiplayer.disconnect.authservers_down` or `multiplayer.disconnect.unverified_username`.  Everything queued for an encrypted connection is
   written through the cipher by the gateway.

## Performance (shared 4-core container, single runs; `tests/bench/net/perf.sql`)

| What | Time |
|---|---|
| `net.process()` forwarding 5,000 movement frames from 1,000 players to `net.play_inbox` | 22-30 ms (about 5 us per frame) |
| `net.keepalive_tick()` for 1,000 players | 17 ms |
| `net.drain_outbox()` for 1,000 connections | 2 ms |
| one full join (handshake to the end of the entry burst), warm cache | about 17 ms (of which the entry packets 8 ms, the cached registry copy 3 ms) |
| building the config cache (once per known-pack combination, until a registry row is edited; call `net.config_cache_build('')` at startup to pay it up front) | about 1.1 s full, 0.5 s for the known-core variant (the NBT encoder walks 6,873 nodes, the tags encoder 19,662 members) |
| bytes of configuration data per join, no compression | about 211 KB with no known packs; about 67 KB for a client that has the core pack (58 KB of that is the tags packet) |

Lessons that cost time: a **volatile function inside a SQL function stops the planner inlining it** (`net.frame` went from 300 us to 8 ns per call when the
`net.deflate_frame` stub was declared `STABLE`); a large **SQL function returning a table is re-planned on every call** (5 ms), where the same body in plpgsql is
planned once per session; `proto.varint_read` is not inlinable (CTE chain, about 0.3 ms per call from plpgsql), which is fine for the rare handshake/login packets
and is why the hot path uses the lax `net.pid()` instead.  A join storm is therefore bound by about 17 ms of database time per player; sending the known-core variant
shrinks the bytes, not that cost.

## Running the tests

```
tools/pg-dev.sh start
tools/capture_vanilla.py --out tests/fixtures/captured/play_nocomp.jsonl               # vanilla 26.3 on 127.0.0.1:25599, offline, flat, no compression, whitelist off
tools/capture_vanilla.py --known-core --out tests/fixtures/captured/play_known.jsonl
tools/capture_vanilla.py --status --out tests/fixtures/captured/status.jsonl
tools/capture_vanilla.py --name "has space" --out tests/fixtures/captured/badname.jsonl
tools/capture_vanilla.py --bad-teleport --out tests/fixtures/captured/play_disconnect.jsonl
tools/capture_vanilla.py --port N --out tests/fixtures/captured/play_comp256.jsonl      # a second server with network-compression-threshold=256
DBCRAFT_TESTDB=dbcraft_net tests/sql/run.sh                                             # all files, one database
```

Every capture-based check skips with a `SKIP` notice when its capture is missing, so the suite still runs without a vanilla server.  Captures are gitignored.
238 checks across the net tests (35 status/login/corpus, 67 replay, 15 compression, 80 registry, 41 handlers).
