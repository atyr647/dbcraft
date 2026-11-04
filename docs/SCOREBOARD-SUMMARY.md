# dbcraft against vanilla 26.3: one-page summary

From one campaign on one tree on a quiet 4-vCPU machine (2026-11-04, commit `f205b34`, real vanilla 26.3 jar, Rust gateway, survival core / vanilla tracker / dynamics / containers on,
3 alternating repetitions per cell, load average at most 1.5 at every cell start).  Details, method and every row: [SCOREBOARD.md](SCOREBOARD.md), [SCOREBOARD-table.md](SCOREBOARD-table.md).
A TIE means the [min-max] ranges of the repetitions overlap.

| Category | Verdict against vanilla | Numbers (dbcraft against vanilla, medians) |
|---|---|---|
| **Capacity** | **Mixed; the hard ceiling is one core.**  Cheaper in CPU, loses the moving-player ceiling and cannot admit 500 | CPU 0.36 / 0.56 against 1.10 / 1.47 cores at 50 / 200 idle players, but 1.0 core flat from 50 walking players up.  200 walking: tick 99 against 82 ms (vanilla 1.2 times better; both over 50 ms), p99 225 against 799 ms (dbcraft better).  200 players with 20% walking: 40 against 98 ms (dbcraft 2.4 times better).  500 players: dbcraft 279 ms sparse all moving, 446 ms crowded, **103-240 of 500 clients dropped**; vanilla crowded 135 ms mean, p99 2.1 s, nobody dropped |
| **Latency** | **vanilla better at 50 players, dbcraft better under overload** | chat p50 / p99 at 50 idle 58 / 89 against 31 / 60 ms; 50 walking 88 / 208 against 51 / 121 ms; 200 idle 15 / 70 against 43 / 89 ms (dbcraft wins p50, TIE p99); 200 walking 185 / 307 against 10,000 (no reply) ms; 20% walking p99 153 against 943 ms.  The 100 ms tick every 4th tick (random ticks) is the cause at low load |
| **Startup / join** | **dbcraft wins, except the storm tail** | one joiner 0.69 against 4.16 s (unexplored), 0.53 against 1.55 s (explored); 50-join storm all in with all chunks 8.0 against 44.4 s, 200 joins 39.9 against 51.8 s.  But worst tick in a 200-join storm 948 against 545 ms, online players' chat p50 146 against 28 ms (50 joins) |
| **Persistence** | **dbcraft wins** (process crash; `fsync=off`) | 10,000 chunks generated in 2.1 against 26 s; save stall 0.07 against 6.0 s; `kill -9` to accepting logins 2.3 against 14.8 s; **an edit 1 s old survives (3 of 3) against lost (0 of 3)** |
| **Disk** | **dbcraft wins** | 14.9 against 62.1 MiB for 10,000 flat chunks (4.2 times smaller; the terrain case is closer to 1.8 times larger than vanilla's chunks alone, from the earlier disk work, not re-measured here) |
| **Memory** | **dbcraft wins** | PSS 118 MiB empty, 209-229 MiB with 50-500 players against 995 MiB empty (partly vanilla's 1 GB initial heap), 1.4-1.8 GB with players: 7-8 times less |
| **Features** | **vanilla wins by a wide margin** | see below |

## Top 5 remaining losses

1. **Moving-player capacity and 500-player admission.**  200 walking players: 98.7 ms mean tick (twice the budget), one core saturated (1.01 cores).  500 players: 279 ms (sparse, all moving), 446 ms (crowded) with 70-240 of 500 clients dropped by the gateway's 30 s read timeout; even the 20%-moving sparse case is 58 ms mean / 116 ms p99 with 82-132 dropped.
2. **Chat latency and tick spikes at 50 players (random ticks, dynamics on, simulation distance 10).**  Chat p50 58 against 31 ms (50 idle), 88 against 51 ms (50 walking); every 4th tick takes about 100 ms.  With dynamics off the 50-idle tick is 5.7 instead of 15.4 ms and chat p50 14 ms.
3. **Login-storm tail.**  200 joins into 20 players: worst tick 948 against 545 ms, tick p99 265 against 120 ms, online chat p50 216 against 182 ms; 50 joins: online chat p50 146 against 28 ms (5.3 times).
4. **Mobs nobody can see, and no mobs by default.**  500 / 2,000 / 5,000 awake cows out of view cost 15.5 / 33.9 / 76 ms of CPU against vanilla's 4.1 / 6.0 / 11.5 ms (3.8 / 5.7 / 6.6 times); `dbcraft.entity-mode` is `off` as shipped.  (In view dbcraft wins 1.2-2.1 times; 5,000 resting items 52 times.)
5. **Edits with a player watching.**  A 1,000-block fill costs the tick 80 ms against vanilla's 19 ms (4.1 times; the dynamics engine processes the fill: 4.7 ms with dynamics off); a 100,000-block fill 297 against 352 ms (TIE); a single `set_block` statement 3.9 against 2.7 ms (1.5 times).

## Capability: what vanilla has that dbcraft does not

dbcraft is a **flat-world** server (an optional seeded noise terrain exists: no caves, ores, trees, structures, vanilla seeds) with **no light engine** (straight-down sky light only), **no mob AI or pathfinding** (mobs are a prototype, `entity-mode` off by default),
**no redstone**, no leaf decay, tree growth or shape updates (fences do not connect), no item drops from broken blocks, no armor, potions, fire, drowning, beds or respawn anchors, no sounds, about 70 of vanilla's 90 commands answer "not implemented", advancements and recipes are replayed from a capture,
no chat signing, **offline mode for real clients only** (online mode is tested with a stub, not a real account), no vanilla world import beyond a subset.  It does have: a survival core for players, vanilla's player tracker, the container protocol for chests / barrels / furnaces / crafting, fluids, falling blocks and random ticks,
a 100,000-block fill in 70 ms, and the whole server as rows you can `UPDATE`.  Several wins above (memory, CPU, join time, tick at idle) come from not doing the work in the first list; the persistence, disk and fill wins are design wins that hold for the work dbcraft does.

**Not run:** 2,000 players; 500 players with vanilla in the sparse cells; a power-cut test (`fsync=off` dev cluster); real clients and online mode.  The load generator shares the four cores, which hurts both servers and the 500-player rows most.
