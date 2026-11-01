# Chunk performance: generation, packaging, caching, joins, edits, compression

Scope: everything between "the world needs a chunk" and "the bytes leave for the client", in SQL, without leaving the project's goals: the world stays rows in
the Minecraft wire format, derived data is a cache that can be rebuilt from the rows, all logic is SQL, the gateway stays a byte pipe, and the bytes stay
identical to vanilla (the oracle tests are the guard).  Branch work on top of the integration merge; the suite went from 724 to 874 checks, all green.

## Result against the targets

| Target | Before | After (median of 5, machine loaded) | Verdict |
|---|---|---|---|
| generate + package an unvisited flat chunk <= 0.5 ms | 9.2 ms + 3.1 ms | **0.35 ms** (min 0.14); the packet comes with it, a cold packet read is 0.02 ms | met |
| first-time join at view distance 10, unexplored world <= 300 ms | 7,381 ms | **73 ms** (min 69) | met |
| the tick must not generate chunks | it did (358 ms ticks for 500 players on an unexplored world) | `async` mode: the tick never generates; proven by `tests/sql/430` | met (opt-in, see below) |
| cached packet read <= 10 us | 37 us | **10.8 us** (min 10.4; 8.3 us in a quieter run) | met on a quiet machine, borderline when loaded |
| `set_block` <= 0.2 ms | 538 us | **0.25 ms** median (min 0.23; 0.20 in a quieter run); 3.3x faster with pgbench, one edit per transaction | close, not met under load |
| 10k edits across 100 sections "well inside a tick" | 208-275 ms | **189 ms** (min 177) | **not met** |
| (stretch) chunk compression in SQL, verified | raised an error | works; flat chunks free, terrain 2.2x at 22 ms | met as a stretch; ratio is weak on real terrain |

Numbers were taken on a 4-core container shared with other benchmark jobs (load average 2.7-3.4), so single runs vary by up to 2x; the "before" numbers were
taken once at a lower load (about 1.8), which makes the improvements conservative.  `tests/bench/world/median_perf.py` repeats the benchmark and prints median,
min and max; quote the load next to any number.

## What was built

### 1. Template generation (`sql/245_world_gen.sql`)
Every flat chunk of a dimension is the same except for its two coordinates.  The reference generator (`mc.generate_flat_slow`, unchanged, checked against
vanilla by `tests/sql/240`) builds ONE chunk in a scratch dimension, whose rows and packet are kept in `mc.gen_template` (a derived cache).  Generating N chunks
is then one set-based `INSERT ... SELECT` that copies the template's section and light rows, and the cached packet is the template packet with the 8 bytes of
coordinates replaced.  `mc.generate_flat(dim, cx, cz)` now takes the fast path; `mc.generate_flat_batch` takes lists.
* The template is invalidated by triggers (layers, dimension shape, biome registry) and by a cheap stamp (generator version, block state count, packet id).
* `mc.generator` registry + `mc.generate_batch` dispatcher: a heavier terrain generator plugs in by inserting a row (a function `(dimension, cxs[], czs[])`).
* Proof (`tests/sql/260`, 38 checks): rows and packets identical to the reference, also at coordinates around +-2,000,000, with edits, replace, template
  invalidation, concurrent-safe `ON CONFLICT DO NOTHING`, and no scratch dimension left behind.

### 2. Lock-free cached read (`sql/230_world_chunk.sql`)
`mc.chunk_packet` used to take a `FOR UPDATE` row lock on every call (inside `mc.ensure_chunk_current`).  It is now one index lookup (chunk + cache joined on the
version) and falls through to `mc.chunk_packet_build` for anything else.  Note for everyone writing SQL here: **a LANGUAGE sql function that cannot be inlined is
re-planned on every call** (0.5 ms for this one); PL/pgSQL keeps its plans.  My first SQL-language version was 3x slower than the old PL/pgSQL one for exactly that
reason, found with `EXPLAIN ANALYZE` (execution 0.02 ms, planning 0.5 ms).

### 3. The generation queue (`sql/430_chunk_queue.sql`)
* Setting `dbcraft.chunk-generation`: **`inline`** (default) generates what a player needs inside the call that needs it (now cheap), exactly the behaviour the
  integration tests were written for; **`async`** puts missing chunks on `mc.chunk_request` and the tick never generates.
* `mc.chunk_request` (one row per chunk, priority = squared distance of the nearest requester) is drained by `mc.generate_pending(n)` with
  `FOR UPDATE SKIP LOCKED`; any number of loops (`call mc.run_generator()`) can run in parallel, each its own connection.  A request nobody waits for any more
  is dropped without generating; a generator that keeps failing is dropped after 3 attempts and logged, without blocking the queue.
* `mc.chunk_wanted` records what each connection was promised; `mc.deliver_ready_chunks()` (called from `net.stream_chunks`, tick step 6) sends the ready ones,
  nearest first, as one `chunk_batch_start .. chunk_batch_finished` group per connection, at most `dbcraft.chunk-batch-max` per tick.  Wants of connections that
  left or whose view moved away are dropped.  Vanilla paces 9, 20, 20 chunks by the client's `chunk_batch_received` replies; any batch sizes are valid for a client
  and this layer does not use those replies for pacing yet.
* `net.hook_chunks` is now set-based (it called three per-chunk functions 529 times); `net.stream_chunks` is replaced by a version that wants and delivers.
* Proof (`tests/sql/430`, 70 checks): an async join sends no chunk from the tick; chunks arrive as they are generated, **byte-identical and in the same order as inline
  mode**; border crossing, pacing, clean-up, failure isolation, the generator loop and its stop flag.
* `tests/bench/world/parallel_generate.sh`: 1 to 4 loops over one queue always make every chunk exactly once (3,000 chunks: 5,950 / 6,970 / 7,380 / 7,710 chunks/s).
  The 1.3x speedup from 1 to 4 loops is **not** a reliable scaling figure: the 4 cores were shared with other jobs.

### 4. Faster edits (`sql/210_world_blocks.sql`)
* `mc.set_block` has a dedicated path for the common case (the section exists, is a palette section, and the palette holds the block or can grow within its bit
  width): the section read (with lock), the section write, ONE `UPDATE ... RETURNING` on the chunk that also returns the one column's heightmap values, and the event
  row, instead of a dozen statements.  Anything else (new section, bit-width change, bare block name, unknown name) goes to `mc.edit_section`, which handles it and raises
  the errors.  3.3x faster measured with pgbench, one edit per transaction (0.8-0.9 ms -> 0.25-0.28 ms at the client, including the round trip).
* `mc.edit_section`: names canonicalised in one set-based statement (it used to call a SQL-language function per name, 60 us each, replanned every time); a
  single-value section becomes a palette section by starting from zero data instead of unpacking and repacking 4,096 entries (`pack_longs` was 750 us per section);
  heightmap flags are computed once per distinct state and skipped entirely for edits below every column top (most edits inside terrain).
* Proof (`tests/sql/270`, 19 checks): the same ~4,000 pseudo-random edits through `set_block` and through `edit_section` leave identical sections (palette, bits,
  packed data, counts), identical chunk rows (versions, flags, the three heightmaps) and identical events in order, including growth past 16 palette entries (4 -> 5
  bits), new sections, blocks above the surface and non-collidable blocks; the incremental heightmaps equal a full recompute; the chunk packets are identical.

### 5. DEFLATE in SQL (`sql/440_deflate.sql`, stretch)
`net.deflate_frame` (the hook the net layer calls for packets at or above the compression threshold, which used to raise) is implemented: Adler-32 and its
combine formula, a fixed-Huffman DEFLATE encoder with run-length matches, zlib framing, `mc.chunk_cache.packet_z`.
* A flat chunk is not compressed at all at generation: the template packet is compressed once as `[stored block: packet id + coordinates][fixed block: the rest]`
  and a chunk's frame is that with its own 9 bytes and a combined Adler-32.  **Generating with compression on costs the same as off (0.49 ms vs 0.49 ms).**  A flat
  packet of 7,262 bytes becomes 1,095 bytes (6.6x).
* An edited or terrain chunk uses the general encoder (2.9 ms for a flat packet, **22 ms per real terrain packet**, 2.3 MB/s) and the result is cached with the chunk.
* **Real terrain compresses only 2.2x** with this encoder, against 5.25x for zlib level 6 on the same packets (`tests/bench/world/zlib_baseline.py`).  My earlier estimate
  of "85-95% of zlib" (docs/COMPRESSION.md) came from synthetic chunks and was wrong for real ones; it is corrected there.
* Verified by real inflaters, not by round trips through my own code: **Python's zlib** (`tools/zlib_check.py`, via `tests/sql/280`) and **Java's `Inflater`**
  (`tests/bench/world/inflate_java.sh`, the inflater the client uses): 95 streams, among them the 49 real vanilla terrain packets, spliced flat frames, an edited
  chunk, runs of every length around 258, all 256 byte values, an empty input, and frames with 3-byte VarInts: **95/95 accepted by both**.  The wire frame is
  `[packet length][data length][zlib stream]`.
* It found a real bug while being wired in: `net.reframe` (sql/420) called `perform net.deflate_frame(0, payload)` as a placeholder that was meant to raise; with a real
  implementation `perform` discards the result and appended nothing, so large frames to compressed connections would have been **silently dropped**.  Fixed (it now
  appends the compressed frame and splits off the packet id so the chunk cache is used).

## What failed, and what I got wrong (kept in the history on purpose)
* **A leaner `edit_section`** (read the chunk row inside the version-bump `UPDATE ... RETURNING`, skip the dimension read, conditional chunk insert) was **not faster**: slightly
  slower in an interleaved A/B, because in this workload most sections need a heightmap change and the second write cost more than the saved read.  Reverted.
* **First benchmarks were wrong in three ways**, all caught and fixed: constant-folded `IMMUTABLE` calls (the earlier session's lesson, repeated in my own micro-benchmarks);
  a clock-derived chunk region that made consecutive runs overlap (later runs "regenerated" nothing and read chunks earlier runs had edited); and an "edit + rebuild"
  loop that edited 500 chunks when only 200 existed, so 300 edits created chunks from scratch.  The honest edit + rebuild of an existing chunk costs about **4-5 ms**.
* `pg_stat_statements` with nested tracking inflates per-statement costs and distorted early comparisons; the figures above were taken with it off.
* The event queue's primary key (`mc.block_event`) is not the bottleneck (about 0.6 us per row).

## What remains
* **Batch edits.** `mc.set_blocks`/`edit_section` cost about 1 ms per touched section plus 4-5 us per edit (statement overhead per section, not per edit), so 10k edits in
  100 sections is still about 190 ms.  Fixing it needs a set-based rewrite across sections (compute the new packed words, counts and heightmap changes with SQL over all
  edits at once).  `mc.fill` already replaces whole sections without unpacking.
* **Rebuild of an edited chunk** (4-5 ms): `sky_layer` is a 2,048-row string aggregation (0.8 ms per partial layer) and the body assembly calls small functions per palette
  entry; both can be made much cheaper and are covered by the oracle tests.
* **Compression ratio on real terrain.** 2.2x vs 5.25x.  Closing the gap needs longer-distance matches and dynamic Huffman codes: possible in SQL, expensive (22 ms per
  packet already); a **minimal native `deflate(bytea)` function would give 5x at about 1.5 ms** and is the obvious accelerator if terrain bandwidth matters.  I did not
  build it: the SQL path works and is verified, which is what the constraint asked for.  Per-section fragments (compress only the section that changed) are not built.
* **Pacing by the client's `chunk_batch_received`** is not used; the batch cap is a fixed setting.
* **Streaming for compressed connections** relies on the cache lookup in `net.deflate_frame`; chunks cached before compression was switched on are filled by
  `mc.backfill_chunk_z` (not scheduled automatically).
* The generation queue is in `async` mode only when the setting says so and a generator loop runs; the dev gateway does not start one yet.

## Changes to files outside the 2xx range (for the merge)
* `sql/420_integration_tick.sql`: `net.reframe` over-threshold branch (the silent-drop bug above), 6 lines.
* `sql/430_chunk_queue.sql` **replaces** `net.hook_chunks` (from sql/400) and `net.stream_chunks` (from sql/410) with `create or replace`; anyone editing those two in
  the 4xx files must edit the 430 versions (a later file wins).
* `tests/sql/135_net_compression.sql` and `tests/sql/420_integration_behaviour.sql` asserted the OLD behaviour ("deflate raises" / "the connection is closed") and now
  assert compression instead.

## Running it
```
tests/sql/run.sh                                   # 874 checks (DBCRAFT_TESTDB=name to keep databases apart)
python3 tests/bench/world/median_perf.py DB 5      # the timings above (PGHOST/PGPORT/PGUSER for psql)
tests/bench/world/pgbench_set_block_overworld.sql  # one edit per transaction, pgbench
tests/bench/world/parallel_generate.sh DB 3000 4   # several generator loops, exactly-once check
psql -d DB -f tests/bench/world/perf_deflate.sql   # compression cost and ratio
tests/bench/world/inflate_java.sh                  # after tests/sql/280: Java's Inflater over the same streams
python3 tests/bench/world/zlib_baseline.py         # zlib's ratios on the real terrain packets
```
