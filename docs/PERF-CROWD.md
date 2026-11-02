# Crowded worlds: what vanilla does, what dbcraft did, what changed

Question: the Rust gateway load test (docs/GATEWAY.md) showed the database is the bottleneck when players crowd together: 500 clients at one point (everybody sees
everybody) gave a 63 ms average tick with 296 late ticks, 2,000 clients collapsed.  A busy spawn lobby is a real scenario.  This document is the work on it.

Machine: 4 CPUs, shared with other workers during every measurement (load average 2.7 to 4.6 while measuring).  Timings are on-CPU time of the tick backend
(`/proc/self/schedstat`) unless stated, which inflates far less than wall time under load; they still carry noise of roughly 10 to 25%.  Ratios of 2x and more are
not noise; differences under about 1.3x are.  `tests/bench/crowd/` has every script.

## 1. Vanilla's rules, read from the 26.3 bytecode (`javap`, never from memory)

`net.minecraft.server.level.ServerEntity.sendChanges()` runs for every tracked entity every server tick.  Its body does the work only when
`entity.needsSync || updateInterval.test(tickCount) || entityData.isDirty()`; `tickCount` is incremented at the end of every call and counts from the creation of the
`ServerEntity` (so the phase differs per entity).

* `EntityType.PLAYER` is registered with `clientTrackingRange(32)`, **`updateInterval(2)`** and `dontTrackDeltas()` (read in `EntityTypes.<clinit>`).
* `UpdateInterval.periodic(p)`: `test(t) = (t % p == 0)`, `nextInterval(t) = (t / p) * p + p`.  `UpdateInterval.NEVER` tests false.
* Inside the body: rotation is packed to one byte (`Mth.packDegrees`) and counts as changed when it differs by at least 1; a position packet is sent when the squared
  length of the delta since the last sent position is at least `7.62939453125E-6` (`TOLERANCE_LEVEL_POSITION`) **or `tickCount % 60 == 0`**
  (`FORCED_POS_UPDATE_PERIOD = 60`); a teleport instead of a relative move when the delta does not fit 16 bits or `teleportDelay++ > 400` (`FORCED_TELEPORT_PERIOD`);
  the head rotation packet (`ClientboundRotateHeadPacket`) goes out in the same gated block, when the head angle byte differs by at least 1; entity data when dirty.
* Players use `dontTrackDeltas()`: no velocity packets (`ClientboundSetEntityMotionPacket`) except when `syncVelocity` is set (knockback and similar).

So **a walking player's position reaches the viewers at most every second tick: 10 packets per second, each carrying `ticks = 2` and the movement of both ticks.**

## 2. What the real traffic shows (tests/bench/crowd/rates.py)

One observer stands still, one walker sends `client_tick_end` + `move_player_pos` every 50 ms moving 0.215 blocks per tick (4.3 blocks/s).  Packets that name the
walker's entity are counted at the observer, 4 s:

| server | move packets | per second | bytes each | the packet |
|---|---|---|---|---|
| real vanilla 26.3 | 41 | **10.25** | 11 | `move_entity_pos`, `ticks = 2`, delta 1761/1762 (two ticks of 0.215 blocks, in 1/4096 block units) |
| dbcraft before | 76 | **19.0** | 11 | `move_entity_pos`, `ticks = 1`, delta 881 (one tick) |
| dbcraft after (`dbcraft.player-update-interval` = 2) | 41 | **10.25** | 11 | `move_entity_pos`, `ticks = 2`, delta 1761/1762: the same bytes as vanilla's apart from the entity id |

dbcraft sent **twice as many movement packets as vanilla** for every moving player.  That is a fidelity bug and, in a crowd where the fan-out costs N x (N-1)
deliveries, a direct 2x on the whole cost.  Fixed in `sql/431`, `sql/434`, `sql/382` (the three places that decide when a movement packet goes out) with the setting
`dbcraft.player-update-interval` (default 2 = vanilla; 1 restores the old behaviour); the phase is per entity, `(tick + entity id) % interval = 0` (vanilla's phase
is the age of the entity's `ServerEntity`, which is just as scattered).  Without a per-entity phase every player in a synthetic crowd that starts together would fire
on the same ticks (measured: p50 157 ms, p99 508 ms, alternating heavy and empty ticks).

## 3. Levers, in the order measured (500 players in 3x3 chunks, everyone sees everyone: 249,500 visible pairs)

| lever | what | effect |
|---|---|---|
| (a) vanilla update interval | players broadcast position every 2nd tick (`EntityType.PLAYER.updateInterval = 2`), per-entity phase `(tick + eid) % 2`; `ticks` field = interval (was game ticks since the last send: 6317 on the first packet). Setting `dbcraft.player-update-interval` (sql/466), 1 = old behaviour | packets/s per walker 19 -> 10.25 (vanilla recording) |
| (b) per-chunk fan-out | `mc.fanout_moves` (sql/430): one blob per viewer chunk cell with the movers in range, the viewer's own packet cut out; byte-identical to the per-viewer path (tests/sql/467, 30 random states) | 2,000-player fan-out 3,375 -> ~150 ms |
| (c) `play_out.data` EXTERNAL | no pglz on blobs that are deflated later anyway (sql/467) | removes compression from the tick |
| (d) visibility: changed pairs only | `mc.refresh_visibility` (sql/468) uses the chunk before the move (`vis_ocx/vis_ocz`); exact fallback (`refresh_visibility_full`, the sql/465 code) whenever any dirty player has an unknown old chunk (join, /tp). tests/sql/469 compares both on random states | 28 crossers in a 2,000 crowd: 739 + 870 ms -> fast path |

500 crowded, all walking: 344 ms -> 47.4 ms CPU/tick (p99 62). Phases: moves 16.9, visibility 13.2, chunks 6.4, drain 8.1.

## 4. Results vs targets (`tests/bench/crowd/run.sh`, quiet single core, this machine)

| scenario | CPU ms/tick avg (p99) | target |
|---|---|---|
| 500 crowded, 20% moving | 22.8 (40.2) | <= 25 met |
| 500 crowded, 100% moving | 47.4 (62.3) | <= 50 met on average, p99 over |
| 500 crowded, 100% moving, `mc.server_tick_batched` | 110.7 (170) | batched loses here: its visibility is `visibility_batched_grid`, no changed-pairs path |
| 2,000 crowded, 20% moving | 321 (408) | all clients are in, tick not at 50 ms |
| 2,000 crowded, 100% moving | run did not finish a sample | 27.6 MB/tick (4.4 Gbit/s at 20 Hz): not a realistic load for any server |

Not met: 2,000 crowded stays about 6x over 50 ms at 20% moving. Output volume is quadratic (each of 2,000 players sees 1,999 others): 9.5 MB/tick even at 20%.
Vanilla comparison at this scale was not possible (Python clients); see the scoreboard worker's numbers.

## 5. What failed / lessons
- Gating on `cur_tick - last_sent_tick >= interval` made all players send in the same tick (bimodal 157/508 ms): the phase has to be per entity.
- The interval changed pinned test expectations (33, 36, 431): re-pinned to the recorded vanilla value (2 ticks), 33 pins the setting to 1.
- Visibility caching assumes `mc.visible` is consistent with the rule; the batch-diff generator used to drop 10% of pairs at random, which the full refresh healed and the fast one cannot. Generator now starts consistent. A runtime `view-distance` change is not handled by the fast path (mark everyone dirty with NULL old chunk, which forces the exact path).

## 6. What remains
Moves 17 ms and drain 8 ms at 500 are bytes-bound; per-tick budget cap (lever j, default off) not built; batched tick needs a changed-pairs visibility to compete; 2,000 needs fewer visible pairs than the view-distance rule gives (vanilla's tracker range for players is smaller than the chunk view distance, to check against section 1).

## 7. Merge notes
Edited: sql/431, 434, 382, 461, OVERRIDES.txt, tests 33/36/431/_batch_diff_helpers. New: sql/430, 466, 467, 468; tests 467, 468, 469; tests/bench/crowd. tests/e2e was not run. Suite 1,681 checks green; check_overrides and check_inlining green.
