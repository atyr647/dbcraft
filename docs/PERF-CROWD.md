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
