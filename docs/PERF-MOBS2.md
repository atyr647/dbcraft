# Mobs, second pass: dbcraft against the real vanilla 26.3 (MOBS2)

Question: docs/SCOREBOARD.md listed mobs as a loss ("2,000 walking mobs: vanilla 44-50 ms, dbcraft 106 ms; about 150 us per awake mob against 22 us").  Re-measure on the current tree against the real
server, then cut dbcraft's cost until it wins, with and without a viewer in range.  This document is the measurement, the change, and what is still a loss.

**Short answer.**  The 106 ms row was stale (docs/PERF-ENTITY.md's lanes had already brought 2,000 mobs to about 33 ms of CPU).  The autonomous lanes of this work make the entity tick 3 to 4 times
cheaper again and write almost nothing to the WAL.  Against vanilla's server thread (CPU per tick, same scenarios, 3 repetitions):

| scenario | vanilla | dbcraft before | dbcraft now | now / vanilla | winner |
|---|---|---|---|---|---|
| 500 cows, a viewer in range | 19.9 ms | 20.4 | **5.0** (p50 3.5) | 0.25 | **dbcraft** |
| 2,000 cows, a viewer in range | 65.6 | 33.0 | **10.9** (p50 8.7) | 0.17 | **dbcraft** (6x) |
| 5,000 cows, a viewer in range | 178.6 | 57.4 | **18.2** (p50 16.2) | 0.10 | **dbcraft** (10x) |
| 5,000 stone items at rest, a viewer in range | 96.9 | 2.2 | **1.4** (p50 0.6) | 0.014 | **dbcraft** (70x) |
| 2,000 cows, nobody in range | 5.2 | 28.0 | 12.0 (p50 9.8) | 2.3 | **vanilla** |
| 5,000 cows, nobody in range | 10.1 | 54.6 | 19.2 (p50 18.5) | 1.9 | **vanilla** |

So **mobs are no longer a loss wherever a player can see them (2,000 and 5,000 awake walking mobs: dbcraft 6 and 10 times cheaper than the vanilla server thread), and resting items stay a large win;
mobs nobody can see are still a loss of about 2x**, and that part is explained and measured below.  Read the caveats first.

**Part 2 (the scoreboard campaign found mobs nobody can see 3.8-6.6x worse than vanilla, and the in-view cost 3-4x higher than part 1 measured; sections "Part 2" below).**  Vanilla and dbcraft alternated
V D V D V D, vanilla `-Xms1G -Xmx2G`, CPU per tick, median of 3, machine load 3-7:

| scenario | vanilla | dbcraft part 1 | dbcraft now | now / vanilla |
|---|---|---|---|---|
| 500 cows nobody can see (a viewer is connected, the ring is outside his view) | 5.0 ms | 5.4 | **3.5** | **0.71** (dbcraft) |
| 2,000 cows nobody can see | 6.6 | 11.4 | 8.2 | 1.24 (vanilla) |
| 5,000 cows nobody can see | 10.5 | 21.1 | 13.2 | 1.25 (vanilla) |
| same, **nobody connected**: 500 / 2,000 / 5,000 cows | 5.0 / 6.6 / 10.5 | | **1.4 / 4.2 / 7.5** | **0.28 / 0.64 / 0.71** (dbcraft) |
| 2,000 / 5,000 cows in view | 81.5 / 195 | 9.6 / 18.7 | **9.5 / 20.6** | **0.12 / 0.11** (dbcraft) |

The in-view cost was never 3-4x higher because of the simulation distance: the scoreboard ran its mob rows on a database whose ground its edit scenario had littered with 2,000 blocks, and a mob that
cannot get a lane costs 250-300 us a tick (section 1).  Mobs nobody can see are no longer simulated tick by tick (lazy lanes, section 2); `dbcraft.entity-mode` stays `off` (section 5).  What is still a
loss is in section 6.

## Method, and what the machine allowed

* **Vanilla**: the real 26.3 server (`~/.cache/dbcraft/server-26.3.jar`, Java 25), flat world, view distance 5, simulation distance 10, one probe client (`tools/entity/probe_client.py`: logs in,
  answers keep-alives, counts what it receives), cows summoned over RCON with the default AI (`tools/entity/vanilla_mobs.py`; `mob_drops` / `entity_drops` off: the `kill` between scenarios first left 800
  loot items that made the next scenario look worse).  Scenarios: `NNNv` = N cows spread over +-40 blocks (+-72 from 5,000) around the viewer, all tracked; `NNNn` = N cows on the square ring 100-140
  blocks away: simulated (simulation distance 10) but seen by nobody (tracking radius 80 blocks); `5000i` = 5,000 stone items at rest.  30 s settle, 30 s window sampling `/tick query` every 5 s and the CPU of
  the `Server thread` and of the whole JVM from `/proc`.  A fresh JVM per repetition, **`-Xms512M -Xmx1G`** (the scoreboard used 2 GB: on this machine the container's memory cgroup killed the JVM at 5,000 cows,
  2.2 GB resident, with 5-7 GB of tmpfs used by other agents' clusters; a smaller heap costs vanilla some GC time, which slightly favours dbcraft).
* **dbcraft**: `tests/bench/mobs2/bench.sql`: the same populations as rows (cows announced to the one viewer), 150 warm-up ticks, `VACUUM ANALYZE` (what autovacuum and autoanalyze do within a minute on a real
  server; **without the ANALYZE the planner worked with statistics taken when the lane table was empty and the new engine's 500-cow tick cost 11 ms for 250 ticks before it dropped to 3.5**: my first
  numbers were wrong by that), then 100 measured `mc.entity_tick` calls, **one transaction per tick** (in one transaction every update of a row inserted by the same transaction also runs a foreign-key check,
  which the server does not).  CPU = on-CPU time of the backend (`/proc/self/schedstat`).  `old` = the tree before this work (commit 046d1e2) in its own database, `new` = this branch.  `walk1` = every mob walks
  all the time (`dbcraft.entity_walk_prob = 1.0`) instead of the prototype's 60 % of new goals being walks.
* **Alternation**: `tests/bench/mobs2/campaign.sh` runs V D V D V D (a vanilla repetition over all scenarios, then the dbcraft block, three times).  The dbcraft numbers in the table above are the later
  `tests/bench/mobs2/steady.sh` run (old and new alternating, 3 repetitions, after the ANALYZE problem was found); the dbcraft columns of the campaign itself (raw files in
  `docs/perf-mobs2-results/campaign/`) used the bench before that fix and are superseded.  So vanilla and dbcraft were NOT interleaved in the final numbers: they ran on the same machine within about
  two hours of each other, under different loads.
* **The machine was not quiet.**  4 vCPUs shared with about eight other agents (test suites, Postgres clusters, JVMs): load average 8-24 during the vanilla measurement, 3-10 during the final dbcraft
  runs.  Vanilla's wall-clock tick time is therefore useless (215 ms mean for 2,000 cows where it measured 44-50 ms on a quiet machine, docs/ENTITY.md), so the vanilla number is the CPU of its server thread per
  tick (cores x time per tick, a tick longer than 50 ms counting as the whole interval); that is also inflated by contention (cache, SMT), more at load 20 than the dbcraft runs at load 5.  A 2x correction of
  vanilla's CPU would not change one winner in the table, and it would make the two losses 4.6x and 3.8x.  Each cell is the median of 3 repetitions; the [min-max] ranges are in the raw tables below and are
  tight for dbcraft (typically within 10 %) and wide for vanilla's 5,000-cow runs (177-222 ms).

## Results (medians [min-max] of 3 repetitions)

### Vanilla 26.3, `docs/perf-mobs2-results/campaign/vanilla.jsonl`
| scenario | tick mean ms (wall, loaded machine) | tick p99 ms | server-thread CPU ms per tick | JVM cores | viewer KB/s | load |
|---|---|---|---|---|---|---|
| 500v | 47.8 [43.4-56.9] | 206 [154-502] | 19.9 [17.9-21.7] | 0.49 [0.41-0.52] | 16 [14-17] | 15 [8-21] |
| 2000v | 215.6 [80.8-226.1] | 596 [259-599] | 65.6 [60.6-69.9] | 0.38 [0.34-0.94] | 41 [34-111] | 13 [7-14] |
| 5000v | 316.7 [284.1-875.6] | 885 [720-2081] | 178.6 [177.0-222.4] | 0.63 [0.29-0.71] | 22 [6-23] | 10 [9-24] |
| 2000n | 10.6 [8.8-19.4] | 52 [42-53] | 5.2 [5.1-5.4] | 0.11 [0.11-0.17] | 0 | 11 [8-23] |
| 5000n | 22.1 [14.7-51.0] | 130 [68-582] | 10.1 [9.8-11.2] | 0.26 [0.23-0.29] | 0 | 11 [6-21] |
| 5000i | 322.2 [132.4-425.2] | 966 [457-995] | 96.9 [69.4-112.5] | 0.38 [0.26-0.60] | 2 [2-4] | 14 [9-21] |

### dbcraft, entity tick as the server tick pays it (inline mode), CPU ms per tick, `docs/perf-mobs2-results/steady.txt`
| scenario | variant | CPU mean | CPU p50 | CPU p99 | wall mean | out KB/tick | WAL KB/tick | load |
|---|---|---|---|---|---|---|---|---|
| 500v | old | 20.4 [17.0-22.2] | 19.9 | 31.6 | 23.3 | 1 | 1 [1-4] | 7 [3-8] |
| 500v | **new** | **5.0** [4.4-5.4] | 3.5 | 13.2 | 7.9 | 1 | 0 | 7 |
| 2000v | old | 33.0 [32.0-33.2] | 31.9 | 54.1 | 63.3 | 4 | 17 [9-22] | 8 [3-10] |
| 2000v | **new** | **10.9** [10.5-11.0] | 8.7 | 21.4 | 23.8 | 4 | 0 | 8 |
| 2000v | old, all walking | 41.0 [39.1-42.1] | 40.4 | 61.7 | 76.2 | 9 | 44 [20-50] | 9 |
| 2000v | **new**, all walking | **14.2** [14.0-14.4] | 12.1 | 26.2 | 25.1 | 9 | 0 | 9 |
| 5000v | old | 57.4 [57.4-63.0] | 56.6 | 93.5 | 71.4 | 10 | 61 [56-91] | 8 [3-10] |
| 5000v | **new** | **18.2** [17.9-19.7] | 16.2 | 43.6 | 20.7 | 10 | 1 [1-3] | 8 |
| 5000v | old, all walking | 82.4 [82.3-83.2] | 81.3 | 104.6 | 87.2 | 22 | 137 [127-237] | 7 |
| 5000v | **new**, all walking | **26.7** [26.3-31.1] | 24.8 | 52.0 | 33.6 | 22 | 2 [2-3] | 6 |
| 2000n | old | 28.0 [27.9-29.2] | 27.2 | 44.3 | 31.6 | 0 | 9 [9-19] | 6 |
| 2000n | **new** | **12.0** [11.3-12.5] | 9.8 | 31.6 | 15.2 | 0 | 0 | 6 |
| 5000n | old | 54.6 [49.0-55.5] | 52.8 | 82.2 | 66.1 | 0 | 69 [55-80] | 5 |
| 5000n | **new** | **19.2** [18.9-22.8] | 18.5 | 35.9 | 25.1 | 0 | 1 | 6 |
| 5000i | old | 2.2 [2.2-3.0] | 1.7 | 9.9 | 4.5 | 0 | 0 | 7 |
| 5000i | **new** | **1.4** [1.2-1.5] | 0.6 | 7.2 | 3.0 | 0 | 0 | 7 |

Per awake-or-walking mob and tick (mean CPU / mobs): old 16.5 us (2,000) and 11.5 us (5,000); **new 5.5 us (2,000) and 3.6 us (5,000)**; vanilla (loaded) 33 us and 36 us with a viewer, 2.6 us and 2.0 us
without.  500 mobs cost 5.0 ms and 2,000 cost 10.9: a fixed part of about 3 ms per tick (the statements of the tick and the scan of the lane table) plus 2.4-3.9 us per mob.

### The entity connection (`dbcraft.entity-mode = split`, `tests/bench/mobs2/split.sh`)
B runs `call mc.entity_loop()` on its own connection (A stood in for by a clock): the tick of the player connection pays nothing for mobs in that mode.  B's CPU per tick is the inline number above
(10.9 ms at 2,000 cows, 18.2 at 5,000, 26.7 at 5,000 all walking: far inside 50 ms on a free core).  The wall times in `docs/perf-mobs2-results/campaign/split.txt` were measured at load 8-24 and say
only that B kept up on 133 of 150 ticks at 2,000 cows (its worst lag 4 ticks) and fell behind and jumped at 5,000 with the machine as it was (jump: positions are closed forms, nothing drifts, test 940 F).
The ownership rules and the determinism test of docs/PERF-MULTICORE.md are unchanged; test 550 passes.

## Reading the numbers

* **A viewer in range: dbcraft wins at 500, 2,000 and 5,000 awake mobs** by 4, 6 and 10 times against the vanilla server thread, and 3 to 4 times against its own previous engine, with the WAL down from
  17-137 KB per tick to about nothing.  Vanilla's cost per cow with a viewer (33-36 us) is its tracker (every tracked cow sends position, motion, head rotation, sound packets: about 540 move, 270
  move+rotation, 640 motion, 430 head packets and 30 sounds per second for 500 cows at 14 KB/s), pathfinding, goal selection and entity collision with 2,000 cows in 80 x 80 blocks.  dbcraft does none of
  that work (list below), so this is not a like-for-like result; it is what the same scenario costs when the server only does what dbcraft models.
* **Resting items**: 5,000 items cost vanilla 97 ms per tick (it cannot hold 20 TPS) and dbcraft 1.4 ms: sleeping entities are not read at all.
* **Nobody in range: dbcraft still loses by 1.9-2.3x** (12.0 ms against 5.2 at 2,000 cows, 19.2 against 10.1 at 5,000).  Vanilla's idle cow in an unobserved region costs 2.0-2.6 us per tick: no tracker,
  no packets, a goal-selector pass that fails 59 times out of 60, a move that is a few adds.  dbcraft's mob costs 3.8-6 us because its activity is events through SQL: each new goal is a statement pipeline
  over a row (the goal draw, the floor test, the cell bookkeeping, a HOT update of a 230-byte row: about 60-110 us of CPU), 30 of them per tick at 2,000 mobs; plus a scan of the lane table; plus the steps
  (a third of the walking mobs per tick at about 3 us each; building them for mobs nobody can see is 3.3 of 15.4 ms, measured by disabling the steps on a noisy machine, so about 20 %); plus a fixed 3 ms
  of statements per tick.  **What dbcraft cannot beat here is the price of a row update inside a statement against a field write in a JIT-compiled loop**, on an activity that vanilla thins out far more
  (a stroll starts on average every 120 ticks of an idle cow and about 24 % of the cows walk at a given moment, derived from the probe's movement-packet counts, against 45 % in dbcraft's wander model:
  goals of 20-80 ticks walking / 40-140 standing).  What would go below it is not simulating what nobody observes (park the lanes of cells no viewer can see and fast-forward them in closed form when a
  viewer arrives or a block changes near them; the goal draws are a hash of (id, tick), so the catch-up is a replay): designed, not built.  Also, in dbcraft's own rules this population does not last:
  `mc.entity_despawn` removes a mob that no viewer's cell contains after 600 ticks (30 s), and the benchmark measures it before that (about 130-280 ticks).
* **AI cadence (the lever asked for)**: vanilla's goal selection runs on every second tick per mob (`(tickCount + id) % 2`, below) and a stroll starts with probability 1/60 per selection; dbcraft has
  no per-tick goal evaluation to thin out, a decision is an event, so the cadence rules save nothing here and were not copied.  Making the wander model vanilla-like (idle about 120 ticks, 24 % walking)
  would cut dbcraft's event rate and would help in exactly the losing cases; it changes visible behaviour (mob activity) and was not done without the vanilla goal system behind it.

## What vanilla does per mob (read from the 26.3 jar with `javap -c`, not from memory)

* `Mob.serverAiStep`: every tick `noActionTime++`, sensing; goal selection only when `(tickCount + entityId) % 2 == 0` (or in the first tick of life) for the target and goal selectors
  (`GoalSelector.tick`: every NOT running goal is asked `canUse()`), otherwise only `tickRunningGoals(false)` (running goals that require an update every tick); then `navigation.tick()` and the move controller.
* `RandomStrollGoal.canUse` (cows: `WaterAvoidingRandomStrollGoal(1.0)`, interval 120): false when `noActionTime >= 100`, else `random.nextInt(reducedTickDelay(120)) == 0`, `reducedTickDelay(120) = 60`:
  1/60 per evaluation, evaluations every 2nd tick, so an idle cow starts a stroll on average every 120 ticks; the target is a random point within 10 blocks horizontally / 7 vertically
  (`DefaultRandomPos.getPos(mob, 10, 7)`), reached by A* pathfinding.
* `ServerEntity.sendChanges` (every tracked entity, every tick): work only when `updateInterval.test(tickCount)` (3 for everything but items 20 and players 2) or the entity data is dirty; `trackDelta` is true for
  every type except players, so a velocity change (squared > 1e-7) also sends `set_entity_motion`; rotation changes send `move_entity_rot` + `rotate_head`.
* **What dbcraft does not model** (and vanilla pays for): A* pathfinding, the goal system, look-around and look-at-player rotation packets, `set_entity_motion` for mobs, ambient sounds, entity-entity
  collision and pushing, cramming, random ticks, vanilla's despawn rules.  The traffic a viewer gets is therefore also different: vanilla 14-41 KB/s for 500-2,000 cows, dbcraft 20 KB/s (500) and 80-180 KB/s
  (2,000 cows, normal and all walking), movement packets only (dbcraft probably sends more bytes at 2,000 because 45 % of its cows walk against vanilla's 24 %).

## Where the time went before (old tree, proportions: measured at load 10-14 with a bench that had no ANALYZE yet)
The lanes of docs/PERF-ENTITY.md made a *goal* cheap but not a *mob*: per awake mob the old engine still did a primary-key probe of the wide `mc.entity` row and an update of the lane row for every tracker
step (a third of the mobs every tick), and every goal change went through flush (wide row update), AI (wide row update) and lane-try (lane insert + wide row update): statements with a fixed cost each, three
non-HOT updates of a 40-column row with five indexes per goal.  One tick of 2,000 cows: lane step 6.6, physics 2.1 (for the dozen mobs a tick that had just left a lane at a chunk border), AI 1.9, lane-try x2
2.8, tracker 1.5, flush 0.8, despawn 0.7 spiking on every 20th tick, log insert 0.3 (ms of CPU); WAL 130 KB per tick.

## What changed (sql/940 and in-place edits of 510 / 541 / 550 / 551)

1. **Autonomous lanes** (`mc.entity_lane` with `auto = true`).  The lane row is the whole state of the mob: anchor position and tick, velocity, goal end, chunk cell, the delta base the viewers hold,
   a precomputed packet head.  A tracker step reads the lane row only and **writes nothing**: the packet is `head || dx || 0 || dz`, and the delta base after a step is the position one step earlier (closed
   form; only the first step of a segment reads the stored base).  `mc.entity_auto_base` computes the base the viewers hold after any number of steps; test 940 B checks it against a stateful step-by-step
   simulation on 12,000 random lanes.
2. **The next goal is drawn inside the lane** (`mc.entity_goal`: the hash and distribution of `mc.entity_ai_ids`, pinned to each other by test 940 A): one narrow row update (HOT; `entity_lane` has
   fillfactor 50, which took the HOT share from 31 % to 100 %) instead of flush + AI + lane-try on the wide row.
3. **The chunk border is crossed inside the lane** when the viewers of the two cells are the same (`mc.entity_view_same`; with one viewer in range, or none, that is always): the lane gets a new
   segment, the entity row its new cell (one update per crossing).  When the crossing changes who sees the mob the lane ends and the exact sweep and the generic tracker send the appearance / removal as
   before (test 940 E2: the viewer who loses the mob gets exactly one `remove_entities`).
4. **Chasing mobs (zombies) keep the lanes of sql/541** (they re-aim every 5 ticks); `dbcraft.entity_auto = off` routes everybody there (test 940 H).
5. **Cheap things around it**: the physics statement is skipped when no entity is awake outside a lane (one probe of a partial index); the tracker's announcement statement when nothing is new;
   `mc.entity_cell_exit` is an inlinable expression (it was a SQL function with a sub-select: 21 us per call, 80 calls a tick); the per-cell blobs are fanned out by a function whose every access is a
   primary-key probe (a 121-row table was scanned 40 us per blob); a partial index of dropped items by cell for the pickup scan; the legacy lane scans read a partial index of the few legacy rows;
   `mc.entity_tick_log` is trimmed (it never was: 20 rows a second for ever) and `mc.entity_clock` replaces the lane-row count in the log.
6. **A gap in the tick numbers** (the entity connection jumped ahead, sql/550) re-anchors every autonomous lane at the tick before the next one with the viewers' real base stored
   (`mc.entity_auto_rebase`, test 940 F: nothing drifts).  Found by that test: the first version anchored at the last tick that ran and sent a delta that missed the skipped ticks.
7. A latent bug fixed on the way: `ceil(distance / g)::bigint` overflowed for a walk direction with `g` about 1e-17 (`sin(pi)`), which would have aborted the whole entity tick
   (`mc.entity_lane_cand` of sql/541 had it too).

### Physics and packets
Untouched: tests 510 / 530 / 541 / 550 / 551 pass with their bodies unchanged except where they looked at internals (541 B read `lane_until` of the entity row, now the lane's `goal_until`; 551 expected one
`play_out` row per viewer, now at most two: one per statement, the autonomous lanes and the chasing lanes).  The recorded vanilla trajectories of tests 510 / 530 are not involved (items and the exact sweep
did not change); the mob walk is checked against the exact sweep to 1e-9 over 400 ticks (541 C, 940 C).  The packets a viewer receives are byte-identical to the old lanes' for every step that is not a
border crossing (the two streams compared tick by tick on 60 cows over 300 ticks: 2,977 against 3,007 packets; the differences are the extra step at each border crossing of the old engine, now merged into
the next regular one, and the viewer's reconstructed position is the same).  New: `tests/sql/940_entity_auto_lanes.sql` (31 checks).  Full suite: 65 files, 2,296 checks, green;
`tools/check_overrides.py` (59, all listed), `tools/check_inlining.sh` and `tools/check_fresh_migration.sh` green.

## What did not work / pitfalls
* **A bench in one transaction**: adds a foreign-key check to every update of a row inserted by the same transaction and hides the real WAL.  Every run here is one transaction per tick.
* **No ANALYZE after the warm-up**: wrong plans for the first 250 ticks (3x too slow), found only when a quieter machine made a 500-cow tick cost 3.8 ms in one harness and 11 ms in another.
* **`pg_stat_statements` and `auto_explain` under load**: statement wall times include the time the process was descheduled and `auto_explain` with nested statements inflated costs 3 to 5 times; the picture
  was rebuilt from on-CPU time (`tests/bench/mobs2/phases.sql`, read-only copies of the statement timed with `schedstat`).
* **`select fn(...)` of a table function in the select list** is not inlined (300 us per call in a micro benchmark); in `FROM ... CROSS JOIN LATERAL` it is.  Micro benchmarks written the first way pointed
  at `mc.entity_auto_base` and `mc.entity_goal`; they were not the problem (1.5 us inlined).
* **Stray entity connections**: `mc.entity_loop(150)` of split-mode runs that ended early (B jumps ahead when it lags and never counts 150 ticks) were left running and held the vacuum horizon back:
  21,000 dead tuples, a goal-index probe of 27 ms, and a 4x slower `ring` scenario until found.  `tests/bench/mobs2/split.sh` ends B itself now.
* **A bench population written with `random()` in a sub-select that does not depend on the row** puts all 2,000 mobs into one chunk (the first `ring`).
* **Stopping the vanilla JVM (SIGSTOP) between scenarios to give the dbcraft side the machine**: the server kicks its client for the missed keep-alive when it resumes and the next scenario has no
  player.  Alternation is per repetition now.  Vanilla at `-Xms2G -Xmx2G` was killed by the memory cgroup (see Method).
* **Skipping the steps of mobs no viewer can see** (about 20 % of the tick in the viewer-less case): written, measured by alternating the two versions tick by tick on one population, differences inside the noise
  of that machine (-15 % to +40 % between runs of the same comparison), not adopted.  An `= any(array)` or `exists` over an array costs 12-20 us per mob, more than the packet it saves.
* **`plan_cache_mode = force_generic_plan` on the lane tick**: no measurable difference in part 1; in part 2 it turned out to matter for the catch-up statement (13.7 ms of planning per call, section 3).

## Still a loss / not done
* **Mobs nobody can see: 1.9-2.3x vanilla's CPU** (part 1).  Part 2 built the closed-form catch-up (lazy lanes): see section 6 for what is left.
* The comparison is not like for like: dbcraft models no pathfinding, goals, look-around, motion packets, sounds, collision (list above).  The vanilla wall-clock tick times of this machine are not usable
  (load 8-24); only CPU time is compared and both sides are inflated by contention, vanilla more.
* The wander model (45 % walking) is more active than vanilla's cows (about 24 %): it is dbcraft's cost to bear in the comparison, left as it was.
* vanilla and the final dbcraft numbers were not interleaved (see Alternation); the viewer-less vanilla runs show 5.2 / 10.1 ms of CPU at load 11, where a quiet machine might measure less.
* The byte/cadence comparison against recorded vanilla MOB traffic was not repeated beyond the packet counts above.
* A real client was not used (the probe client counts packets); the real gateway was not in the loop (the SQL entity tick is measured).

## Part 2: why the scoreboard saw three times more in view, mobs nobody can see, and the default mode

The scoreboard campaign (docs/SCOREBOARD.md) measured 500 / 2,000 / 5,000 cows in view at 13 / 33 / 71 ms of CPU per tick (vanilla 16 / 61 / 149) and cows nobody can see at 15.5 / 33.9 / 76 ms
(vanilla 4.1 / 6.0 / 11.5, a loss of 3.8-6.6x), and noted that `dbcraft.entity-mode` is `off` as shipped.  Three requests: find the 3-4x, make mobs nobody can see cost no more than vanilla,
decide the default mode.

### 1. The simulation distance is not the cause; the world the scenario ran in is

No entity code reads `simulation-distance`.  Measured to be sure (`tests/bench/mobs2/simdist.sh`, the same scenario at simulation distance 3 and 10 alternating, 2 repetitions,
`docs/perf-mobs2-results/part2/simdist.txt`): 2,000 cows in view cost 12.0 and 13.1 ms at distance 3 and 11.1 and 10.9 ms at distance 10.

What differs is the ground.  A mob gets an autonomous lane only when every column of its walk has the same floor under its feet (`mc.entity_floor`: the highest solid cell is exactly one below
the feet); otherwise it stays in the exact sweep (physics, the generic tracker, a lane retry every tick), at about 250-300 us per mob and tick instead of 3-8.  The scoreboard ran its mob rows
on the database its *edit* scenario had just used, which left 2,000 stone and gold blocks scattered over +-45 blocks at y = -60: a quarter of the columns the cows walk on.  Reproduced:

| 2,000 cows in view, dbcraft CPU ms per tick | |
|---|---|
| fresh flat chunks (`bench.sql -v reset=1`) | 9-11 |
| the same area after the campaign's 2,000 scattered blocks (`-v scatter=2000`, a worse scatter than the campaign's) | 215-238 (about 800 mobs outside lanes: physics 53-63, lane retry 129-149, tracker 26-30 ms) |
| the campaign's database as it was found (`world-state-contamination.txt`) | 69 (1,885 of 2,000 cows in lanes: the awake ones cost 10 ms of physics and 39 of tracker) |

Fixed: `bench.sql` regenerates the flat chunks of the mob area (`reset=1`) and `tools/scoreboard/mobs.sh` passes it, so the mob rows no longer depend on what ran before them in the same
database.  Not fixed: **a mob that cannot get a lane is still expensive** (a built-up world is full of them: the exact sweep is 60-80 us, the lane retry of the two functions 160 us, the generic
tracker 30-60 us per mob and tick).  A negative cache for lane attempts (retry when the goal, the floor or the cell changes) is the obvious next step; it was not built.

### 2. Lazy lanes: what nobody can see is not simulated tick by tick

A lane whose chunk cell is farther than `min(tracking range, view radius) + 1` cells from every viewer cannot be seen by anybody, and nobody can get to see it without a refresh that
passes through `mc.entity_viewers_refresh`.  Its whole future is a pure function of the lane row (a goal is the hash of (id, tick), a walk a closed form), so:

* it is **replayed every 32nd tick** (its slot, `id % 32`), each expired segment with the tick it expired at (`tt = goal_until`), which is exactly the computation a tick-by-tick run makes at `tt`;
  it sends no packets and writes only its own narrow row (HOT);
* **whoever is about to look catches it up first** (`mc.entity_auto_catchup`): a viewer's new cells (before the appearance packets are built), a block change within three chunks (before the lane
  ends), a section change of a chunk with a floor summary (before the summary is dropped: the lane is replayed against the floor as it was), a gap in the tick numbers (`mc.entity_auto_rebase`),
  and the end of a lane;
* **a viewer who gets within reach wakes the lanes around him** (the same refresh): lanes within `min(trk, r) + 1` of his new cell are simulated tick by tick again, so a mob that walks into
  his view is announced at the tick it crosses, exactly as before;
* a lane that is behind by several segments replays one per visit (`mc.entity_auto_tick` runs one pass; a second pass costs 0.7 ms of set-up for a handful of rows), and all of them in
  one call when somebody looks.  `dbcraft.entity_lazy = off` disables all of it.

**Proof** (`tests/sql/940_entity_auto_lanes.sql`, section L; 400 cows, tick-by-tick run against lazy run):

| check | result |
|---|---|
| after 353 ticks the lanes of the lazy run, caught up to that tick, equal the lanes of the tick-by-tick run, every column, to the last bit (anchor, position, velocity, goal, segment end, cell, the viewers' base) | 0 differences in 400 lanes (about 7 goals each; more than 20 lanes were behind when they were caught up: the test asserts it) |
| a viewer teleports next to the cows: the packets he is told in the 120 ticks after (tick, cow, kind, values) | identical sets |
| a viewer walks up, one chunk every 8 ticks, 200 ticks | identical packets |
| a block is placed on the spot of a lane that is behind | every cow in the same state after 7 more ticks |
| a gap of 150 ticks in the tick numbers | same goal chain for all 400 lanes, positions within 0.15 blocks, 90 % identical to the last bit (see the note below) |
| lanes within reach of a viewer are never lazy, and become lazy again within a segment of his leaving | yes |
| no tracker step is computed for a lane nobody watches (after the first ticks) | none logged |

Note on the gap check: the lazy run and the tick-by-tick run differ by up to one walking step (0.1 block) in about 4 % of the lanes there.  The cause is not the replay: in the tick-by-tick run the first
step after a gap cannot always be expressed as a plain delta, the lane is handed to the exact sweep and the generic tracker, and the sweep of that tick places the mob one step off the closed form (the same
hand-off happens at a position sync every 400 ticks: `mc.entity_auto_end(bad, p_tick, ...)` then physics in the same tick; present in sql/541's lanes too).  Lazy lanes have no steps and so avoid it.
The cows of the comparison are born at tick 100000 minus up to 29 and the runs are shorter than 370 ticks for the same reason: tick minus birth = 400 would end a lane in one run only.

### 3. What made the cost, from profiling (the corrected picture of part 1)

Per due mob the replay statement is ~60-90 us of CPU (the goal hash, the segment end, the floor verdict, a HOT update of a 250-byte row), about what part 1 had measured as "transitions 60-110 us",
but **the fixed cost per tick, not the per-mob cost, was what lost against vanilla**:

* **Planning.**  The statement that replays lanes with `p_ids` takes 13.7 ms to plan, and PostgreSQL kept choosing custom plans for it (they looked cheaper than the generic plan): 13.7 ms per call
  of the catch-up path (a viewer's arrival, a block change).  `plan_cache_mode = force_generic_plan` on the function: 1.4 ms.  The per-tick path was less affected (its first plan is generic), which is why
  part 1 measured no difference there.  Applied to `mc.entity_auto_run`, `mc.entity_auto_try` and `mc.entity_lane_try`.
* **Statement set-up**: 1.4 ms per call for the 12-CTE statement even with nothing to do, 0.7 ms after splitting it into a replay statement and a step statement (the second only when an eager lane
  inside the viewers' box is due), after taking the `UPDATE` of the wide `mc.entity` row out of it (opening its six indexes), and a single probe of "what is due" instead of three.
* **Passes**: 2.7 statement passes per tick (80 due rows, then 10, then 1: the lanes that were behind by more than one segment) became one.
* **Index on `goal_until`** (to find the due lanes): worse, not better.  Every segment update then writes an index entry (no HOT), and the dead ones are re-checked by every scan until the next vacuum
  (the probe of one slot read 252 buffers to return one row: 6 ms).  The two partial indexes now are on immutable keys (`id` for the eager lanes, `id % 32` for the lazy ones), so the updates stay HOT.
* **The floor test**: `mc.entity_floor_ok` is a SQL function with sub-selects: 30-42 us per call (executor start-up, not probes).  Each lane keeps the verdict "the 3x3 chunks around my cell are
  uniform at my level" (`ucx`, `ucz`, `uok`; recomputed on a cell change by `mc.entity_floor3`, cleared by the invalidation trigger of sql/541), and a walk that stays within those chunks needs no probe.
* **Dead ends**: removing the CTE materialization (-> 73 ms: every inlined stage re-evaluated the expressions of the one before for each use); a margin of two chunks instead of one around the viewers
  (more eager lanes for nothing); a lane bench on a bloated lane table (the earlier runs of a database left 2,000 pages for 5,000 rows and HOT chains of 40 versions: `bench.sql` starts from a
  `VACUUM FULL` now; the docker configuration vacuums every 10 s).
* **Measuring**: `/proc/self/schedstat` has the resolution of a scheduler tick (4 ms) here, so a single tick's CPU is quantised and p99 values are noise; means over 100 ticks are fine.
  Machine load of 2-8 from other agents moved single runs by up to 2x; every number below is a median of 3 repetitions alternated with the vanilla runs, with the range.

### 4. Results (V D V D V D, `tests/bench/mobs2/campaign2.sh`, `docs/perf-mobs2-results/part2/campaign/`)

CPU per tick, median [min-max] of 3 repetitions.  Vanilla: Server-thread cores x max(mean tick, 50 ms), the real 26.3 jar, `-Xms1G -Xmx2G`, view distance 5, simulation distance 10, one probe client.  dbcraft:
`mc.entity_tick` on freshly generated flat chunks (`reset=1`), one transaction per tick, on-CPU time of the backend, 100 ticks after 150 warm-up ticks and a VACUUM.  `old` = part 1 of this work
(commit d53eb24's tree, in its own database), `now` = this branch.  Load average during the runs: vanilla 2.1-7.5, dbcraft 3.7-7.6 (4 vCPUs shared with other agents).

| scenario | vanilla | old (part 1) | **now** | now / vanilla | now, nobody connected | now, every mob walks all the time |
|---|---|---|---|---|---|---|
| 500 cows, nobody can see them (ring 100-140 blocks, view 5) | 5.0 [4.9-5.0] | 5.4 [4.6-5.9] | **3.5** [3.5-4.4] | **0.71** | **1.4** [1.1-2.2] | |
| 2,000 cows, nobody can see them | 6.6 [6.2-6.8] | 11.4 [10.3-14.0] | 8.2 [7.0-10.1] | 1.24 | **4.2** [3.5-5.1] | |
| 5,000 cows, nobody can see them | 10.5 [10.4-11.2] | 21.1 [19.3-21.6] | 13.2 [12.8-20.6] | 1.25 | **7.5** [7.3-8.3] | |
| 2,000 cows in view | 81.5 [67.9-84.6] | 9.6 [9.2-15.5] | **9.5** [9.0-9.9] | **0.12** | | 11.8 [11.8-12.8] |
| 5,000 cows in view | 195 [173-260] | 18.7 [18.4-18.8] | **20.6** [20.4-22.1] | **0.11** | | 32.6 [31.5-33.6] |

(The scoreboard campaign measured vanilla at 6.0 / 11.5 ms for 2,000 / 5,000 cows out of sight and 61 / 149 in view on a quiet machine; here, at load 3-7, 6.6 / 10.5 and 81.5 / 195.  dbcraft's
100-tick means move by 10-20 % between runs at that load.  Neither side is corrected.)

* **Nobody can see the mobs and nobody is connected: below vanilla at all three sizes** (0.28, 0.64, 0.71 of vanilla): lanes replayed every 32nd tick cost 1.4 / 4.2 / 7.5 ms, that is 2.8 / 2.1 / 1.5 us
  per mob and tick against vanilla's 10 / 3.3 / 2.1 (vanilla's fixed cost dominates at 500).
* **A viewer is connected but cannot see the mobs (the scoreboard's "nobody in range" rows): 500 cows below vanilla (0.71), 2,000 and 5,000 still about 1.25x vanilla**, down from 1.7x and 2.0x (part 1)
  and from the scoreboard's 5.7x and 6.6x (that tree on the contaminated world).  What is left over the nobody-connected case (+4 ms at 2,000, +6 ms at 5,000) is the viewer's margin: lanes within
  `min(tracking range, view) + 1` = 6 chunks of him are simulated every tick (14 % of the ring's mobs; they cannot be lazy: a mob that crosses into his view has to be announced at the tick it crosses),
  they send nothing while they are outside his view, but each time one *does* cross the edge of his view the lane ends, and the exact sweep, the generic tracker and the lane retry take
  over for a few ticks: 0.2 mobs a tick at 5,000 cows, 3 ms a tick for the three statements together (about 13 ms of statement set-up per such mob).  Handling the appearance inside the lane statement instead of ending the lane would remove that; not done.
* **In view: unchanged, 10-12x below vanilla** (the tick is the same tick: 9.5 against 9.6 ms at 2,000, 20.6 against 18.7 at 5,000: the lazy bookkeeping, the verdict columns and the second statement cost
  the in-view case 0-10 %).  With every mob walking all the time (how the scoreboard ran these rows) 11.8 / 32.6 ms.
* **Spread of the dbcraft runs** is 5-10 % for nobody-connected and in view, up to 25 % for the connected-viewer case (a few mobs a tick leaving lanes at the edge of his view).

### 5. Should `dbcraft.entity-mode` be `inline` by default?  Measured: no.

`tests/bench/mobs2/idle.sql` / `idle.sh`: players stand still, **no entity exists**, the hook that `mc.server_tick` calls (`if mc.entity_mode() <> 'off' then mc.entity_step(tick)`) is timed in wall
microseconds (CPU time has a 4 ms resolution here), 200 ticks per cell, 3 rounds alternating the modes (`docs/perf-mobs2-results/part2/idle-entity-mode.txt`; the machine was shared: compare the minimum
and p50):

| players | `off` | `inline` (no mobs) | `split`, player connection | `split`, the entity connection |
|---|---|---|---|---|
| 0 | 15 us | 500-960 us | 60-70 us | 480-980 us |
| 50 | 15-20 us | 700-1,600 us | 60-80 us | 720-1,380 us |
| 200 | 15-20 us | 1,160-1,970 us | 63-86 us | 1,170-2,150 us |

The cost with nothing to simulate is not about zero.  `inline` costs 0.5-1 ms at no players, 1.2-2 ms at 200 players (the viewer-cell refresh of every player every tick, the AI and tracker
statements, the log row), which is 5-9 % of the scoreboard's idle-200 tick (20.6 ms) and 4-8x the whole quiet tick of an idle server with nobody connected (0.125 ms); and it **switches the quiet-tick
fast path off**: `mc.tick_quiet` (sql/800) requires `mc.entity_mode() = 'off'`, so an idle server with no players would run full ticks.  The prototype spawner is also on in `inline` mode unless
`dbcraft.entity_spawner = off` (a cow or a zombie within 16-32 blocks of every player every 40 ticks, 8 mobs per player): a default of `inline` would change what the server does, not only
what it costs.  So `off` stays the default, and the server that wants items (drops, containers, death drops) and mobs sets it: `update mc.server_property set value = 'inline' where key =
'dbcraft.entity-mode'` (`split` with `tools/entity_loop.sh` for the second connection), and `set dbcraft.entity_spawner = 'off'` for items without wandering mobs.  What would make `inline` free:
an early exit in `mc.entity_step` when there are no entities and nobody to spawn for, a viewer refresh that only runs when a player changed chunk, and `mc.tick_quiet` accepting an empty entity table
(sql/800 belongs to the idle track and was not touched).

**Update (docs/WHY-MOBS-COST.md section 9):** the early exit asked for above is built: `mc.entity_tick` returns at once with no entity row (and the spawner off or nobody connected), and `mc.tick_quiet` accepts `inline` with no
entity; the empty hook costs 35-75 us instead of 0.35-1.0 ms and does not grow with the players.  `off` is still the default.  The WAL figures of the in-view cells in this document ("about 0") were measured with the write
position of the WAL; the insert position gives 12 KB per tick at 2,000 cows in view (WHY-MOBS-COST section 2).

### 6. Still a loss / not done
* **A viewer connected, mobs just outside his view: 1.25x vanilla at 2,000 and 5,000 cows** (above).  The margin band and the lane that ends when a mob crosses the edge of his view are the cost; the
  fix (announce inside the lane statement, no end of the lane) was not built.
* **A mob that cannot get a lane** (a built-up world: any column of its walk not at the floor level of its feet) costs 250-300 us per tick (exact sweep 60-80, lane retry of two functions 160, generic
  tracker 30-60).  A world where a quarter of the ground has blocks on it costs 215-238 ms at 2,000 cows in view against 10 ms on flat ground.  Needs the negative cache and a cheaper floor test.
* The first execution of every plan after a VACUUM / ANALYZE of the entity tables costs 3-30 ms (the cached plans are invalidated: 70 ms of re-planning per vacuum cycle, about 0.35 ms a tick at the
  docker configuration's 10 s cycle) and shows up as spikes (p99 30-45 ms of the bench).
* Lanes nobody can see are **not exact to the tick** at the moment they end near a floor edge (a lane that cannot continue ends at the tick it is replayed, up to 31 ticks after the tick it
  expired at: the mob loses that walk); the equality tests use worlds where lanes stay on a floor.  `mc.entity_live` of a lazy lane is exact only after `mc.entity_auto_catchup`.
* The comparison is still not like for like (vanilla's pathfinding, goals, tracker traffic: list above), and dbcraft's cows walk 45 % of the time against vanilla's 24 %.
* Split mode (entity connection) was not re-measured in part 2; its block-event path (`mc.entity_wake_apply`) catches lanes up before it ends them, but in split mode the floor-change hook is off
  (the lanes belong to the other connection) and a lane that is behind when the floor of its chunk changes is replayed against the new floor.

### 7. Reproduce part 2
```
export PGHOST=/tmp PGPORT=57411 PGUSER=postgres
tests/bench/mobs2/applydir.sh DB [DIR]            # apply the entity files of sql/ (or of DIR: the old tree) to a database
OLD_DB=mob3old NEW_DB=dbcraft tests/bench/mobs2/campaign2.sh /dev/shm/mob3-res 3 500n,2000n,5000n,2000v,5000v     # V D V D V D
python3 tests/bench/mobs2/aggregate2.py /dev/shm/mob3-res                                                       # the table of section 4
psql -X -v mobs=2000 -v where=view -v reset=1 -v scatter=2000 -v warm=150 -f tests/bench/mobs2/bench.sql         # the world the scoreboard's edit scenario leaves behind
tests/bench/mobs2/simdist.sh 2000v 2                                                                            # simulation distance 3 against 10
tests/bench/mobs2/idle.sh 0 50 200                                                                              # section 5
psql -X -q -At -f tests/bench/mobs2/fn.sql (functions) / passes.sql (passes per tick) / ae3.sql (plans with timing) / stages.py
```
Raw results: `docs/perf-mobs2-results/part2/`.

## Reproduce
```
DBCRAFT_PGDATA=/dev/shm/mob-pg DBCRAFT_PGPORT=57411 tests/bench/entity/setup_db.sh dbcraft_dev      # new tree; the same script from a checkout of 046d1e2 gives the `old` database `dbcraft`
export PGHOST=/tmp PGPORT=57411 PGUSER=postgres RCON_TIMEOUT=180
tests/bench/mobs2/campaign.sh /dev/shm/mob-res 3          # vanilla repetitions + the dbcraft block (superseded by steady.sh for dbcraft); needs the jar, Java 25, 2+ GB free
tests/bench/mobs2/steady.sh /dev/shm/mob-res/steady.txt 3  # dbcraft old/new, steady state
python3 tests/bench/mobs2/aggregate.py /dev/shm/mob-res    # the tables above
psql -X -v mobs=2000 -v where=view -v ticks=100 -v warm=150 -f tests/bench/mobs2/bench.sql    # one scenario;  phases.sql, pgss.sql, ae.sql, spikes.sh, ab_run.sql: where the time goes
```
Raw results: `docs/perf-mobs2-results/` (`campaign/vanilla.jsonl` one JSON line per repetition and scenario with the 5-second `tick query` samples and the packet counts of the probe client).
