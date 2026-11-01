# Game module: players, permissions, movement, chat, commands, tick (SQL)

Everything here is SQL (PL/pgSQL where a loop or exception handler is needed) in `sql/300`-`sql/360`.  Nothing in it opens a socket or knows about TCP.

## What was checked against the real server, and how

A vanilla 26.3 server (the jar whose SHA-1 is pinned in adacraft) was run in offline mode and driven by scripted clients (`tools/game_probe.py`).
Everything those clients received was recorded byte for byte.  Two checkers compare the SQL with those recordings:

| Checker | What it does | Result |
|---|---|---|
| `tests/game_replay.py` | Rebuilds the recorded situation in SQL (same players, same UUIDs, same entity id), runs the command/join/leave/chat/kick, and compares each player's received frames, in order | **17 of 17 scenarios byte-identical** |
| `tests/game_verify.py` | Builds single packets with the SQL builders and compares them with the recorded packets | **20 of 20 byte-identical** |
| `tests/sql/*.sql` | Pure SQL assertions (settings, bans, login checks, join/leave, visibility, movement rules, chat, slots, keep-alive, tick) | **209 checks pass** (9 reference + 86 codec + 21 + 48 + 45 game) |

Byte-identical against the real server (every packet listed was compared as a whole frame):
`system_chat` for: join and leave messages, `/list`, `/time set day`, `/weather clear`, `/gamemode` (the one the executor gets and the one the target gets),
`/tp`, `/give`, `/op`, `/deop`, `/difficulty` (the "already that difficulty" failure), `/whitelist list` (empty), and **unknown command** (two messages);
`player_info_update` (join with all actions, game mode change), `player_info_remove`, `add_entity` for a player, `move_entity_pos`, `move_entity_pos_rot`,
`move_entity_rot`, `rotate_head`, `player_position` (the correction after an illegal jump, and the one after `/tp`), `player_chat`, `disguised_chat` (`/say`),
`player_abilities`, `game_event` (change game mode), `container_set_slot` (after `/give`, merging into an existing stack), `disconnect` for the movement kick,
and `set_time` in both forms (periodic, and with one clock entry).

## Rules the real server follows, found by experiment (and implemented)

| Behaviour | Measured |
|---|---|
| Two position-carrying packets (`move_player_pos` or `move_player_pos_rot`) with no `client_tick_end` between them | disconnect `multiplayer.disconnect.invalid_player_movement`. A real client sends `client_tick_end` every tick. Rotation-only and status-only packets were not limited (5 in a row tried) |
| NaN or infinite coordinate or angle | the same disconnect. Coordinates beyond 3.0E7 are accepted (clamped), yaw 400 and pitch 120 are accepted |
| A single packet moving a stationary player more than 10 blocks | refused: the player gets `player_position` with the old position, zero delta and a new teleport id; further moves are ignored until `accept_teleportation` echoes it. 9.9 blocks accepted, 10.1 refused, in survival and in creative |
| `accept_teleportation` in 26.3 | VarInt id plus x, y, z (doubles) plus yaw, pitch (floats). A VarInt alone fails to decode (this was the first thing memory got wrong) |
| Entity movement packets in 26.3 | `[entity VarInt][flags VarInt: bit 0 on ground, remaining bits = step count][steps: ticks VarInt + three shorts in 1/4096 block]`; rotations are `floor(degrees * 256 / 360)`; `move_entity_rot` is `[entity][bool][yaw][pitch]` |
| Periodic `set_time` | once a second (20 ticks), game time only with an empty clock list. `/time set` sends one clock entry |
| `/tp` with integer coordinates | centres them on the block (10 becomes 10.5) |
| Plain strings among compounds in a text component `with` list | wrapped as `{"": value}` (an unnamed key); a bare plain text root is a string tag |

## Connection-layer contract

```
gateway  --insert-->  mc.play_in (conn_id, packet_id, body)     decoded play-state packets in arrival order (seq is an identity column)
select mc.tick();                                                one call per 50 ms
gateway  <--read----  mc.play_out (seq, conn_id, data)           frames ready to write to conn_id, in seq order; delete them once written
gateway  <--read----  mc.kick (conn_id, reason_nbt)              close these connections after flushing their play_out rows
login -> mc.login_check(uuid, name, ip)  then  mc.on_join(conn_id, uuid, name);   connection closed -> mc.on_leave(conn_id)
```
`mc.tick()` first claims the rows of `play_in` (`delete ... returning` into `play_in_work`) so a packet that arrives mid-tick waits for the next tick.
Compression is off: frames are `[length][id][body]`.  `mc.login_check` returns the vanilla translation key and arguments; `mc.disconnect_json` (login phase) and
`mc.disconnect_nbt` (play phase) format them.  Keys were read from `PlayerList.canPlayerLogin` in the bytecode; the whitelist key was seen live
(`multiplayer.disconnect.not_whitelisted`).

## Files

| File | Contents |
|---|---|
| `300_game_nbt.sql` | network NBT writers, text component builders (key order as vanilla writes it) |
| `310_game_packets.sql` | clientbound packet builders |
| `315_game_fast.sql` | inlinable replacements for hot helpers (see Performance) |
| `320_game_settings.sql` | `mc.server_property`, ops, whitelist, bans, `mc.login_check` |
| `330_game_players.sql` | `mc.player`, inventory, join/leave, visibility, queues |
| `340_game_input.sql` | movement, held slot, creative slot, keep-alive |
| `350_game_chat.sql` | chat types, commands and their feedback |
| `360_game_tick.sql` | chat intake, `mc.tick()`, `mc.tick_log` |

Tools: `tools/pkt_layout.py` (reads a packet class's wire layout from the jar with `javap`, never runs it), `tools/nbt_dump.py` (decodes recorded NBT),
`tools/game_probe.py` (scenarios: `social`, `kick`, plus the experiments `movetest`, `moveseq*`, `dist`), `tools/cap_view.py`.
To regenerate the recordings: start a vanilla 26.3 server (offline, whitelist off, `op` for a player named `Op`, compression off), then
`tools/game_probe.py social --port <port>` and `tools/game_probe.py kick`.  Recordings stay in `/tmp/game-scratch/cap` (override `DBCRAFT_CAPDIR`) and are not in git.

## Structurally right but NOT compared with the real server

* `teleport_entity` (used when one movement step exceeds 8 blocks; vanilla used `entity_position_sync`, whose path codec I did not decode).
* Command feedback keys other than the ones listed above: `/gamemode` on yourself, `/time set <ticks>` / `add`, `/difficulty` success, `/weather rain|thunder`, `/whitelist add|remove|on|off`, `/ban`, `/pardon`.  Weather game events are unverified.
* The clock total after `/time set`: the packet layout is byte-identical, but the value vanilla chose (`/time set day` at game time 5738 gave 49000, two days ahead) is not understood; ours is the next occurrence of the marker.
* Item stack limits (everything stacks to 64 here), the container state id rule (1 at join, +1 per server-sent update, fitted to one observation), the `block.` / `item.` choice for item names in `/give`.
* Item stacks with data components are stored with their raw bytes (`components = {"raw_hex": ...}`); they are not decoded.
* Defaults of `server.properties`: the key list is what the real server writes, the default values are documented defaults.
* Unknown-command context for multi-word input (one word recorded).

## Not implemented

Damage, death, respawn, `/kill`; `/seed`, `/msg`, `/me`, `/help` and most of vanilla's ~90 commands; target selectors (`@a`, `@p`); other operators' feedback broadcast; chat rate limits and
message signing (offline mode only); the `commands` packet (command tree sent at join: **not built**, a recorded 26-node level-0 and 2,399-node operator graph exist for a future
byte-exact attempt); entity metadata, attributes and the waypoint packets other players receive when someone joins (`set_entity_data`, `update_attributes`, `waypoint`); latency
broadcasts to the tab list; hunger, health and experience; ender chests and any container beyond the player inventory; `entity-broadcast-range-percentage`.
Visibility is a simplification: two players see each other when their chunk coordinates differ by at most `view-distance` (capped at 32) in both axes.

## Performance (single machine: 4 cores, one tick connection, PostgreSQL 16, `jit=off`, `fsync=off`)

`tests/bench/game/run.sh PLAYERS SIDE_CHUNKS MOVING_FRACTION [TICKS]` simulates players spread over a square and, every tick, feeds each moving player a
`move_player_pos_rot` plus every player a `client_tick_end`, calls `mc.tick()` and drains `mc.play_out`, each as its own transaction.  First 20 ticks dropped.

| Scenario | Viewers per player | tick avg | p95 | p99 | max | of which moves / visibility |
|---|---|---|---|---|---|---|
| 500 players, all moving, sparse | 19 | **40.4 ms** | 46 | 58 | 64 | 28.5 / 10.3 |
| 500 players, 20% moving, sparse | 19 | **24.4 ms** | 37 | 42 | 45 | 16.1 / 6.6 |
| 500 players, all moving, crowded (30x30 chunks) | 159 | 163.5 ms | 212 | 240 | 242 | 118.6 / 42.8 |
| 2,000 players, 20% moving, sparse | 21 | 70.7 ms | 91 | 102 | 105 | 44.7 / 22.8 |
| 2,000 players, all moving, sparse | 21 | 139.1 ms | 183 | 205 | 215 | 99.5 / 35.8 |
| 2,000 players, all moving, denser (100x100 chunks) | 78 | 306.1 ms | 374 | 383 | 385 | 213.8 / 87.5 |

Reading it: a 50 ms tick is met at 500 players (averages 24 to 40 ms; the all-moving case has p99 above 50 ms).  It is **not** met at 2,000 players, and crowding multiplies
the cost because the movement fan-out grows with viewers: that is `string_agg` building one `play_out` row per viewer.  Parallel ticking by region was not attempted, and
`docs/DATABASE-COMPARISON.md` found parallel write scaling disappointing on this machine, so it is unproven.  The load generator ran on the same 4 cores; load average stayed under 1.1 during these runs.

What made the difference (all measured; the first full run took 5.9 s per tick for 500 players):

| Change | Effect |
|---|---|
| Packet builders and codec helpers rewritten as single-expression SQL so they inline (`315_game_fast.sql`) | float decode 3,260 ms to 33 ms per 20,000 bodies; 20,000 move packets 10.8 s to 1.05 s |
| `MATERIALIZED` CTEs for the per-mover packet, so it is built once per mover, not once per viewer | 5.9 s to 0.57 s per tick |
| Frames assembled inline in the fan-out query instead of calling the builder functions (one function execution each, with a packet-id lookup) | moves 115 ms to 28 ms at 500 players |
| A slim, freshly `ANALYZE`d temp copy of the online players for the visibility join (the planner did not know how few were dirty) | wanted-pair step 91 ms to 3 ms |
| Build the periodic `set_time` packet once instead of once per player | 6.2 ms average to 0.07 ms |

## Lessons worth keeping

* A SQL function inlines only if its body is one expression (no `FROM` / `WITH`) and any argument it uses more than once is cheap.  A `FROM (select ...)` inside a helper costs a full executor start per call.
* `mc.prof(label)` (opt-in with `set mc.profile = 'on'`) prints the time since its previous call; `auto_explain` with `log_nested_statements` shows the plans inside PL/pgSQL.
* In Postgres `<<`, `>>`, `&` and `|` share one precedence level: parenthesise every shifted term.
* An uncorrelated scalar subquery in a select list is evaluated before the `FROM` side effects: run state-changing calls as separate statements in tests.
* Never let a malformed packet raise inside the tick (it would abort every player's tick): fixed-size packets are length-checked, variable ones use `proto.varint_safe` / `proto.string_safe`.

## Things to know when merging

* `315_game_fast.sql` redefines shared codec functions (`proto.varint`, `proto.frame`, `proto.f64_read`, `proto.f32_read`, `mc.pid`, `mc.sid`) with identical results; the 86 codec tests pass with them.  `proto.varint_slow` is the previous implementation.
* This module owns `mc.player`, `mc.inventory_slot`, `mc.visible`, `mc.play_in`, `mc.play_in_work`, `mc.play_out`, `mc.kick`, `mc.game_state` (clock, weather, spawn: replace with the world module's when it exists), `mc.server_property`, `mc.op`, `mc.whitelist`, `mc.ban`, `mc.command`, `mc.chat_type`, `mc.chat_log`, `mc.tick_log`.
* `mc.chat_type` ids must match the order of the `chat_type` registry the configuration phase sends (sorted by name; `chat` = 0 and `say_command` = 4 were confirmed).
* Tests run in database `dbcraft_game` (`DBCRAFT_TESTDB=dbcraft_game tests/sql/run.sh`).
