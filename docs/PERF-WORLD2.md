# World track 2: fills with a player in range, whole sections, fill modes, terrain against vanilla

Scope (the losses and never-compared items of the world side): (1) what a large fill costs the tick when a player can see it, **measured against the real vanilla 26.3
server for the first time**; (2) the whole-section fill cost that had regressed (0.31 to 0.42 ms) and the `/fill` modes, which had no SQL counterpart; (3) terrain
generation (`dbcraft:noise`) against vanilla generating real terrain; (4) the scoreboard's edit rows for the record.  Everything client-visible stays byte-identical:
`tests/e2e/compare_fill.py` against a real vanilla server was re-run on the final code (see "Verification").

## How the numbers were taken, and why most of them are not clean

**The machine was not quiet, and got worse while I worked.**  4 cores shared with about 8 other workers; the load average was 4 to 5 at the start, 10 to 26 for most of the
measurements below, and the container was restarted once.  Absolute times in this document therefore differ by factors between runs (`ab_fill.sql` gave 0.92 ms and 5.57 ms of *CPU* time for the same original whole-section fill in two
runs minutes apart, both at a load average above 20); **only the ratios inside one interleaved run mean something, and every table says at which load it was taken.**
Measures: CPU time of the backend (`tests/bench/edit/cpu_timer.sql`, resolution 4 ms, hence groups of many calls), A/B interleaved in one session and one database
(`tests/bench/world2/ab_world2.sql` against frozen copies of the starting commit's functions in schema `bench_head`, `tests/bench/world/ab_fill.sql` against the original
per-block-era fill), and for vanilla the CPU time of the JVM's "Server thread" and of all its threads from `/proc/PID/task/*/schedstat` (nanoseconds)
(`tests/bench/world2/vanilla_fill.py`, `vanilla_gen.py`).  Java 25, the pinned jar (SHA-1 `33680f5f...`), G1; the heap was 2 GB in the first vanilla run and 0.9 to 1.2 GB later,
because the memory cgroup of this container OOM-killed every JVM that grew past about 1.3 GB (it killed my vanilla server four times and other workers' servers repeatedly).

## 1. A fill with a player in range

What a client sees is unchanged: the packets are the ones `compare_fill.py` proves identical to vanilla's.  What changed is **where the encoding happens and how much it costs**.

### Vanilla, measured (`vanilla_fill.py`: RCON command, a scripted client in range, JVM CPU between the command and 0.6 s after it, idle baseline subtracted)

First run, load average 4 to 5, 2 GB heap, 7 repetitions after a warm-up call (stone and air alternate, every call changes every block).  "main" = the Server thread
(which runs the command *and* the tick that broadcasts the change), "JVM" = all threads (light engine, chunk workers, network):

| scenario | viewer: RCON round trip | viewer: main CPU | viewer: JVM CPU | nobody: main CPU | nobody: JVM CPU |
|---|---|---|---|---|---|
| 100,000 blocks (scoreboard fill), 48 packets, 197 kB | 424 ms (344-466) | **239 ms** | 647 ms | 173 ms | 564 ms |
| 64 whole sections (262,144 blocks) | 1,489 ms | **629 ms** | 1,728 ms | 511 ms | 2,096 ms |
| one whole section | 30.8 ms | 15.7 ms | 32.8 ms | 6.5 ms | 6.2 ms |
| 1,000 blocks | 8.9 ms | 9.8 ms | 51.6 ms | 3.0 ms | 5.6 ms |
| 10 blocks / 48 blocks / 1 block | 2 to 4.5 ms | under 2 ms (below what the method resolves) | | | |

Second run, load average 10 to 17, cold JVM (0.9 GB heap): 100,000 blocks 286 ms main / 765 ms JVM (viewer), 255 / 666 (nobody); 64 whole sections 645 / 2,644 and 637 / 2,504.
The main-thread CPU agrees between the runs (239 to 286 ms), the wall-clock times do not (424 against 1,315 ms).  Two things the scoreboard did not show: the 201 ms it
quoted for vanilla's 100,000-block fill (no player, no load) is the *wall* time of an RCON round trip; with a player in range the same fill costs the main thread 240 to 290 ms of
CPU, and the packets reach the client in the tick after the command (44 to 140 ms after the RCON reply in an exploratory run), so the client sees the change after command + tick.

### dbcraft, before and after (`ab_world2.sql`, one fake connection in range, CPU ms per call, median (min - max) of 5 rounds, **load average 8 to 10**)

"fill" is the statement that changes the blocks (a separate backend: an admin's SQL, not the tick); "tick" is `mc.broadcast_block_events()`, step 5 of the tick.

| scenario | fill, before | fill, after | tick, before | tick, after | tick ratio |
|---|---|---|---|---|---|
| 100,000 blocks (48 sections, 197 kB) | 90.7 (79-111) | 103.0 (98-108) | **315.9 (292-321)** | **9.0** (-7 - 14: below the 4 ms resolution of the CPU timer; a wall-clock run gave 3.1 ms) | 35x |
| 64 whole sections (517 kB) | 51.5 (45-62) | 62.0 (58-68) | 178.9 (163-204) | 4.9 (1.5 - 15) | 36x |
| one whole section | 9.0 (7.7-9.5) | 11.1 (7.9-11.7) | 4.1 (2.8-6.4) | 1.0 | 4x |
| 1,000 blocks | 14.3 (8.8-18.0) | 16.7 (14.1-18.4) | 6.7 (4.2-9.4) | 1.7 | 4x |
| 48 blocks (per-block events) | 34.8 | 35.1 | 3.6 | 3.2 | unchanged path |
| 10 blocks | 18.2 | 16.8 | 3.2 | 3.6 | unchanged path |
| 1 block | 2.7 | 2.5 | 1.36 | 1.34 | unchanged path |

(The absolute values of the small rows are 10 to 20 times what a quiet machine gives, see above: a `set_block` is 0.1 to 0.25 ms when the machine is idle.  Read the ratio columns.)
The same code measured earlier at load 4 to 5 (`bench_broadcast.sql`, before the change): the scoreboard fill took 38 ms as a statement and **237 ms in the tick** (281 to 290 going
back to air), 64 whole sections 11 ms and 140 ms.  After the change, same method: statement 39 ms (to air; to stone about 5 ms more), tick 3.9 ms.

So the tick stalls for **3 to 9 ms instead of 240 to 320 ms** after a 100,000-block fill with a viewer, against vanilla's 240 to 290 ms of main-thread CPU for command and
broadcast together.  The cost did not disappear, it moved: the statement is 7 to 13% more expensive when it has to encode (a fill to stone; a fill to air barely changes,
the packet of state 0 is shorter), on the connection that runs it.  Total CPU of fill plus tick: before about 406 ms, after about 112 ms at the same load (at load 4 to 5: 275 ms before, 43 ms after), against vanilla's 650 to 765 ms across all threads (and 240 to 290 ms on its main thread alone).  **A fill issued from inside the tick** (there is no `/fill` command in dbcraft yet,
only SQL) would pay the encoding in that tick as before; the statement-time encoding is only a win for fills issued from outside it.

### What was done

1. **A section whose only event is one fill has a packet that is a function of (section, bit map, block)** (the order of vanilla's set depends on the bit map alone, the
   states are all the same block).  `sql/960_world_fill_encode.sql`: per bit map the order is simulated once (`mc.shortset_order`, about 1.5 us a position, 6 ms for a whole section)
   and written as a hex *template* (per entry two hex digits for the first byte, a marker and a digit for the second byte, a placeholder for the trailing bytes of the state) in
   `mc.sbu_tpl`, an unlogged cache of the newest 800 shapes; per block state three `replace()` passes fill in the state's bits and trailing bytes and `decode()` makes the bytes
   (0.09 ms for a 1,728-position section, 0.25 ms for a whole one, at load 3 to 4).  `translate()` would do two passes in one, but it is five times slower than `replace()`
   (0.3 against 0.05 ms for the 20 kB template of a whole section).  The result equals the original encoder byte for byte for every shape and every VarLong length class of the state id
   (0, 1 to 3, 4 to 511, 512 and up; `tests/sql/960`: 17 states x 10 shapes, and 80 random fills with and without a viewer at the time of the fill).
2. **The fill builds the packet itself when a connection can see the section** (`mc.fill`, `mc.block_event.pkt`, stored uncompressed): the tick copies bytes.  With nobody in range
   nothing is encoded (a viewer who arrives before the tick gets the packet built by the broadcast from the cached template, tested).
3. **A fill queues its events in one statement** (it used to insert one row per section, and the statement-level trigger of the entity wake-up ran after each: four statements, about
   0.1 ms, 48 times for the scoreboard fill).
4. **Whole sections: one UPDATE.**  A whole-section fill of a single-value section of another block changes every position, so nothing is read: one `UPDATE ... WHERE bits = 0 AND
   palette[1] <> block`, inline in `mc.fill` (and as the first step of `mc.fill_section_core`).
5. **The changed positions of a palette section are read off the words with masks and shifts** (4-bit entries: the per-field flags of a word are packed to 16 bits with four
   mask-and-shift steps, 256 words), instead of a loop over up to 4,096 positions (about 1.2 us each) that every fill into a section with partly matching content paid.

### Whole sections (item 2), `ab_fill.sql` against the original per-block-era fill, no player, CPU ms, load average 22

| scenario | original (per-block era) | now | now against original |
|---|---|---|---|
| one whole section | 5.57 (4.70 - 6.54) | 5.62 (4.72 - 6.44) | **1.00x**: recovered (0.31 to 0.33 ms against 0.42 to 0.46 ms measured quiet before this work, `docs/WORLD.md`) |
| 64 whole sections | 85.1 (80.2 - 93.6) | 30.3 (28.1 - 35.1) | 2.8x faster |
| 100,000 blocks | 671 (627 - 840) | 81.9 (79.6 - 91.6) | 8.2x faster |
| 1,000 blocks | 17.8 (16.3 - 21.0) | 10.7 (9.2 - 10.8) | 1.7x faster (4.3x in a run at load 10) |
| 16x1x16 floor | 13.9 | 10.5 | 1.3x |
| unaligned 40x40x40 | 490.8 | 75.5 | 6.5x |

The first version of this work (a `SELECT ... FOR UPDATE` then an `UPDATE`, through a function with a `SET` clause, and a per-chunk visibility query) measured 0.74x and
0.89x of the original in two runs; the inline `UPDATE`, one visibility query per fill instead of per chunk, and the one-statement event insert brought it to 1.00x.  I did not
get below the original's cost: the remaining statements (the dimension row, `canon_state`, the chunk row, the chunk version update, and the entity wake-up trigger's four
statements on the event insert, which belongs to the entity track) are the original's too.

## 2. Fill modes (`sql/961_fill_modes.sql`, `mc.fill_mode`)

`mc.fill_mode(dim, x1, y1, z1, x2, y2, z2, block, mode, filter)` with `replace [filter]`, `keep`, `outline`, `hollow`.  A filter is a block (`stone`: every state), a block with
properties (`oak_log[axis=x]`), or a tag (`#minecraft:logs`, nested tags resolved).  `destroy` is refused (drops and a break effect per block exist nowhere in dbcraft).
`mc.fill` keeps the default mode and its own loop.  The word-level fill (`mc.fill_section_core`) takes a list of states to replace: per word the fields that hold one of them are
found with the zero-field test, the write is masked to them, the counts follow from the same flags.  Shell modes are six disjoint slabs per box (and the inside as a seventh box
for `hollow`), the changed positions of a section's boxes are united into ONE event, so the packets are those of vanilla's single pass over the box (its set holds the
changed positions in x, y, z order, whatever the mode).  `hollow` puts two blocks in one section: its event is marked `'*'` and the broadcast reads the states from the section.
A section with a global palette goes position by position through `mc.edit_section`.

Checked against a reference that applies the same box position by position (x fastest, then y, then z) with `mc.set_blocks` in a second region (`tests/sql/961`): 24 random boxes
each for replace, replace with a block / properties / tag filter, keep, outline and hollow, with and without a viewer at the time of the fill, plus a whole-section case and a
section with a global palette: every block, every section's block and fluid counts and every packet (entries in order, with states) equal.  **Vanilla's own packets for these
modes were not recorded** (no byte-level comparison; `compare_fill.py` covers the default mode), and the speed of the modes against vanilla was not measured.
`mc.fill_mode` returns the number of blocks changed (vanilla's count); `mc.fill` still returns the blocks covered.

## 3. Terrain generation against vanilla

Measured the same way on both sides: CPU time of the whole server process tree while it generates a square of chunks (vanilla: `tests/bench/world2/vanilla_gen.py`, `/forceload` rectangles
of up to 256 chunks, each waited for, JVM threads from `/proc`; dbcraft: `tests/bench/world2/gen_cluster.py`, 80 x 80 chunks of `dbcraft:noise` through `mc.generate_noise_batch`,
CPU of the postmaster and every backend including the ones that exited, WAL writer and checkpointer included, plus a `CHECKPOINT`).

| | CPU per chunk | notes |
|---|---|---|
| **vanilla 26.3, real terrain** (default generator, structures on, seed 12345), 25 rectangles of 256 chunks = 6,400 chunks, one run to the end (run 4, load average 18 to 22) | **median 61.6 ms** (mean 68.6, min 52.0, max 104.0) over the 21 rectangles after the first four (5,376 chunks); the first four, with a cold JIT: 193, 102, 97, 106 ms | all JVM threads: generation workers, light engine, JIT, GC, the chunk IO thread; no player; `save-all flush` not measured |
| vanilla, an earlier run that was OOM-killed after 5 rectangles (run 1, load 6 to 7) | 140, 73, 85, 67, 67 ms | |
| **dbcraft, `dbcraft:noise`, whole Postgres cluster** | **8.08 ms** generation + 0.12 ms checkpoint (6,400 chunks, load average 11 to 13) | rows, light, the cached packet, WAL |
| dbcraft, generating backend only (`bench_terrain.sql`, 1,600 chunks, 3 rounds, load about 10) | 6.3 ms (5.9 - 6.3): rows 3.25, light 1.08, packet 1.97; fresh database: 5.15 ms at load 3 to 4 (`docs/WORLD.md`) | |

So dbcraft's cost per chunk is **7.6 times below vanilla's median 61.6 ms** (8.1 against 61.6; 6.3 backend-only; vanilla's real terrain has caves, ores, trees and structures where dbcraft's has none: **not the same
work**, which `docs/WORLD.md` says too).  Caveats on the vanilla figure: three earlier attempts were OOM-killed by the container's memory cgroup after 1 to 5 rectangles (1.0 to 1.8 GB resident; other workers' servers were killed as well),
the finished run shares the machine with a load average of 18 to 22 (CPU time is less sensitive to that than wall time, but not immune: the per-rectangle values scatter between 52 and 104 ms), and the JIT is still warming
over the first rectangles after the four counted as warm-up.  The dbcraft figure includes
persistence (WAL) and the packet, vanilla's does not include sending; vanilla's chunk files are written lazily (not measured).

**A bug found on the way, fixed: `mc.compute_light` took 0.6 to 1.8 s per terrain chunk on a populated database.**  Its `pl` CTE is referenced from a scalar subquery of `want`
(once per layer); the planner inlined it there and evaluated the whole window computation above it once per layer.  With the statistics of a database holding a few thousand
chunks and `plan_cache_mode = force_generic_plan` it chose that plan every time (EXPLAIN ANALYZE: `Function Scan on generate_series lay ... actual time=1812 ms`); on a fresh database
it did not, which is why `bench_terrain.sql` (fresh databases, scratch dimensions) measured 0.9 ms and nobody noticed.  Generating 6,400 chunks into a database with 700 chunks ran at about
1 chunk per second before the fix.  `pl as materialized (...)` (sql/220) makes it deterministic: 589 ms to 1.5 ms per chunk in the same database, light bytes unchanged
(tests/sql/240, 250 (real terrain, 49 captured chunks), 260, 270, 295 and 855 pass).  Every light recompute of an edited terrain chunk had the same exposure.

The generator itself (sql/855) was not changed: with vanilla at about 62 ms, shaving the noise (a profile of 400 chunks: 151 `t_vnoise` calls at about 5 us and 256 `t_hash` calls at
2 us per chunk, together 1.3 of the 3.2 ms of rows) would have been a few percent of 5 to 8 ms and each change needs the byte-identity tests of `tests/sql/855` to be re-argued.

## Verification

* `tests/e2e/compare_fill.py` against the real vanilla 26.3 server, re-run on the final code (fresh flat world on both sides, a connected client at the time of every fill, so the
  packets were the pre-built ones): **32 steps, 134 `section_blocks_update` packets (133,921 entries) and 4 `block_update` packets, ALL IDENTICAL.**
* `tests/sql/850`, `851`, `855` unchanged and green; `tests/sql/960` (32 checks) and `961` (36 checks) new.  The whole suite on the final tree (`prun.sh`, 2 jobs): 66 files, **2,333 checks, all pass**
  (`441_deflate_native` timed out once under load average 25 and passed when re-run alone, in the first full run); `check_overrides.py`, `check_inlining.sh` and `check_fresh_migration.sh` pass (output in `docs/perf-world2-results.txt`).

## 4. The scoreboard's edit rows, re-run (`tests/bench/world2/scoreboard_edit.py`)

Same statements and timing as `tools/scoreboard/run2.py scenario_blocks` (vanilla: RCON round trip; dbcraft: server-side statement time), V D V D alternated, 2 repetitions, one
database and one vanilla JVM for the whole run, **load average 13 to 17**, so every time below is 5 to 15 times what a quiet machine gives (vanilla's 100,000-block fill took 3.1 s here
against 201 ms in the original session; dbcraft's 188 ms against 42.8 ms).  Medians of the per-repetition p50, range in brackets:

| | nobody in range: vanilla | dbcraft | with a player in range: vanilla | dbcraft statement | dbcraft tick |
|---|---|---|---|---|---|
| single block edit (ms) | 4.34 (0.82 - 7.85) | 0.16 (0.15 - 0.17) | 34.1 (15.5 - 52.8) | 0.15 | 0.11 |
| fill 1,000 blocks (ms) | 20.3 (16.6 - 23.9) | 8.6 (5.5 - 11.7) | 35.7 (23.4 - 48.0) | 6.6 | 4.1 (1.0 - 7.2) |
| fill 100,000 blocks (ms) | 3,080 (2,252 - 3,909) | 188 (181 - 195) | 1,571 (1,300 - 1,843) | 182 | 14.5 (12.0 - 16.9) |

The ratios (dbcraft / vanilla) are 0.04, 0.42 and 0.06 without a player and 0.004, 0.19 and 0.12 with one, taken under the same load, alternated; they agree in direction with the original
scoreboard's rows (0.11, 0.14, 0.21) and I would not quote them to better than a factor of two.  The vanilla column mixes a cold JIT (the JVM was started shortly before) with the load;
the CPU-time measurements of section 1 are the better comparison for the large fills.  `docs/SCOREBOARD.md` keeps its original values and gets a dated note, not replaced numbers.

## What did not work

* **`translate()` instead of `replace()`** in the template fill: one pass instead of two or three, but 0.3 ms against 0.05 ms for the 20 kB template of a whole section (multibyte-aware per-character search).
* **A faster `mc.shortset_order`** (precomputed hash table, no duplicate test in the probe loop, tighter loops): 5% (2.83 against 2.99 ms for 1,728 positions, 5.93 against 6.09 ms for 4,096, results identical on
  60 random sequences).  The cost is the interpretation of about 15 PL/pgSQL statements per position (inserts and re-inserts of the doubling rehash), not the arithmetic; not applied.  A faster `mc.cells_positions` (one series instead of a cross join):
  0.95 to 0.68 ms for 1,728 positions; not applied (it would rely on the order of an aggregate without ORDER BY).
* **Set-based simulation of the hash set**: linear probing with insertion order is a sequential process (a later key whose home slot is free takes it, an earlier key that probed past it displaces nothing), and a round-based SQL formulation
  needs one statement per round; I did not find a loop-free formulation, so a shape's FIRST encoding still costs the simulation (about 1.5 us a position: 2.8 ms for a typical partial section, 6 ms for a whole one).
* **The vanilla comparisons under load**: every wall-clock vanilla number of this session is inflated by the load and the cold JIT; only main-thread and JVM CPU time are usable, and those only roughly (239 to 286 ms for the 100,000-block fill).
* **Vanilla terrain without OOM kills and load**: three of four attempts were killed by the memory cgroup (section 3); the one complete run shares the machine with a load average of 18 to 22.
* A first version of the A/B script ran for 30 minutes before I killed it; the CPU timer's 4 ms resolution had forced groups of hundreds of calls, which at that load took far longer than estimated.

## What is still a loss, or not done

* **The first fill of a shape costs what the tick used to pay**, now in the filling statement.  Measured (`cold.sql` pattern: empty template cache, one viewer, the scoreboard fill, load average 13): the first fill to stone
  271 ms of CPU (27 distinct shapes simulated for the 48 sections) and 12 ms in the tick; the same fill again to air 79.5 ms and 7 ms, to stone 88.7 ms and 2.3 ms.  So a cold fill's statement plus tick (about 283 ms)
  is still below the starting point's (statement about 80 to 90 plus tick 240 to 316 ms at similar load), and a repeated shape is 3 to 4 times cheaper; the saving of a cold fill is 20 to 30%, not the 35x of the tick alone.
  Only repeated shapes (the interior sections of a big fill, repeated fills) hit the cache.  A native function (the zlib accelerator's way) would make the first encoding about 100 times cheaper; not built.
* **A fill issued from inside the tick** pays the encoding there, as before (there is no `/fill` command in dbcraft; only SQL calls `mc.fill`).  The encode-at-fill-time design assumes fills come from other connections.
* A fill to stone is 7 to 13% more expensive as a statement when a player can see it (the encoding); a whole-section fill costs 1.00x of the original per-block-era fill, not less.
* **The speed of the fill modes against vanilla was not measured**, and vanilla's packets for them were not recorded.  `keep` and `replace <filter>` read every field of the box (about 0.4 ms a section); the 4-bit bit-map packing is fast, sections with
  5- to 8-bit palettes still read their changed positions with a loop (1.2 us a position).  `destroy` is not implemented.
* Vanilla without structures, vanilla's `save-all flush` for terrain, and dbcraft with several generator loops: not measured.
* `light_update` after block changes, `block_entity_data`, the order of sections of different chunks: unchanged from `docs/WORLD.md` ("Not verified").

## Reproduce

```
tests/bench/world2/make_head_impl.py                                   # frozen copies of the starting commit's fill/broadcast in schema bench_head
psql -X -d DB -f tests/bench/world2/head_impl.sql; psql -X -d DB -v rounds=5 -f tests/bench/world2/ab_world2.sql     # head against new, fill and tick, one viewer
psql -X -d DB -v rounds=9 -f tests/bench/world/ab_fill.sql                                                           # the per-block-era fill against the box fill (no viewer)
psql -X -d DB -v rounds=5 -f tests/bench/world2/bench_broadcast.sql                                                  # statement and tick per scenario, with and without a viewer
python3 tests/bench/world2/vanilla_fill.py --port P --rcon R --reps 7                                                  # vanilla, flat world, view distance 10, started by hand (see the file header)
python3 tests/bench/world2/vanilla_gen.py --rcon R --size 100                                                          # vanilla terrain: forceload rectangles, CPU per chunk
python3 tests/bench/world2/gen_cluster.py --port P --db DB --pgdata DIR --size 80                                      # dbcraft noise terrain, whole-cluster CPU per chunk
python3 tests/bench/world2/scoreboard_edit.py --db DB --dbport P --repeat 2                                            # the scoreboard's edit rows, V D V D, with and without a viewer
python3 tests/e2e/fill_probe.py ...; python3 tests/e2e/compare_fill.py V.json D.json                                    # byte comparison with a real vanilla server (tests/e2e/README.md)
```
Raw output of this session: `docs/perf-world2-results.txt`.
