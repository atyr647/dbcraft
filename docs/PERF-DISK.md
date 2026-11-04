# Disk size of the world

The loss this document closes: the scoreboard said a 10,000-chunk flat world is 82.5 MiB in dbcraft against 62.1 MiB for vanilla's region files (1.33x).  Re-measured on
the tree this work started from (commit 046d1e2): **92.6 MiB, 1.49x**, because the tables had grown a column and a cache since.  After the change below it is **16.1 MiB,
0.26x of vanilla**.  Real terrain was worse than flat and is now better than vanilla's whole world folder, with one caveat about the chunk packet cache (below).

Everything here was measured on the 4-core development machine, which other agents were using (load average 6 to 20 through the session), on a PostgreSQL 16.15 cluster
in `/dev/shm`, `jit = off`.  Sizes are deterministic; timings are CPU time of the backend (`/proc/self/schedstat`), alternated A/B, medians with the range of all
repetitions, and still carry about 10% noise.

## 1. What was measured, and how vanilla was measured

| World | dbcraft before | vanilla | how |
|---|---|---|---|
| 10,000 flat chunks (the scoreboard's `world10k`: generate, then size) | 92.63 MiB (`pg_total_relation_size` of `mc.chunk`, `chunk_section`, `chunk_light`, `chunk_cache`, `block_entity`; the scoreboard's own query) | **62.09 MiB** (65,108,563 bytes, `du -sb world` after `save-all flush`, the recipe of `tools/scoreboard/run2.py`, re-run today) | vanilla 26.3.jar, `level-type=flat`, `forceload` of 100 x 100 chunks |
| 2,000 chunks of `dbcraft:noise` (50 x 40, seed 0) | 46.59 MiB | no vanilla world has this content: **7.84 MiB** is dbcraft's own export (`tools/world_export.py`, zlib level 6 like vanilla's Java deflater, 2,000 chunks of 1,081 bytes, one 4 KiB sector each) | an upper bound of what vanilla would need to store the same blocks |
| the imported vanilla world (780 full chunks, `tests/world_import`) | 43.93 MiB (no packet cache yet), 54.45 MiB once every chunk has been sent once | **17.08 MiB** is the whole folder (`region` 16.4 MiB, `entities` 0.46, `poi` 0.17); **7.23 MiB** is only what the 780 full chunks occupy (their sectors, entities, poi) | `du -sb` and a reader of the region headers (`status` of every entry) |

Which vanilla number is the fair one, per world:

* **Flat**: the whole folder.  Vanilla needed 15,876 chunk entries for the 10,000 forced chunks (10,816 `full`, the other 5,060 are `structure_starts`, `biomes`,
  `initialize_light` and `terrain` stages of the border it generated), each in a 4 KiB sector, although a full flat chunk is only **555 bytes** of zlib.  There is no `entities` or
  `poi` folder in the world (nothing in them).  So its floor is **4,096 bytes per chunk** whatever the content; dbcraft now needs **1,692 bytes per chunk**.
* **Imported terrain**: both.  The whole folder (17.08 MiB) carries 2,175 unfinished neighbour chunks that dbcraft never imports (the importer takes `full` chunks only); the 780
  full chunks alone take 7.23 MiB (8,959 bytes per chunk, sector padded; 6,864 bytes of zlib).  dbcraft's rows are compared with both below.
* **Noise terrain**: the export (above) is a lower bound for vanilla, and vanilla's real terrain chunks are bigger (the imported world's are 6.9 KB of zlib, a noise chunk has no caves,
  ores, trees or structures), so the honest range for "what vanilla would store" is 4,096 to about 9,000 bytes a chunk.

## 2. Where the bytes went (before)

Per chunk, including the indexes, flat world (10,000 chunks), bytes:

| Table | Before | Why |
|---|---|---|
| `mc.chunk_section` (1 row) | 4,162 | the section is 2,285 bytes uncompressed (`toast_tuple_target = 8160`: nothing is ever compressed), and with fillfactor 70 two rows fill a page: 4,096 bytes of page for 2,285 of row |
| `mc.chunk` (1 row) | 2,797 | four `smallint[256]` (three heightmaps and the light cache key, 536 bytes each) in a 1,722-byte row; three rows per page at fillfactor 70 |
| `mc.chunk_cache` (1 row) | 2,114 | the framed packet (7,262 bytes, pglz'd to 184) **and** its compressed frame `packet_z` (1,071 bytes: the template was compressed by the SQL deflate, a 99-byte zlib stream would do); 1,347 bytes a row, four to a page at fillfactor 70 |
| `mc.chunk_light` (3 rows) | 638 | three rows (one `empty/empty`, two sky arrays that pglz shrinks to 36 bytes) and a 70-byte index entry per row |
| **total** | **9,713** | against vanilla's 6,511 per forced chunk (4,096 per chunk it stores) |

Real terrain (imported world, per chunk, no cache): `mc.chunk_section` 51,788 of 59,056 bytes.  It has 24 rows a chunk (the importer keeps every section, 60% of them single-value
air or stone at about 200 bytes of row and index each) and the data of the others is uncompressed (2 to 3 KB).  The packet cache adds 14.7 KB a chunk once a chunk has been sent
(7.1 KB pglz'd packet + 5.5 KB compressed frame, in the TOAST table).  Noise terrain, per chunk: `chunk_section` 12.8 KB, `chunk` 6.9 KB (see "dead tuples" below), cache 2.4 KB, light 2.3 KB.

Things that were **not** the problem, measured: the indexes are 7% of the flat world (four primary keys, 52 to 70 bytes an entry, 15 to 26% bigger when a table is filled out of
key order); the free-space maps and visibility maps are 24 to 40 KB a table; the WAL is separate (below); there are no dead tuples after a flat generation (`pgstattuple`: 0).

## 3. What changed (`sql/950_world_storage.sql`, "the compact storage profile")

| Change | Saves (flat, per chunk) | Notes |
|---|---|---|
| `mc.chunk_section`: every variable-length column `STORAGE MAIN` + compressed (lz4 as written, pglz when compacted), `toast_tuple_target 512`, fillfactor 90 | 3,780 | a flat section row goes from 2,285 to about 270 bytes; terrain rows shrink to a quarter.  `MAIN` keeps the value in the row: with the default `EXTENDED` PostgreSQL moved `dimension` and the biome palette out to the TOAST table first |
| `mc.chunk`: the four arrays `STORAGE MAIN`, `toast_tuple_target 128`, fillfactor 90 | 2,470 | **a row under 2,032 bytes is never compressed, whatever `toast_tuple_target` says** (tested: a 1,636-byte row stays raw with target 128).  The flat generator copies its template chunk's values, and the template row *is* over the line while it is built, so with target 128 all four arrays are compressed there (28 to 36 bytes each) and every copy inherits them: the row is 230 bytes instead of 1,722 |
| `mc.chunk_cache`: fillfactor 100; the flat template's compressed stream is zlib level 9 when the native deflate is installed (`sql/245`, `gen_version` 4) | 1,659 | `packet_z` of a flat chunk is 130 bytes instead of 1,100; rows are 390 bytes and 20 fit a page |
| `mc.chunk_light`: `sky`, `block` `STORAGE MAIN`, lz4, fillfactor 90 | 113 | an incompressible 2,048-byte light array (vanilla's, imported) no longer goes to the TOAST table |
| `mc.compact_world_storage()` + `tools/compact_world.sh` | | rewrites stored rows (pglz, then `VACUUM FULL`): the existing databases' path, and the cold-data pass |
| `mc.trim_chunk_cache(interval)` | | drops cached packets older than that (derived data); opt-in, see section 6 |

Read sites that decompressed a value once per use were changed to decompress it once (section 5): `mc.edit_section_core`, `mc.fill_section`, `mc.compact_section`, `mc.set_blocks`
and `mc.edit_section` (heightmaps), `mc.section_state_ids`, `mc.heightmaps_wire3`.  Without them `mc.set_blocks` was **3.3x slower** (1.19 ms to 3.9 ms a touched section).

## 4. Sizes after

All numbers in MiB of `pg_total_relation_size` of the five world tables (what the scoreboard measures), same data as in section 1.

| World | Before | After (as generated / imported) | After `tools/compact_world.sh` | Vanilla |
|---|---|---|---|---|
| 10,000 flat chunks | 92.63 | **16.14** (1,692 B/chunk; WAL while generating 64.1 -> 21.7 MiB) | 16.14 (nothing to gain: generated compact) | **62.09** whole folder; 4,096 B per chunk stored |
| 2,000 noise chunks | 46.59 | 19.90 (3,039 of the 10,433 bytes a chunk are free space the generator's updates left in `mc.chunk`, see section 6) | **13.34** (6,992 B/chunk) | 7.84 (own export, a lower bound; 4,096 B/chunk) |
| imported vanilla world, 780 chunks, cache empty | 43.93 | 17.84 (the importer writes lz4 rows) | **13.35** | 17.08 whole folder / 7.23 the 780 chunks alone |
| the same, after every chunk was sent once (cache warm) | 54.45 | 24.35 | | |

Per table, per chunk, flat world, bytes including indexes: `chunk_section` 4,162 -> 380, `chunk` 2,797 -> 329, `chunk_cache` 2,114 -> 455, `chunk_light` 638 -> 525; total 9,713 -> 1,692.

Existing databases: `tools/compact_world.sh --apply-sql` (applies `sql/245`, `291`, `950`, rewrites every row, `VACUUM FULL`s) took the 10,000-chunk flat database of the *old* tree from **92.66 to 27.02 MiB** (1.3 s of rewrite, 0.3 s of `VACUUM FULL`).  It stays above the 16.14 of a freshly generated world because the old cache rows keep their 1,100-byte compressed frames (`select mc.trim_chunk_cache(interval '0')` and let them refill, or regenerate).

## 5. Hot-path cost of the change (CPU time, `tests/bench/world/` style; A = the tree before, B = after, alternated, 6 rounds each, medians, ranges in brackets)

| Path | Before | After (lz4 writes, the default) | After with pglz writes | Verdict |
|---|---|---|---|---|
| `mc.set_block` (a player's edit) | 541.8 us [472-649] / 538.5 [458-626] in two runs | 542.9 [491-630] / 553.2 [478-644]: **0 to +3%** | 597.9 [496-681]: +11% | lz4 is the default because pglz costs +11% here; noise is about 10% |
| `mc.get_block` | 42.0 [34-57] / 38.8 [32-55] | 45.0 [35-52] / 43.3 [36-57]: **+3 us (+7 to 11%)** | 43.1 | a section row is decompressed (palette and data); ranges overlap; real cost, small |
| `mc.set_blocks`, 10,000 edits, per touched section | 1,607 [1,475-2,001] / 1,596 | 1,568 [1,503-1,792] / 1,592: **0%** (was 3,877 before the read sites were fixed) | 1,658 | |
| `mc.fill`, a 48 x 20 x 48 box (12 sections), per call | 22.4 ms [15.7-34.6] / 21.1 | 20.8 [15.5-26.4] / 21.1: **0%** | 22.0 | |
| edit + `mc.chunk_packet` rebuild (flat) | 4,382 us / 4,286 | 4,133 / 4,316: **0%** | 4,414 | |
| join into an unexplored area (generate + 529 chunks) | 128.2 ms [109-152] / 109.9 | 109.5 [99-153] / 97.7: **-12 to -15%** | | smaller cache rows |
| the same join, everything cached | 15.4 ms [9-21] / 14.2 | 12.0 [11-14] / 12.7: **-11 to -22%** | | |
| `mc.generate_flat_area` per chunk | 276 us | 273.5 us: 0% | | |
| cold build of a real terrain chunk packet (imported, 300 chunks, CPU) | 6.27 / 5.92 ms | 5.85 / 5.59 ms (as imported), 5.72 / 5.91 ms (compacted) | | the heightmap read sites were fixed first |
| noise generation, 2,000 chunks | 24.5 s wall (12.2 ms/chunk), WAL 37.7 MiB | 19.5 s (9.7 ms/chunk), WAL 25.4 MiB | | wall time on a loaded machine |

The tick (`tests/bench/tick/ab.sh`, 200 players, 30 x 30 chunks generated and cached, view distance 10, 4 alternated runs of 100 ticks after 20 of warm-up; medians, (min-max) of the four runs; load average 11 to 17 on the machine):

| 200 players | tick wall avg ms (before / after) | on-CPU avg ms | `chunks` phase ms | verdict |
|---|---|---|---|---|
| 20% walking | 41.4 (37.6-45.2) / 42.4 (39.1-44.6) | 9.0 (8.4-9.9) / 9.3 (9.1-9.9) | 5.7 (3.9-6.5) / 7.0 (4.9-7.3) | within noise (+3% CPU, ranges overlap) |
| 100% walking | 79.1 (75.1-84.8) / 84.5 (60.2-99.4) | 26.9 (22.8-34.4) / 23.8 (19.5-32.4) | 19.5 (17.3-32.6) / 23.4 (11.2-36.3) | within noise (the CPU median is lower, the wall median higher, the ranges are 20 ms wide) |

The tick reads sections only through the block-edit phases (`blocks` 0.2-0.4 ms) and chunks only through the cache; neither moved.  I did not rerun the 10-minute 200-player soak of `docs/SOAK.md`.

## 6. Decisions, and what did not work

* **lz4, not pglz, as the write compression.**  pglz is 4 to 13% smaller on terrain (imported sections 11.9 MB against 13.4 MB) but costs +11% on `set_block` (lz4: 0 to +3%) because every
  edit re-forms and re-compresses the section row.  The compaction pass recompresses with pglz, so cold data gets the smaller form.  `mc.set_world_storage('compact', 'pglz')` makes it the default.
* **`toast_tuple_target` below 2,032 does not compress smaller rows.**  Found by experiment (a first try at the chunk row did nothing).  The template trick above, and a padding in
  the compaction (`status || 2,100 spaces`, removed again in a second statement), are the two ways found to get small rows compressed.
* **A compressed value stays compressed in a PL/pgSQL variable and every use decompresses it again.**  Exactly the quadratic behaviour `docs/COMPRESSION.md` warned about for
  detoasted values: 256 `proto.i64_read(data, ...)` calls on a compressed `data` cost 2.7 ms.  Fixed at the read sites (`v := v || ''::bytea`, `array_cat(v, '{}')`), not by
  keeping sections raw.  **Any new function that loops over a section's `data` or `palette`, or over a chunk's heightmaps, must do the same**; `tests/sql/950` does not catch a
  missing one, only the benchmark does (`set_blocks` per section, `fill`).
* **Fillfactor 70 vs 90 vs 100 for sections** made no measurable difference to `set_block` (405 vs 407 us) and 90 keeps room for an edit to stay on its page; 100 gives 3% less.
* **Content-addressed shared sections** (all flat sections are identical): not built.  After compression a flat section row is about 270 bytes plus a 52-byte index entry, 380 bytes of a
  1,692-byte chunk; sharing would remove at most a quarter of the flat world's remaining size and cost every section read a join and every edit a copy-on-write.  For terrain nothing
  is shared.
* **One row per chunk for the sections** (cross-section compression, 24 fewer row headers and index entries): not built.  It would give a section array that every edit rewrites whole (a 40 KB
  row), and `mc.chunk_section` is a composite type used by `mc.gen_template`, `mc.section_wire` and the importer; a view over it cannot keep the hot edit path's `UPDATE ... WHERE pk`.
  Real terrain stays 1.9 times larger than vanilla's full chunks alone (13.35 against 7.23 MiB): vanilla deflates a whole chunk (6.9 KB), per-row lz4 or pglz has no entropy stage
  (about 14 KB a chunk here, `packet_z`, a deflate of the same chunk, is 5.5 KB).  The way to close that is a cold tier that stores deflated chunks and thaws them into the hot tables; every reader of
  `mc.chunk_section` (about 15 functions in 10 files plus the tests) would have to thaw first, and one that did not would see air.  Not attempted.
* **Dropping `packet` and keeping only `packet_z`** (or the reverse) in `mc.chunk_cache`: about 7 KB of 14.7 KB a terrain chunk.  Not done: a dozen readers (`sql/230`, `380`, `383`, `430`,
  `432`, `440`) read `packet` and `net.deflate_frame` checks the compressed frame against it, and the world-performance and join tracks edit those functions.  It needs a native inflate in `dbcraft_zlib`.
* **The packet cache is the largest remaining item for terrain that has been visited** (24.35 MiB warm against 13.35 cold).  It is derived data and `mc.trim_chunk_cache('1 hour')` drops what is
  older; the price is that the next send of such a chunk rebuilds it (5.6 to 6.3 ms of CPU for a terrain chunk, 0.3 ms for a flat one through the generic path, against 20 us cached), which is the
  difference between the join scoreboard rows and a cold join.  It is therefore **not** run by default.  Nothing calls it periodically (the gateway's maintenance thread only vacuums); run it from
  `psql`/cron where disk matters more than rejoin speed.
* **Noise generation leaves a third of its chunk table as free space** (`mc.chunk` is 3.0 KB a chunk after generation against 0.8 after `VACUUM FULL`): the generator inserts each chunk row and
  `mc.ensure_chunk_current` then updates it twice and locks it once (7,520 updates for 2,000 chunks), and a 1.7 KB row has no room for a new version on its 8 KB page.  The space is reused by
  later chunks; `tools/compact_world.sh` removes it.  Fixing it means writing the final row once in `sql/855` / `sql/220`, which belong to the world-performance track: not edited.
* **Light is 31% of a flat chunk now** (525 bytes: three rows and three 70-byte index entries).  `empty/empty` layers are rows only because `mc.light_wire` reads them as rows.  Not changed.

## 7. Operating it

```
psql -c "select mc.set_world_storage('compact')"        # what sql/950 applies; 'legacy' puts the old settings back, 'compact' + 'pglz' is the smallest
tools/compact_world.sh [--apply-sql]                     # an existing database: apply sql/245, 291, 950, rewrite the rows, VACUUM FULL.  Stop the gateway first
psql -c "select mc.trim_chunk_cache(interval '1 hour')"  # optional: drop cached chunk packets older than that
```

`tools/migrate.sh` is for a fresh database: a second run over an existing one stops at the `mc.blocks` view of `sql/210`, which `sql/290` later widens.  `VACUUM FULL` frees nothing while
any session in any database holds a transaction open (the tables came out *bigger* when measured next to a running test suite); `tools/compact_world.sh` warns.

The importer (`tools/world_import.py`) writes with the profile's lz4; run `tools/compact_world.sh` after a big import to get the pglz form (17.84 -> 13.35 MiB for the test world).

## 8. Reproduce

```
tools/pg-dev.sh start  (DBCRAFT_PGDATA=/dev/shm/..., DBCRAFT_PGPORT=...; alter system set jit = off)
tools/migrate.sh --fresh; tools/load_reports.py; ...          # as tests/sql/prun.sh builds its template
select mc.generate_batch('minecraft:overworld', array_agg(x), array_agg(z)) from generate_series(-50, 49) x, generate_series(-50, 49) z;   -- 10,000 flat chunks
checkpoint;  select sum(pg_total_relation_size(c.oid)) from pg_class c where c.relnamespace = 'mc'::regnamespace and c.relname in ('chunk','chunk_section','chunk_light','chunk_cache','block_entity');
```
Vanilla: `tools/scoreboard/run2.py` `scenario_world10k` (or the same RCON recipe by hand); the region statistics were read with a 30-line script over the region headers.  The A/B
timing scripts are in `tests/bench/disk/` (`hot.sql` + `ab_hot.py` for the table of section 5, `generate_and_size.py` and `sizes.sql` for section 4, `cold_build.sql`).
