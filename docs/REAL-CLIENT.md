# The real Minecraft client against dbcraft

Until now only scripted clients (which answer like a real one) had connected.  This document records what happens with the **real vanilla 26.3 Java client**
(the official client jar, libraries and assets from Mojang's launcher metadata, every SHA-1 verified), running under a virtual display with software rendering.

**Result in one paragraph.**  The real client joins dbcraft, loads the flat world, walks, breaks and places blocks, chats, runs commands, and stayed connected
for a 10-minute soak plus a 4-minute soak that crossed chunk borders, with no disconnect, no protocol error, and a client log whose warnings and errors are
identical to a session against the real vanilla server.  Two clients see each other.  The real client found **two bugs** that the 1,000+ scripted checks and the
byte-for-byte replays had not (both fixed, with regression tests): `/tp Name` did not exist, and a teleported player stayed **invisible** to a viewer that
became able to see it in the same tick.

Everything below was done on a 4-core machine shared with other workers (load average from about 1 up to 10 while the full test suite ran next to two clients), software rendering (llvmpipe), an 854x480 window, render distance 2,
14 to 20 frames per second.  Timings are therefore indicative only.

## Setup (all scripted; nothing from Mojang is committed)

| Step | Command |
|---|---|
| download client + libraries + assets (610 MB, 5,215 files, SHA-1 checked) | `python3 -I tools/realclient/download_client.py 26.3 /tmp/mc-client` |
| Java 25 and display tools | `apt-get install openjdk-25-jre-headless xvfb xdotool x11-utils imagemagick mesa-utils libgl1-mesa-dri libglx-mesa0 libegl1 libegl-mesa0 libgbm1 libopengl0` |
| the reference: a real vanilla server (offline, flat, view distance 2) | `tools/realclient/vanilla_server.sh start` (port 25613) |
| a dbcraft server on ports of its own | `DBCRAFT_PGDATA=/tmp/dbcraft-pg-client DBCRAFT_PGPORT=54477 tools/realclient/dbcraft_server.sh setup`, then `... start` (gateway on 25633) |
| a client | `tools/realclient/run_client.sh start NAME HOST:PORT` (second client: `DISPLAY_NUM=98 ...`) |
| screenshot, input | `tools/realclient/run_client.sh shot NAME [FILE]`, `tools/realclient/drive.sh key|hold|click|look|chat ...` |
| soak | `[LAP_SECONDS=12] tools/realclient/soak.sh MINUTES NAME` |
| compare the client logs | `python3 -I tools/realclient/logdiff.py DBCRAFT_LOG VANILLA_LOG` |

Things that were not obvious (all handled in the scripts):

* The client's default OpenGL window creation fails under Xvfb (`Failed to create window for OpenGL context: Couldn't find matching GLX visual`).  Forcing SDL to
  EGL fixes it: `SDL_VIDEO_FORCE_EGL=1 SDL_VIDEODRIVER=x11` with `LIBGL_ALWAYS_SOFTWARE=1` (Mesa 25.2, OpenGL 4.5 core).
* 26.3's minimum simulation distance is 5 on the client (`options.txt` value 2 is rejected); the server still runs at 2.
* Without a sound device the client logs `Failed to open OpenAL device` and carries on.  With a fake access token it logs a 401 from Mojang's account service
  and carries on.  Both appear identically against vanilla.
* Under Xvfb the pointer is not grabbed: one large relative mouse move is ignored (the pointer stops at the screen edge) and absolute warps do not turn the
  camera.  `drive.sh look` therefore re-centres the pointer and moves in steps of 8 pixels (0.15 degree per pixel).
* Two clients need two virtual displays (`DISPLAY_NUM`), otherwise their windows overlap.

## Results

Screenshots are under `/tmp/mc-client/shots/` (not committed: they show Mojang's textures).

| # | Check | Result |
|---|---|---|
| 1 | The real client reaches the joined state against **vanilla** | yes (server log `Probe logged in`, screenshot `vanilla-join.png`: grass to the horizon, hotbar, hand) |
| 2 | The same against **dbcraft**: terrain loads, world visible, no disconnect | yes (`dbcraft-join1.png`).  F3 reads `Minecraft 26.3 (26.3/vanilla)`, server brand `dbcraft`, `XYZ: 0.500 / -60.00000 / 0.500`, `Chunk: 0 -4 0`, the same as the `mc.player` row (`dbcraft-f3.png`) |
| 2b | Client log: warnings and errors against vanilla and dbcraft | **identical**: 4 messages in common (Mojang account 401, Realms feature flags, OpenAL, a post-effect warning), none only in dbcraft, none only in vanilla (`logdiff.py`).  No `Exception`/`Disconnect`/`Failed to decode`/`Network Protocol Error`/`Invalid` beyond that baseline of 7 matching lines, which never grew |
| 3 | Walking, jumping, turning | yes.  Holding W for 2 s moved the row z 0.50 to 9.13 (4.3 blocks/s, walking speed); mouse motion changed `yaw` in the row (240 px = 36.0 degrees) and `pitch`; F3 and the row agree to the displayed precision |
| 4 | Break and place | yes.  Left click on the grass at (0,-61,16): `mc.get_block` = `air`, neighbours untouched, the client shows the hole with dirt below (`dbcraft-broke.png`).  After `/give`, right click: `minecraft:stone` at the same place, the stack stays at 64 (creative) |
| 5 | Chat and commands | yes.  `<Probe> hello from the real client` is displayed and in `mc.chat_log`.  `/give` as a non-operator answers `Unknown or incomplete command` (what vanilla does: the command is absent from a non-op's tree); after making the player an operator: `Gave 64 [Stone] to Probe`, the hotbar shows the stack.  `/time set day` answers `Set minecraft:overworld to time marker minecraft:day`; `/foobar baz` the red `Unknown or incomplete command. See below for error / foobar<--[HERE]`; `/gamemode survival` answers `Set own game mode to Survival Mode` and the client switches to the survival HUD (hearts, hunger, experience) (`cmd-feedback.png`) |
| 6 | Soak | **phase 1**: 626 s connected, 3-second laps (inside one chunk).  **phase 2**: 268 s, laps of about 50 blocks that crossed three chunk borders each way (`LAP_SECONDS=12`).  **manual walk** across more borders with the chunk-border overlay: new chunks are present as the player arrives (`border-walk-b.png`, F3 chunk -2 -4 4 = row (-2, 4)).  Over all of it: no disconnect, client error count unchanged, `mc.error_log` empty.  Gateway: 42,211 ticks, 1,146 late (2.7%), worst tick 184 ms, while the machine ran the full test suite and other workers, so these figures say little about an idle machine (phase 1 alone: 223 of 12,506, 1.8%; phase 2: 37 of 5,342, 0.7%) |
| 7 | Two real clients | yes, after fix 2 below.  `Probe2` renders `Probe` (player model, name tag) and the reverse (`fixed-probe-sees-probe2.png`, with the hitbox).  A rejoin restores the saved position |

Also verified with a real client: `teleport_entity` (its layout was "not verified" in docs/GAME.md): `/tp Probe2 ~ ~ ~10` made Probe2 appear 10 blocks farther away
in Probe's view (`rejoin-compare.png`), so the packet is accepted and applied.

## Bugs found by the real client (fixed)

### 1. `/tp <destination>` and `/tp <targets> <destination>` did not exist
`/tp Probe` answered "No player was found".  The command only knew `tp <player> <x> <y> <z>`.  Vanilla's forms are `tp <destination>`,
`tp <targets> <destination>`, `tp <x> <y> <z>` and `tp <targets> <x> <y> <z>`.  Fixed in `sql/350_game_chat.sql` (in place, because the branch is inside the
large `mc.run_command` dispatcher and a wrapper-by-rename is not safe when tests re-include files): destination forms take the target to the destination's
position and rotation, answer `commands.teleport.success.entity.single`, and send an absolute `player_position` (flags 0).  The command's usage text in `mc.command` was updated.
Not covered: target selectors (`@s`, `@a`), rotation and facing arguments.

### 2. A teleported player stayed invisible to a viewer that could see it again in the same tick
After `/tp`, a player that became visible to a viewer in the same tick was added with `add_entity` at the **old** position (the shared "last told" position),
for example 70 blocks away in a chunk the viewer had not loaded; the correcting `teleport_entity` followed a tick later.  The real client keeps an entity that was
added in an unloaded chunk out of its tracked set (it is neither ticked nor rendered), so it never applies the later teleport: **no model, no hitbox, no error**.
The scripted clients and the byte-exact replays could not see this, because they do not simulate the client's world.
Vanilla adds a newly tracked entity at its current position.  Fix: `mc.sync_entity_position(uuid)` (in `sql/350_game_chat.sql`), called by both `/tp` branches, for jumps that vanilla's entity tracker sends as a
teleport (a delta that does not fit in a short: more than 8 blocks, the movement step's own test): the viewers that already see the player get `teleport_entity` +
`rotate_head` at once, and the shared position is made current before the visibility step of the same tick.  **A shorter `/tp` is left exactly as it was** (a relative
move from the next movement step, which `tests/sql/36_game_tick.sql` pins and vanilla does the same): my first version synced every `/tp` and that test caught it.
The stale base of a short teleport is at most 8 blocks from the real position, which a new viewer's loaded area contains; that is an assumption, not something I
reproduced or tested with a real client.
Regression test: `tests/sql/490_client_tp.sql` (29 checks; with the helper neutralised it fails at "the shared last-told position is current at once").  Verified with
two real clients on the scenario that failed (`/tp Probe2 0 -60 0`, then `/tp Probe`), using the first (all-`/tp`) version of the helper; the final version is identical
for that 70-block jump but I did not repeat the real-client run after narrowing it (the machine was saturated); the SQL tests cover the narrowed version.
Other code that moves players by something other than a movement packet should call the same function (nothing else does today: join sets the base itself).

## Things seen that are not bugs, or not fixed

* `create temp table if not exists ...` inside the tick prints one `NOTICE` per call: about 850 per 40,000 ticks per table in the gateway log (`/tmp/mc-client/gateway.log`).
  Harmless, but it is also the relation churn the tuning worker measured; a `SET client_min_messages = warning` in the gateway session would silence it.
* The `/time set` clock total can differ from vanilla's (known, docs/GAME.md); the client displays the right time of day.
* The client's own window gets a `Requested post effect does not exist: minecraft:end_of_frame` warning in both vanilla and dbcraft sessions.

## What was not tested

* Online mode (real Mojang accounts, encryption): the dev gateway is offline-only.
* Compression on the wire with a real client (threshold -1 throughout).
* More than two clients, a larger view distance, hardware rendering, sound, skins (offline players get the default skin), resource packs.
* Soaks longer than about 15 minutes; behaviour after a database crash.
* Anything needing a real keyboard layout or mouse grab: input was synthetic (XTEST), so inventory screens and drag-and-drop were not exercised.
* Survival mechanics (damage, hunger, death) are not implemented in dbcraft, so the survival HUD is displayed but nothing happens to the numbers.

## My own mistakes during this work (so they are not repeated)

* A first soak script sampled on a lap counter instead of a schedule, so it logged once; and its laps returned to the start, so a single sample looked like "no
  movement".  Fixed (`soak.sh`).  The first soak did not cross chunk borders at all (the lap stayed inside one chunk); the second phase does.
* `pkill -f <pattern>` killed the shell that contained the pattern; the scripts stop clients through pid files.
* A test glob (`run.sh 386`) matched nothing and printed nothing; use a name fragment.
