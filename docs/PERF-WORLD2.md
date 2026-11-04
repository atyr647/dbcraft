# World track 2: fills with a player in range, whole sections, fill modes, terrain against vanilla

Scope (the losses and never-compared items of the world side): (1) what a large fill costs the tick when a player can see it, **measured against the real vanilla 26.3
server for the first time**; (2) the whole-section fill cost that had regressed (0.31 to 0.42 ms) and the `/fill` modes, which had no SQL counterpart; (3) terrain
generation (`dbcraft:noise`) against vanilla generating real terrain; (4) the scoreboard's edit rows for the record.  Everything client-visible stays byte-identical:
`tests/e2e/compare_fill.py` against a real vanilla server was re-run on the final code (see "Verification").

## How the numbers were taken, and why most of them are not clean

**The machine was not quiet, and got worse while I worked.**  4 cores shared with about 8 other workers; the load average was 4 to 5 at the start, 10 to 26 for most of the
measurements below, and the container was restarted once.  Absolute times in this document therefore differ by factors between runs (the same A/B run at load 5 and at load 25
shows a whole-section fill at 0.9 and 5.6 ms of *CPU* time); **only the ratios inside one interleaved run mean something, and every table says at which load it was taken.**
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
CPU, and the packets reach the client in the tick after the command (about 15 ms later in the first run), so the client sees the change after command + tick.

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
the packet of state 0 is shorter), on the connection that runs it.  Total CPU of fill plus tick: before about 320 to 410 ms, after about 110 ms at the same load (about 45 ms
at load 4 to 5), against vanilla's 650 to 765 ms across all threads (and 240 to 290 ms on its main thread alone).  **A fill issued from inside the tick** (there is no `/fill` command in dbcraft yet,
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

(see below)

## Verification

* `tests/e2e/compare_fill.py` against the real vanilla 26.3 server, re-run on the final code (fresh flat world on both sides, a connected client at the time of every fill, so the
  packets were the pre-built ones): **32 steps, 134 `section_blocks_update` packets (133,921 entries) and 4 `block_update` packets, ALL IDENTICAL.**
* `tests/sql/850`, `851`, `855` unchanged and green; `tests/sql/960` (32 checks) and `961` (36 checks) new.

## What did not work, what is still a loss

(see below)
