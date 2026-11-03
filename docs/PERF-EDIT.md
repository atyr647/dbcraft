# Edits and chunk rebuild: what was measured, what changed, what did not work

Scope: the two items `docs/PERF-CHUNKS.md` left open ("batch edits", "rebuild of an edited chunk"), in SQL, with byte-identical output.
Everything below was measured on the shared 4-core development machine while three other workers were running (load average 2.5-4.8), PostgreSQL 16, `jit = off`.

## How the numbers were taken (read this first)

* **CPU time, not wall-clock.** `tests/bench/edit/cpu_timer.sql` defines `bench.cpu_ms()`: the time the backend has spent on a CPU (`/proc/self/schedstat`).
  Wall-clock timings of the same loop varied 2x from one minute to the next; CPU time varies about +-25% and, more importantly, A and B see the same noise.
  It is **quantised to scheduler ticks (about 4 ms)**, so a loop shorter than about 50 ms is only good to +-10%.
* **A/B interleaved.** `ab_rebuild.sql` and `ab_batch.sql` run the original implementation and the new one on identical chunk sets in the same session, alternating the order every round,
  and report median / min / max and the median of the per-round ratio.  The originals are frozen copies in schema `mc_old` (`old_impl.sql`, generated from commit `971e8cb` by `make_old_impl.py`).
* Single runs still differ by up to 40% between minutes; where two runs exist both are given.
* `tests/sql/290_world_batch.sql` and `295_world_rebuild.sql` prove identical results; the whole suite is **919 checks** (874 before).

Reproduce (needs a database with the schema loaded; `tests/sql/run.sh` builds one):

```
psql -X -d DB -f tests/bench/edit/old_impl.sql -f tests/bench/edit/exp_setbased.sql      # the reference copies and the archived experiment
psql -X -d DB -v rounds=9 -f tests/bench/edit/ab_rebuild.sql                              # rebuild after edits, old against new
psql -X -d DB -v rounds=7 -f tests/bench/edit/ab_batch.sql                                # batched edits: old, new, set-based experiment
psql -X -d DB -f tests/bench/edit/single_edit.sql                                         # one edit / one read per call
psql -X -d DB -f tests/bench/edit/profile_rebuild.sql                                     # where the rebuild time goes (wall-clock; also profile_body/s3/light/build_path)
```

## A bug found on the way (fixed): sections created by a few edits stored twice the data

`mc.edit_section` turns a missing or single-value section into a palette section by zero-filling `((4096 + vpl - 1) / vpl) * 16` **hex-pair repeats**: `repeat('00', k)` is `k` bytes, a long is 8,
so the section kept **4,096 bytes instead of 2,048 at 4 bits** (every width: twice the longs).  The many-edits path rebuilt the data from the unpacked longs and hid it; the few-edits path
(48 edits or fewer into a missing or single-value section: a block placed in an empty section) kept the extra half.  A client reads a fixed number of longs per container, so the chunk packet of
such a section is unparsable.  The end-to-end tests only edited the flat world's existing section, so nothing noticed.  Fixed in `mc.edit_section_core` (`* 8`); regression checks in
`tests/sql/290_world_batch.sql` (every section has exactly `ceil(4096 / (64 / bits)) * 8` bytes; a section created by two single edits has 2,048 bytes).
**An existing database may contain such sections.**  The extra bytes are zeros at the end, so trimming repairs them (then bump the chunk versions so cached packets are rebuilt):

```sql
with fixed as (
  update mc.chunk_section s set data = substring(data from 1 for e.expected)
    from (select dimension, cx, cz, sy, ((4096 + (64 / bits) - 1) / (64 / bits)) * 8 as expected from mc.chunk_section where bits > 0) e
   where s.dimension = e.dimension and s.cx = e.cx and s.cz = e.cz and s.sy = e.sy and octet_length(s.data) > e.expected
  returning s.dimension, s.cx, s.cz)
update mc.chunk c set version = c.version + 1 from (select distinct dimension, cx, cz from fixed) f where c.dimension = f.dimension and c.cx = f.cx and c.cz = f.cz;
```

## 1. Rebuild of an edited chunk (done: 2.5x to 5.7x faster)

CPU time per `mc.chunk_packet` call right after the edit, 40 chunks per round, median of 9 rounds (two runs shown: load 4.75 / load 3.1):

| After ... | original | new | speed-up | target |
|---|---|---|---|---|
| one edit below the surface (light inputs unchanged) | 3.19 / 4.08 ms | **0.60 / 0.96 ms** | 5.7x / 4.3x | <= 1 ms: met |
| one edit above the surface (heightmap and light change) | 3.51 / 3.94 ms | 1.17 / 1.39 ms | 3.0x / 2.9x | |
| 1,000 random edits (4 sections, 5 sky layers) | 7.68 / 7.80 ms | 2.88 / 3.30 ms | 2.5x / 2.5x | <= 3 ms: borderline |

Where the 4.5 ms went (wall-clock profile of one rebuild, `profile_rebuild.sql`, load 4) and what became of it:

| piece | before | after | what changed |
|---|---|---|---|
| `compute_light` after an edit that did not move the surface | 1.0 ms | 0.02-0.04 ms | **light cache key**: `mc.chunk.light_ws / light_top` remember the two inputs of light (the WORLD_SURFACE heightmap, the highest non-empty section); equal inputs and the right number of rows: nothing to do |
| `heightmaps_wire` | 1.04 ms | 0.09 ms | three plpgsql packing loops (256 steps each) became one grouped `bit_or` aggregate over the three arrays |
| `light_wire` | 0.84 ms | 0.03-0.05 ms | one pass over the light rows (masks with `bit_or`, arrays with `string_agg ... FILTER`) instead of eleven scans and four plpgsql bit-set builders; falls back to the old code above 62 layers |
| `section_wire` (1 stored section) | 1.05 ms | 0.04-0.09 ms | two lookups instead of a chain of small SQL functions (0.15 ms); **hash index on `ref.block_state(name)`**: a probe costs 7 us instead of 30 us (the btree pays a locale-aware comparison per level) |
| `chunk_packet_body`, all of it (flat chunk) | 2.1 ms | 0.24-0.48 ms | the pieces above, one lookup of chunk and dimension, empty-section bytes built inline |
| `block_entities_wire` | 0.28 ms | 0.005 ms | `exists` check first |
| `sky_layer`, one partial layer | 0.64 ms | 0.03 ms uniform / 0.2-0.3 ms general | uniform surfaces (flat worlds) need no per-column work; otherwise lit columns are kept as four 64-bit masks per row and turned into hex with `translate` |
| `ensure_chunk_current` after 1,000 edits (light of 5 layers, 4 of them partial) | 2.4 ms (4 general layers at 0.32 ms each inside it) | 1.4-1.9 ms | all partial layers in one statement (columns grouped by surface height once, cumulative mask per absolute level); only layers whose rows differ are written.  This is what keeps the 1,000-edit rebuild at about 3 ms: a general `sky_layer` is still 0.2-0.3 ms and the statement plus the row writes cost the rest |
| planning | 1.26 ms (custom plans) | 0.47 ms | `set plan_cache_mode = force_generic_plan` on the rebuild functions: the statements are planned once per session, not on every call.  Not applied to `chunk_packet` (the cached read, about 11 us) or `mask_wire`, where the per-call cost of a function-level setting would show |

Equivalence: `sky_layer` against the original on 2,800 random heightmaps (uniform, two-level, smooth, random, extremes 0 and 384, bases that are not multiples of 16);
whole chunks after eight edit stages (below/above the surface, 3,000 random edits, tops lowered, a high section filled and emptied, a block entity, a global-palette section): light rows,
packet bodies and `section_wire` identical in all eight chunks every time.  The 49 real flat and 49 real terrain chunks of the oracle tests (`240`, `250`) are still byte-identical.

Not changed: how well the light matches vanilla (76% of layers; still sky light straight down only).

## 2. Batched edits (partly done: 1.4x to 2.4x faster with many sections, parity with one section; the stated targets are NOT met)

CPU time per `mc.set_blocks` call, median over 7 rounds (`ab_batch.sql`; "experiment" = the set-based version described below):

| scenario | original | **new** | speed-up | set-based experiment | target |
|---|---|---|---|---|---|
| B1 10,000 edits in 1 section | 76 ms (52-88) | 84 ms (43-88) | 1.0x | 140 ms | <= 10 ms: **not met** |
| B2 10,000 edits over 100 sections | 164 ms (146-219) | **107 ms** (92-180) | 1.6x | 188 ms | <= 40 ms: **not met** |
| B3 10,000 edits over 1,000 sections | 595 ms | **275 ms** | 2.4x | 614 ms | |
| B4 1,000 edits over 10 sections | 15.9 ms | 11.6 ms | 1.5x | 55 ms | |
| B5 12 edits over 3 sections (per call) | 3.6 ms (1.5-5.8) | 1.7 ms | 1.7x | 7.6 ms | |
| B6 100 edits over 4 sections (per call) | 2.2 ms | 2.4 ms (1.4-2.6) | 1.4x by the per-round ratio; the medians are inside each other's noise | 7.4 ms | |

(An earlier, shorter run of the same script: B1 52 vs 60 ms, B2 127 vs 160, B3 216 vs 528, B4 8 vs 16, B5 1.4 vs 2.8.  The spread between runs is about +-30%; B4 and B5 are quantised to 4 ms.)

What the new `mc.set_blocks` (sql/290) does differently from the original loop, which called `mc.edit_section` for every section (a dozen statements each, about 0.5 ms per section):

* the dimension and the block names are resolved once per batch;
* `mc.edit_section_core` (split out of `mc.edit_section`, which now calls it and behaves as before) reads, edits and writes a section: two statements;
* the chunk row is read and written once per chunk (version += changed sections, dirty, heightmaps), with the heightmaps kept in local arrays while the chunk's consecutive sections are processed;
* heightmap rules are applied inline per change (three function calls per change before), the rescan after a removed top still uses `mc.column_top`;
* all events are queued by one insert at the end, in the original order (identical ids order, `old_state`, `new_state`);
* in the two same-width loops of the core, names, palette positions and flags are looked up once per distinct name and the old block's flags once per palette entry, instead of four array searches per edit.

### What did not work: the set-based rewrite (kept as `tests/bench/edit/exp_setbased.sql`, schema `mc_exp`)

I wrote the pass the task asked for first, verified it against the original loop (it passes the same 27 checks) and measured it: **slower than the loop at every size except 1,000 sections**.
It computes everything for all edits at once: a window function (`lag`/`lead` over the position) makes repeated positions behave like sequential edits; per word the edited entries' masks and
values are OR-ed with `bit_or` and the old bytes are spliced; widths that grow are recomputed for all 4,096 entries of the section and packed with a grouped aggregate; heightmap candidates per
column come from the net effect on each position.  Lessons, in the order they cost time:

1. **The planner cannot size a CTE chain.** After two joins its estimate collapsed to "1 row", so it chose nested loops that re-ran whole sub-plans for every row: 700 ms for 500 edits in 100 sections.
   Fix: statements that only join CTEs run with `enable_nestloop = off` (transaction-local `set_config`, restored afterwards); everything that must read a big table (stored sections, chunk rows) is read in a
   separate statement and passed as an array of rows; name and state-id lookups are per-row index probes in scalar sub-queries, never joins (a join would hash the 35,723-row table).
2. **JIT.** `enable_nestloop = off` adds a huge penalty to the cost of any cross join; that pushed the estimated cost over `jit_above_cost` and PostgreSQL compiled 321 functions on every call: 4-5 seconds
   of fixed cost, independent of the batch size.  The function now sets `jit = off` (the repository's tick settings already say so; a default install has it on).
3. **Wide rows through a sort.** A window function over rows that carried each section's 4 KB base data copied megabytes and spilled to temp files; computing the window on the narrow rows and joining the data afterwards fixed it.
4. **Per-row cost of the executor.** After all that: about 10 us per edit in the main statement (fifteen materialised nodes at 0.3-0.5 us per row each) against about 5 us per edit for the PL/pgSQL loop.
   More joins, sorts and aggregates cannot beat a loop that touches each edit a few times.  Fixed cost was 15-20 ms per call (planning thirty CTEs), which is why 12 edits took 18-23 ms.
   In its favour: it scales with sections (B3: 0.05 ms per section against 0.5 ms), and it needs no state between sections.  Not enough.
5. A lean loop was the better design for this machine and this language; PostgreSQL's executor is the wrong tool to run a 4,096-entry bit-packing update for 10,000 edits faster than a tight loop.

### Why the stated targets are out of reach in PL/pgSQL

10,000 edits in 40 ms is 4 us per edit **including** the 1.5-2 us the event insert costs (an unlogged table with an identity primary key; `docs/PERF-CHUNKS.md` measured about 0.6 us for the index alone),
the 3-4 us of the core loop, and the heightmap work.  The remaining levers I did not pull because they change behaviour or need other modules:

* queue one event per section instead of one per block when a batch changes more than a few dozen blocks of a section (vanilla sends a section update packet there anyway): removes the
  event insert from large batches (about 20 of the 52 ms of B1) but changes what the tick receives, so the net layer's handling has to be adapted and byte-compared first.
  **Done for `mc.fill`, not for `mc.set_blocks`** (docs/WORLD.md "Block change packets" and "Large fills": a fill queues one `cells` event per section, the broadcast sends
  `section_blocks_update` byte-identical to vanilla's, 100,000 blocks went from 470-490 ms to 37-39 ms).  `mc.set_blocks` still queues one row per block;
  the broadcast already turns those into section packets, so queueing a bit map from the batch would be the same change here;
* a native helper for the per-word bit surgery (excluded by the project rules for this task);
* batch the chunk-row and section-row updates of all sections in one `UPDATE ... FROM unnest(...)` after the loop (saves the per-section write statement, about 80 us each: B3 would gain about 80 ms).

## 3. Single edit (`mc.set_block`): not changed

`single_edit.sql`: 4,000 random edits over 100 flat chunks, **230-330 us of CPU per edit** in the first round (the target was 200 us; the previous worker measured 250 us under load), reading a block 30-40 us.
Later rounds of the same run get slower (up to 450-600 us) because the whole script runs in one transaction and the row-version chains of the hot rows grow; a tick commits, and the numbers there are the first-round ones.
The new light cache key makes every chunk row about 500 bytes larger and every edit rewrites that row; comparing runs with the key populated and with it nulled showed **no difference beyond the noise** (+-30%).
I found no cheap win in the six statements of the fast path; the cost is statement overhead, which is what the lean batch avoids for many edits.

## Files

* `sql/200_world.sql` (cache key columns, upgrade block, hash index), `210_world_blocks.sql` (`edit_section_core`, `edit_section`, data-length fix), `220_world_compute.sql` (`sky_layer`, `compute_light`),
  `230_world_chunk.sql` (wire helpers, `chunk_packet_body`, generic plans), `245_world_gen.sql` (template copies the key; `gen_version` 3), `290_world_batch.sql` (`set_blocks`).
* `tests/sql/290_world_batch.sql` (27 checks), `295_world_rebuild.sql` (18 checks).
* `tests/bench/edit/`: the scripts above, `old_impl.sql` (generated), `exp_setbased.sql`.

An existing database picks up the two new `mc.chunk` columns when `sql/200` runs again: the block drops `mc.gen_template` first (a derived cache holding `mc.chunk` rows, which blocks `ALTER TABLE`; sql/245 recreates it and it is rebuilt on first use).

## Caveats

Load from other workers throughout; CPU time removes the scheduling noise but not cache and memory-bandwidth contention.  Single numbers are +-30%; the ratios (same session, interleaved) are the evidence.
The rebuild numbers use flat chunks (one stored section at the start); chunks with many stored sections and big palettes spend more in `section_wire`.
The 1,000-edit scenario uses 4 sections and block states from a pool of 6.  Heightmap `MOTION_BLOCKING` accuracy is as before (name-based approximation).
