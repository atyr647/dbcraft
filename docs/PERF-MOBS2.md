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
* **`plan_cache_mode = force_generic_plan` on the lane tick**: no measurable difference.

## Still a loss / not done
* **Mobs nobody can see: 1.9-2.3x vanilla's CPU** (numbers and the cause above).  Not reachable with this design without not simulating unobserved lanes (the closed-form catch-up described above).
* The comparison is not like for like: dbcraft models no pathfinding, goals, look-around, motion packets, sounds, collision (list above).  The vanilla wall-clock tick times of this machine are not usable
  (load 8-24); only CPU time is compared and both sides are inflated by contention, vanilla more.
* The wander model (45 % walking) is more active than vanilla's cows (about 24 %): it is dbcraft's cost to bear in the comparison, left as it was.
* vanilla and the final dbcraft numbers were not interleaved (see Alternation); the viewer-less vanilla runs show 5.2 / 10.1 ms of CPU at load 11, where a quiet machine might measure less.
* The byte/cadence comparison against recorded vanilla MOB traffic was not repeated beyond the packet counts above.
* A real client was not used (the probe client counts packets); the real gateway was not in the loop (the SQL entity tick is measured).

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
