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
| `tests/e2e/compare_commands.py` | A six-player command session (about 390 steps, operators of every level) recorded on the real server and replayed against dbcraft over TCP; see [Commands](#commands) | **2,316 of 2,316 player/step pairs identical** (1,665 packets) |
| `tests/sql/810`, `811`, `812` | the generated command tree against recordings for levels 0 to 4, the parser against what the real server said, the commands | **213 checks pass** (17 + 86 + 110) |

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

## Commands

`sql/810`-`815` (and `tools/load_command_tree.py`).  Vanilla has one command graph (Brigadier): the client gets it at join so it can complete and colour what is typed, and the
server parses what the client sends against the same graph.  Here that graph is **rows** and both uses read them, so the packet and the dispatcher cannot disagree.

| Piece | What it is |
|---|---|
| `mc.cmd_node`, `mc.cmd_child` (sql/810) | one row per node (kind, name, executable, restricted, redirect, argument parser id and properties, suggestion provider, `min_level`), the edges in vanilla's registration order.  2,399 nodes, 92 commands.  Loaded by `tools/load_command_tree.py` from the recording of a level-4 operator joining a vanilla server (`play_op4`, made by `tools/bootstrap.sh`; Mojang data, never committed); `min_level` of each node comes from the generator's `commands.json` (matched by path) and the loader checks the two sources against each other |
| the `commands` packet (sql/810) | `mc.cmd_tree_body(level)`: breadth-first numbering of the nodes visible at the level (children in order, then the redirect), cached per level in `mc.cmd_tree_cache`.  Sent at join for the player's level (`net.commands_body`, entry packet 70) and again after `/op` / `/deop` together with `entity_event 24 + level`, in the order vanilla sends them |
| the parser (sql/811) | `mc.cmd_parse(level, text)` is `CommandDispatcher.parseNodes` and `execute` (read from the library's bytecode): literal or argument children, backtracking over alternatives, the sort of candidate parses, which exception is reported and its cursor.  Argument parsers: bool, integer, float, double, string (word, phrase, greedy), gamemode, entity and game profile (names, UUIDs, `@a @e @p @r @s @n` with the options `name distance limit sort gamemode type level x y z dx dy dz tag team`), message (selectors inside), item stack and predicate (id only), vec3 (`~`, `^`, integer x z centred), rotation, time (`d s t`), resource location, datapack resource |
| the dispatcher (sql/813) | `mc.cmd_execute`: a command that is not in the player's graph is unknown (exactly what vanilla says), a syntax error is reported with vanilla's text plus the context line (up to ten characters before the cursor, the rest underlined, `<--[HERE]`), then `mc.cmd_run_<command>(player, level, text, signature, arguments)`.  Aliases (`/tp`, `/tell`, `/w`, `/xp`, `/tm`) are redirects in the graph.  A command of the graph without an implementation says so in red; it is never silently ignored |
| feedback (sql/812) | `mc.cmd_success`: the executor gets the message; every other operator gets it as `chat.type.admin` (gray, italic); both only while the game rule `send_command_feedback` is on |
| selectors (sql/812) | `mc.sel_players`: players only (mobs and items of the entity prototype are not selectable), `@e` is every player and a type other than `minecraft:player` selects nobody, nearest / furthest / random sorts, limits, the box of `dx dy dz` against a standing player |

Implemented commands (the first column is what a level-0 player may use, the rest needs the level vanilla needs): `/list [uuids]` `/me` `/msg /tell /w` `/help [command]` (usage
text derived from the graph with Brigadier's smart-usage algorithm); `/say` `/seed` `/gamerule` (all 58 rules, stored in `mc.game_rule`, defaults in `mc.gamerule_default`)
`/clear` `/give` `/gamemode` `/teleport /tp` `/time set add query` `/weather` `/difficulty` `/kill` (levels 2 and up); `/op` `/deop` `/whitelist` `/ban` `/pardon` (3 and up).

**Verified byte for byte against the real server**

* the `commands` packet for permission levels 0, 1, 2, 3 and 4 (`tests/sql/810`; level 0 against a recording from a different server run than the one the graph was loaded from);
* a recorded session of 392 steps with six players (operators Op1 to Op4 of levels 1 to 4, Bob and Cy plain), run on the real server and on dbcraft (`tests/e2e/record_commands.sh`,
  `compare_commands.py`): **2,316 of 2,316 player/step pairs identical, 1,665 packets**.  Compared: every `system_chat` and `disguised_chat`, the `commands` packet, `player_abilities`,
  the game-mode `game_event`, the permission-level `entity_event` and every `container_set_slot`.  The steps cover every implemented command with its failures, 132
  steps that use selectors (forms and errors), every permission level's `/help`, all 58 game rules' defaults, `/op` and `/deop` with the tree swap, the operator broadcast and
  `send_command_feedback`, `/give` stacking, `/clear`, `/tp` in all its forms (absolute, `~`, `^`, rotation, destination, several targets), `/ban` with the kick;
* what the session needed to learn (all now in the code): a `/gamemode` that changes nothing is silent; `/tp` `~` is relative to the executor and sends the offsets with relative flags
  (and, for a relative y, an absolute packet with the next teleport id); `/give` adds stack by stack with a slot update after each; `/clear` counts "from N players" for the players
  that lost something and sends nothing to a target in `maxCount 0` mode; `time set N` answers an int and `time add N` a long; `/ban` kicks with `multiplayer.disconnect.banned`
  without the reason; a message argument in the mouth of a level-0 player is plain text.

**What the comparison masks or cannot see (honestly)**

* vanilla orders the children of `/gamerule` by hash, differently on every run, so the node numbering of the `commands` packet and the order of `/help`'s `/gamerule (...)` line
  differ between two runs of the real server.  Both are compared after sorting the children of `/gamerule` (`tests/e2e/cmdtree.py`); everything else is in registration order.
  The byte-exact comparison of the tree (levels 0 to 4) is with recordings of the same run the graph came from, plus level 0 across runs;
* clock totals in `/time add`, `/time query time` and `/time query gametime` are run-specific: only the shape of the answer is compared (`time set` totals are compared exactly);
* the death steps (`/kill` of a player, `perform_respawn`) belong to the survival module and are compared only with `--survival`; `/kill` itself selects the victims, answers
  `commands.kill.success.*` and calls `mc.kill_players(uuid[])` when that function exists (without it the command says so and kills nobody);
* only the packet kinds above are compared: vanilla also sends entity metadata, sounds, item entities (`/give`), set_equipment, recipe book and advancements around these commands,
  which dbcraft does not (see Not implemented).

**Not supported (said in the error text, not hidden):** item components and NBT in item arguments (`stone[...]`), the selector options `advancements nbt predicate scores x_rotation
y_rotation`, `/tp ... facing`, `/time` forms other than `set`, `add`, `query time|gametime`, every other command of the graph (they answer "is not implemented").
Differences that are not errors: `weather rain|thunder` accepts a duration and ignores it (no weather timer); `op`, `deop`, `whitelist`, `ban` and `pardon` only know players the
server has seen (vanilla in offline mode accepts any name and shows it in lower case: `argument.player.unknown` here); game rules are stored and reported but only
`reduced_debug_info` (entity event 22/23) acts on clients here; the survival module reads them from `mc.game_rule`.

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
| `810_cmd_tree.sql` | the command graph as rows and the generated `commands` packet |
| `811_cmd_parse.sql` | the Brigadier-style parser, selector parser, argument types |
| `812_cmd_support.sql` | selector resolution, feedback and operator broadcast, error reports, game rules, message components |
| `813_cmd_dispatch.sql` | `mc.cmd_execute`, `/list /time /weather /difficulty /gamemode /tp /give /op /deop /whitelist /ban /pardon` |
| `814_cmd_chat.sql` | `/say /me /msg /seed /help /gamerule /clear` |
| `815_cmd_kill.sql` | `/kill` (selection and feedback; the death is the survival module's) |

Tools: `tools/pkt_layout.py` (reads a packet class's wire layout from the jar with `javap`, never runs it), `tools/nbt_dump.py` (decodes recorded NBT),
`tools/load_command_tree.py` (loads `mc.cmd_node` from a recording), `tools/game_probe.py` (scenarios: `social`, `kick`, plus the experiments `movetest`, `moveseq*`, `dist`), `tools/cap_view.py`.
To regenerate the recordings: start a vanilla 26.3 server (offline, whitelist off, `op` for a player named `Op`, compression off), then
`tools/game_probe.py social --port <port>` and `tools/game_probe.py kick`.  Recordings stay in `/tmp/game-scratch/cap` (override `DBCRAFT_CAPDIR`) and are not in git.

## Structurally right but NOT compared with the real server

* `teleport_entity` (used when one movement step exceeds 8 blocks; vanilla used `entity_position_sync`, whose path codec I did not decode).
* Command feedback not in the recorded session: `weather rain|thunder` (the game events; the feedback key is verified), the `/whitelist` and `/ban` of players the server has not seen.  Everything else is in the
  command session above.
* The clock total after `/time set`: the packet layout is byte-identical, but the value vanilla chose (`/time set day` at game time 5738 gave 49000, two days ahead) is not understood; ours is the next occurrence of the marker.
* Item stack limits (everything stacks to 64 here), the container state id rule (1 at join, +1 per server-sent update, fitted to one observation), the `block.` / `item.` choice for item names in `/give`.
* Item stacks with data components are stored with their raw bytes (`components = {"raw_hex": ...}`); they are not decoded.
* Defaults of `server.properties`: the key list is what the real server writes, the default values are documented defaults.

## Not implemented

Damage, death and respawn (the survival module; `/kill` calls it); the other ~70 commands of vanilla's graph (they are in the player's command tree, so clients complete them, and answer
"not implemented"); chat rate limits and message signing (offline mode only); entity metadata, attributes and the waypoint packets other players receive when someone joins
(`set_entity_data`, `update_attributes`, `waypoint`); item pickup, sound and equipment packets around `/give` and `/clear`; latency broadcasts to the tab list; hunger, health and experience;
ender chests and any container beyond the player inventory; `entity-broadcast-range-percentage`.  Recipes, advancements and the player's own entity data are still replayed from a capture
(`net.static_packet`); the command tree is no longer one of them.
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
