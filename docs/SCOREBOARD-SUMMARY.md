# dbcraft against vanilla 26.3: one-page summary (final campaign, partial)

Tree `400f628` (all tracks merged), real vanilla 26.3 jar, Rust gateway, survival / tracker / dynamics / containers on, V D V D V D, load average at most 1.5 at every cell start, a new (faster) VM: compare ratios with
campaign 1 (`SCOREBOARD-SUMMARY-2026-11-04-campaign1.md`), not milliseconds.  **The campaign was stopped early: only idle 0 / 50 / 200 players, 50 walking players (3 repetitions) and 200 walking players (1 repetition) were re-run on the final tree;
every other row of [SCOREBOARD.md](SCOREBOARD.md) is explicitly marked "not re-run on the final tree" with campaign 1's value.**  TIE = the [min-max] ranges overlap.

| Category | Verdict against vanilla | Numbers re-run on the final tree (dbcraft against vanilla, medians) |
|---|---|---|
| **Capacity** | **dbcraft wins up to 200 walkers; 500 players unknown on this tree** | 50 walking: tick 15.8 against 30.1 ms, CPU 0.38 against 1.13 cores.  200 walking (1 repetition, locator bar off above 120 players): 21.1 against 45.8 ms, CPU 0.54 against 1.84; vanilla's chat p99 is 9.7 s, dbcraft's 35 ms.  500 players not re-run: campaign 1 had 446 ms crowded / 279 ms sparse with 70-240 clients dropped (loss); the capacity track's own document reports 778-884 ms crowded and 131-143 ms sparse with 0 dropped |
| **Latency** | **dbcraft wins or ties** (campaign 1: vanilla won at 50 players) | chat p50 / p99 at 50 idle 5.1 / 16 against 7.4 / 29 ms (TIE / dbcraft 1.7x); 50 walking 7.5 / 27 against 16 / 54 ms (TIE / dbcraft 2.0x); 200 idle 6.8 / 28 against 16 / 41 ms (TIE / dbcraft 1.5x); tick at 50 idle 3.1 against 24.7 ms |
| **Startup / join** | not re-run (campaign 1: dbcraft wins 3-6x, loses the 200-join storm tail) | |
| **Persistence** | not re-run (campaign 1: dbcraft wins; `fsync=off`, process kills only) | |
| **Disk** | not re-run (campaign 1: 14.9 against 62.1 MiB for 10,000 flat chunks) | |
| **Memory** | **dbcraft wins 7-14x** | 73 MiB empty, 188-203 MiB with 50-200 players against 1,009 MiB empty and 1.4-1.5 GB with players (vanilla `-Xms1G`); CPU 6.8x / 5.7x less at 50 / 200 idle players (0.094 against 0.64, 0.21 against 1.18 cores), idle 0 CPU a TIE (0.013 / 0.013) |
| **Features** | **vanilla wins by a wide margin** | see below |

## Remaining losses (the cells that were re-run have none; these are the known open ones, NOT re-measured here, with their source)

1. **500 players crowded**: campaign 1 446 ms against vanilla's 135 ms and 103-240 of 500 clients dropped; capacity track 778-884 ms, 0 dropped.
2. **500 players sparse, all moving**: campaign 1 279 ms, 70-141 dropped; capacity track 131-143 ms (target 100 not met); vanilla never measured at 500 sparse.
3. **Locator-bar cliff**: the bar is half a walking tick at 50-120 players and is switched off above 120 (`dbcraft.locator-bar-max-players`), so the 200-walker result above benefits from it being off.
4. **A viewer with mobs just outside his view**: 1.25x vanilla at 2,000 / 5,000 cows (PERF-MOBS2, own session); campaign 1 had 3.8-6.6x before the lazy lanes; `dbcraft.entity-mode` is `off` as shipped.
5. **200-join login storm and edits with a viewer** (campaign 1: worst tick 948 against 545 ms; 1,000-block fill tick cost 80 against 19 ms); the storm round 2 and dynamics fixes target these, not measured here.

## Capability: what vanilla has that dbcraft does not

Flat world (optional noise terrain: no caves, ores, trees, structures), **no light engine**, **no mob AI or pathfinding** (mobs prototype, off by default), **no redstone**, no leaf decay, tree growth or shape updates, no item drops from broken blocks, no armor, potions, fire, drowning, beds, sounds,
about 70 of 90 commands "not implemented", advancements and recipes replayed from a capture, no chat signing, **offline mode for real clients only**.  It has the survival core for players, vanilla's player tracker, chests / barrels / furnaces / crafting, fluids, falling blocks and random ticks, and the whole server as rows.
Several wins above (memory, CPU, idle tick) come from not doing the work in the first list.
