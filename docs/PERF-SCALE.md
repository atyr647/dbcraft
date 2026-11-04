# World size and storage layout

Question: do dbcraft's world operations stay fast as the stored world grows, and which storage-layout levers keep them fast?
Everything before this was measured on worlds of a few hundred to a few thousand chunks.

## Summary

* **Latency does not depend on world size** for any operation a tick performs, up to 200,000 flat chunks (1.9 GB) and 20,000 real-terrain chunks (1.9 GB).
  Fitted growth exponents of p50 against chunk count are between -0.10 and +0.19 for every operation (a 200x larger world is at most 2.9x slower, on cold reads;
  warm reads are within 1.5x), no plan changed, and no hot statement used a sequential scan at any size. The growth that exists is logarithmic: index depth and cache misses.
* **One real scaling hazard existed, and is fixed:** `select ... from mc.blocks where x = .. and y = .. and z = ..` unpacked every section before filtering
  (4 ms per stored section: 4 s per 1,000 sections, about 200 s at 50,000 and 800 s at 200,000). The rewritten view (`sql/290_blocks_view.sql`) answers the same query in
  88-250 ms at 50,048 sections (parallel scan) and in 0.7-0.9 ms when the section coordinates are added; rows are identical to `mc.blocks_in`.
* **Storage:** a flat chunk costs 9.8 KB, a real terrain chunk 95 KB (sections 74%, packet cache 15%, light 8%, chunk row 3%). Letting section rows compress
  (opt-in, `sql/291`) takes dense chunks to 54 KB without measurable latency cost (after one function was fixed, see below).
* **The biggest dense-world cost is not storage but CPU on the join path:** a 441-chunk join into real terrain takes 104-120 ms at every world size because the packet cache is
  stored compressed with pglz and every join decompresses 22 MB. lz4 makes it 36 ms for +24% cache size; uncompressed storage makes it 13 ms for 4x the cache size (opt-in switch in `sql/291`).
* **Levers that do not help:** hash/range partitioning (single lookups 4x slower, joins 2.5-6x slower), a covering index, a packed bigint key, BRIN, physical ordering/`CLUSTER`
  (medians unchanged; only first-touch p99 improves). An UNLOGGED cache saves 10 KB of WAL per dense chunk but a crash then costs 2.6-6.5 s for the first join.

## How this was measured (and what it does not show)

* PostgreSQL 16.15, 4 vCPUs (Xeon 2.1 GHz) **shared with up to six other jobs for the whole session** (load average 2.2-4.3 before each measurement, stated in the tables).
  Treat differences under about 1.5x as noise. Medians come from 200 random keys per operation (30 for joins, 20 batches for generation); p99 is the 99th percentile of those.
* Own cluster: `shared_buffers = 256MB`, `fsync = off`, `synchronous_commit = off`, `max_wal_size = 1GB`, `jit = off`. The world is larger than the cache from about 50,000 chunks on.
* **COLD** = the server is stopped, the OS page cache dropped (`echo 3 > /proc/sys/vm/drop_caches`) and the server started again, then 200 random keys; each key touches mostly uncached pages,
  but the shared upper index levels warm up during the run, so cold p50 is "cold start of a large database", not "every access misses". **WARM** = the same keys again. The disk is a fast
  virtual SSD (random reads about 100 us); on a slow disk the cold numbers would be larger.
* Latencies are taken inside PostgreSQL with `clock_timestamp()` around each call (no client or network time).
* Two kinds of world, both built set-based and in spiral order of 8 x 8 chunk tiles (what an exploring player produces):
  **flat** (the flat generator: sections, light and cache per chunk) up to 200,000 chunks, and **dense** (the 49 real vanilla terrain chunks of `tests/fixtures`,
  replicated with rewritten coordinates and block entities; their cached packets are the real ones with the coordinates patched; the replicas were checked: the patched packet equals what the server builds
  from the replica rows, for 64 of 64 chunks). A dense world repeats 49 chunks, so TOAST compression and the buffer cache see more repetition than real terrain would: storage and compression numbers are
  optimistic for a world of unique chunks.
* Not covered: concurrent load (these are single-session latencies), worlds beyond 200,000 flat / 20,000 dense chunks (the cluster was capped at 4 GB; larger sizes are extrapolated), other dimensions, entity data.

## Results: flat world

### flat: chunks per world size: 1,024, 10,048, 50,048, 100,032, 200,000

#### flat, warm: p50 (p99) in microseconds

| operation | 1,024 | 10,048 | 50,048 | 100,032 | 200,000 | last/first (p50) | fitted b (R2) |
|---|---|---|---|---|---|---|---|
| get_block | 12 (62) | 16 (72) | 18 (106) | 21 (384) | 14 (87) | 1.17x | +0.06 (0.36) |
| block_at | 26 (177) | 22 (115) | 23 (108) | 29 (156) | 39 (224) | 1.50x | +0.06 (0.30) |
| blocks_in | 3,936 (9,596) | 4,050 (13,061) | 4,868 (18,829) | 4,355 (12,822) | 5,062 (16,986) | 1.29x | +0.04 (0.70) |
| chunk_packet_cached | 17 (185) | 17 (106) | 21 (92) | 28 (244) | 23 (149) | 1.35x | +0.08 (0.68) |
| set_block | 129 (436) | 105 (669) | 76 (401) | 80 (363) | 136 (618) | 1.05x | -0.04 (0.11) |
| rebuild_after_edit | 3,738 (9,828) | 3,823 (5,353) | 4,478 (7,403) | 4,102 (11,864) | 5,836 (8,990) | 1.56x | +0.06 (0.57) |
| generate_batch64 | 17,170 (25,320) | 6,427 (12,265) | 10,999 (19,590) | 9,392 (39,373) | 8,331 (26,833) | 0.49x | -0.10 (0.31) |
| join441 | 6,906 (12,178) | 8,038 (13,153) | 10,640 (14,238) | 7,854 (14,738) | 10,462 (13,882) | 1.51x | +0.07 (0.55) |
| border_step | 6,956 (8,271) | 7,645 (11,375) | 8,009 (11,031) | 8,368 (12,879) | 7,975 (9,884) | 1.15x | +0.03 (0.86) |

#### flat, cold: p50 (p99) in microseconds

| operation | 1,024 | 10,048 | 50,048 | 100,032 | 200,000 | last/first (p50) | fitted b (R2) |
|---|---|---|---|---|---|---|---|
| get_block | 100 (284) | 105 (724) | 186 (1,874) | 163 (4,084) | 162 (1,261) | 1.62x | +0.12 (0.73) |
| block_at | 94 (1,243) | 122 (545) | 168 (1,424) | 201 (4,368) | 270 (648) | 2.86x | +0.19 (0.94) |
| blocks_in | 3,556 (14,644) | 5,497 (20,530) | 4,094 (13,513) | 4,473 (17,523) | 5,096 (18,917) | 1.43x | +0.04 (0.27) |
| chunk_packet_cached | 165 (916) | 222 (1,043) | 290 (3,684) | 286 (1,873) | 282 (1,109) | 1.71x | +0.11 (0.92) |
| set_block | 338 (1,773) | 591 (3,097) | 401 (1,301) | 434 (1,215) | 512 (4,386) | 1.52x | +0.05 (0.20) |
| rebuild_after_edit | 6,202 (9,652) | 5,614 (10,189) | 4,946 (8,923) | 6,438 (11,140) | 4,705 (8,754) | 0.76x | -0.03 (0.25) |
| generate_batch64 | 15,410 (37,744) | 8,008 (29,375) | 11,406 (47,536) | 9,922 (36,013) | 7,374 (24,122) | 0.48x | -0.10 (0.49) |
| join441 | 5,212 (50,218) | 9,202 (40,235) | 10,562 (41,138) | 7,664 (52,760) | 7,680 (34,352) | 1.47x | +0.07 (0.33) |
| border_step | 8,718 (11,746) | 10,023 (13,373) | 7,786 (17,596) | 7,794 (15,626) | 8,178 (11,581) | 0.94x | -0.03 (0.31) |

#### flat: storage per chunk (heap + toast + indexes, bytes per chunk)

| table | 1,024 | 10,048 | 50,048 | 100,032 | 200,000 |
|---|---|---|---|---|---|
| chunk | 2,840 (idx 96) | 2,823 (idx 91) | 2,803 (idx 72) | 2,800 (idx 69) | 2,804 (idx 74) |
| chunk_section | 4,208 (idx 96) | 4,189 (idx 91) | 4,169 (idx 72) | 4,166 (idx 69) | 4,170 (idx 74) |
| chunk_light | 688 (idx 248) | 684 (idx 259) | 664 (idx 240) | 678 (idx 254) | 680 (idx 256) |
| chunk_cache | 2,160 (idx 96) | 2,129 (idx 91) | 2,118 (idx 72) | 2,116 (idx 69) | 2,121 (idx 74) |
| **all four** | **9,896** | **9,825** | **9,753** | **9,759** | **9,775** |

#### flat: growth (generation), vacuum, plans

| chunks | made | seconds | chunks/s | WAL bytes/chunk | checkpoints (timed/requested) | vacuum analyze s | DB MB | plans with a seq scan |
|---|---|---|---|---|---|---|---|---|
| 1,024 | 1,024 | 0.36 | 2823.3 | 6704 | 0/0 | 0.07 | 36 | none |
| 10,048 | 9,024 | 1.63 | 5534.7 | 6883 | 0/0 | 1.19 | 121 | none |
| 50,048 | 40,000 | 6.45 | 6199.0 | 6848 | 0/0 | 4.14 | 493 | none |
| 100,032 | 49,984 | 7.81 | 6401.4 | 6964 | 0/0 | 6.6 | 959 | none |
| 200,000 | 99,968 | 14.85 | 6731.6 | 7129 | 0/1 | 4.97 | 1893 | none |

load average before the operations: 2.97, 3.27, 3.77, 4.32, 3.99
dead tuples / autovacuum runs / autoanalyze runs at measurement time (largest world): chunk:0/1/2 chunk_section:0/2/3 chunk_light:0/3/3 chunk_cache:0/3/2 chunk_request:0/0/0 chunk_wanted:0/0/0

Plan stability: `EXPLAIN` of the section lookup, chunk existence, chunk + cache join, light read, the 441-chunk join and the region query at each size: index scans / index-only scans / nested
loops at every size, **no sequential scan on an mc.* table** (the join's plan changed from hash joins at 1,000 chunks to nested loops at larger sizes, both fast).
Autovacuum kept up: dead tuples were 0 at every measurement (the generator only inserts; edits are tiny). `VACUUM (ANALYZE)` of the four chunk tables takes 5 s at 200,000 chunks.
Checkpoint/WAL while generating: about 7 KB of WAL per flat chunk (68 KB per dense chunk); one requested checkpoint at the 200,000-chunk step (`max_wal_size = 1GB`).
Index sizes: all indexes of the four chunk tables together are 95 MB at 200,000 flat chunks (0.5 KB per chunk), smaller than `shared_buffers`.

## Results: dense (real terrain) world

### dense: chunks per world size: 1,073, 5,105, 10,097, 20,081

#### dense, warm: p50 (p99) in microseconds

| operation | 1,073 | 5,105 | 10,097 | 20,081 | last/first (p50) | fitted b (R2) |
|---|---|---|---|---|---|---|
| get_block | 22 (88) | 17 (70) | 17 (85) | 22 (139) | 1.00x | -0.02 (0.04) |
| block_at | 28 (122) | 40 (173) | 39 (243) | 29 (126) | 1.04x | +0.04 (0.07) |
| blocks_in | 3,492 (12,340) | 3,692 (10,451) | 4,528 (14,429) | 3,577 (13,554) | 1.02x | +0.04 (0.14) |
| chunk_packet_cached | 10 (114) | 14 (126) | 18 (119) | 17 (79) | 1.70x | +0.20 (0.90) |
| set_block | 74 (418) | 74 (270) | 73 (578) | 74 (356) | 1.00x | -0.00 (0.09) |
| rebuild_after_edit | 14,908 (31,051) | 14,124 (24,486) | 13,600 (22,639) | 12,408 (23,642) | 0.83x | -0.06 (0.89) |
| join441 | 104,406 (128,856) | 90,880 (150,016) | 113,544 (153,399) | 116,228 (148,172) | 1.11x | +0.04 (0.22) |
| border_step | 112,363 (147,032) | 112,714 (143,941) | 109,258 (137,661) | 124,544 (147,720) | 1.11x | +0.02 (0.27) |

#### dense, cold: p50 (p99) in microseconds

| operation | 1,073 | 5,105 | 10,097 | 20,081 | last/first (p50) | fitted b (R2) |
|---|---|---|---|---|---|---|
| get_block | 177 (588) | 170 (563) | 137 (667) | 168 (503) | 0.95x | -0.04 (0.23) |
| block_at | 176 (698) | 235 (979) | 190 (2,241) | 219 (2,844) | 1.24x | +0.06 (0.33) |
| blocks_in | 4,693 (15,326) | 5,324 (19,293) | 5,994 (18,872) | 4,648 (31,892) | 0.99x | +0.02 (0.06) |
| chunk_packet_cached | 71 (393) | 100 (543) | 156 (569) | 259 (1,668) | 3.65x | +0.43 (0.91) |
| set_block | 333 (6,428) | 342 (4,901) | 384 (4,876) | 496 (4,604) | 1.49x | +0.12 (0.70) |
| rebuild_after_edit | 16,004 (35,254) | 15,026 (27,934) | 17,004 (35,911) | 16,296 (32,900) | 1.02x | +0.01 (0.11) |
| join441 | 104,380 (221,422) | 111,821 (238,602) | 106,218 (204,907) | 120,615 (217,497) | 1.16x | +0.04 (0.55) |
| border_step | 111,045 (163,980) | 115,098 (130,918) | 113,119 (155,049) | 113,881 (156,505) | 1.03x | +0.01 (0.44) |

#### dense: storage per chunk (heap + toast + indexes, bytes per chunk)

| table | 1,073 | 5,105 | 10,097 | 20,081 |
|---|---|---|---|---|
| chunk | 2,840 (idx 92) | 2,807 (idx 74) | 2,932 (idx 67) | 2,850 (idx 67) |
| chunk_section | 70,224 (idx 1,848) | 70,539 (idx 1,972) | 70,556 (idx 1,995) | 70,513 (idx 2,004) |
| chunk_light | 8,062 (idx 1,092) | 7,813 (idx 1,083) | 8,001 (idx 1,101) | 7,968 (idx 1,106) |
| chunk_cache | 13,971 (idx 92) | 13,813 (idx 74) | 14,347 (idx 67) | 13,942 (idx 67) |
| **all four** | **95,097** | **94,973** | **95,835** | **95,272** |

#### dense: growth (generation), vacuum, plans

| chunks | made | seconds | chunks/s | WAL bytes/chunk | checkpoints (timed/requested) | vacuum analyze s | DB MB | plans with a seq scan |
|---|---|---|---|---|---|---|---|---|
| 1,073 | 960 | 2.91 | 330.0 | 63983 | 0/0 | 0.39 | 125 | none |
| 5,105 | 4,032 | 13.49 | 298.8 | 68349 | 0/0 | 1.1 | 491 | none |
| 10,097 | 4,992 | 15.85 | 314.9 | 67811 | 0/0 | 1.79 | 953 | none |
| 20,081 | 9,984 | 31.87 | 313.3 | 68144 | 0/1 | 2.86 | 1855 | none |

load average before the operations: 2.93, 3.15, 3.49, 3.69
dead tuples / autovacuum runs / autoanalyze runs at measurement time (largest world): chunk:0/1/5 chunk_section:521/2/2 chunk_light:0/3/5 chunk_cache:0/1/3 chunk_request:0/0/0 chunk_wanted:0/0/0

`join441` and `border_step` are 100-120 ms at every size: that is CPU, not I/O (cold and warm are equal): see "Cache storage" below.

## Fitted growth

The fitted exponent `b` of p50 ~ N^b is in the last column of the tables above. Reading: for a 200x range, `b = 0.1` is the growth of a log-depth index plus a few cache misses.
No operation has `b` above 0.19 (flat, cold `block_at`: 94 us at 1,024 chunks to 270 us at 200,000, R2 0.94) except dense cold `chunk_packet_cached` (71 to 259 us over 20x, b = 0.43,
R2 0.91), which is a cold random read of a 14 KB TOAST value per call and is still a quarter of a millisecond. Most R2 values are low because the true trend is flat and the noise is not.

## Two scaling hazards that are not about latency of a single key

1. **`mc.blocks` with a coordinate filter scanned and unpacked every section** (above). Measured on the 200,000-section world: cancelled after 15 s; 3.98 s for the first 1,000 sections.
   Fixed by `sql/290_blocks_view.sql`: x, y, z are now join columns (section origin + a 0..15 series per axis), so the filters discard rows before any block is looked up, and
   `cx`, `cz`, `sy` are exposed (appended, so the `INSTEAD OF` triggers survive) for an index lookup. Same rows as `blocks_in` (9,216 of 9,216, equal md5), `UPDATE`/`DELETE`/`INSERT`
   through the view still work. Still O(sections) without the section columns (88 ms at 50,048 sections, so about 0.35 s at 200,000), but about 1,000x cheaper per section.
   Cost of an unfiltered `select * from mc.blocks`: not measured on large worlds; it looks up every block through `entry_at`, which is slower than the old set-based unpack, so use `blocks_in` for bulk reads.
2. **Region scans on the section table grow with the world's extent.** A 16 x 16 chunk box on the primary key (dimension, cx, cz, sy) uses `cx` for the index range and tests `cz` as a filter, so
   it examined 564 buffers for 6,144 rows in a world 144 chunks wide (30 ms with I/O, 1.5 ms for a 4 x 4 box). Nothing on the tick does this; `blocks_in` over big boxes, exports and `fill` do.
   BRIN does not help (below), a z-order key would; not built.

## Levers, one by one

| Lever | Result | Verdict |
|---|---|---|
| Sargable `mc.blocks` | point query 200 s to 0.09-0.25 s at 50k sections, 0.7 ms with section coordinates | **adopted** (`sql/290`, test `tests/sql/290_blocks_view.sql`, 17 checks) |
| Let section rows compress (`toast_tuple_target` default) | section table 345 MB to 143 MB (2.4x) on 5,105 dense chunks; chunk total 95 KB to about 54 KB; no change in get_block / set_block / rebuild / join; **blocks_in 4x slower until `unpack_longs` was fixed** | **opt-in** (`mc.set_section_compression`, `mc.rewrite_sections`, `sql/291`, test `tests/sql/291`) |
| Cache packet storage: lz4 / external | join441 on dense terrain 104 ms to 36 ms (lz4, +24% size) or 13 ms (external, 4x size) | **opt-in switch** `mc.set_cache_storage` |
| UNLOGGED `chunk_cache` | WAL per dense chunk 11.8 KB to 1.6 KB; crash empties it; first join after a crash 2.6-6.5 s instead of 92-141 ms | not adopted (needs a warm-up job first) |
| Evict cold cache rows | hit 18.5 us, miss 4.4 ms (flat; 6-15 ms dense); cache is 22% of flat storage, 15% of dense | not built (needs read tracking; low value for flat worlds) |
| `CLUSTER` / insertion order | medians unchanged (join441 cold p50 6.0-7.5 ms for spiral, shuffled, scattered and clustered); cold p99 61 ms scattered to 25 ms clustered; 4.6 s of exclusive lock for 50k chunks | not needed; run only if first-touch p99 matters |
| Hash / range partitioning | single lookup 9 us to 34-43 us, 441-chunk join 3.5 ms to 8.9-21 ms, planning 0.33 ms to 0.56-0.91 ms | **hurts**, not adopted |
| Covering index `INCLUDE (version, dirty, hm_dirty)` | join 3.5 ms to 4.7 ms; index 2.4 MB to 5.7 MB | no gain |
| Packed bigint primary key | index 2.4 MB to 1.1 MB (50 bytes per chunk), lookup the same (8 vs 9 us), join slower in my test (7.2 vs 3.5 ms, a different plan) | not worth it |
| BRIN on (cx, cz) | 24 KB vs 2.4 MB, region scan 0.32 vs 0.31 ms (16 x 16), 0.14 vs 0.10 ms (4 x 4); useless when rows are inserted in scattered order | not worth it |

### Cache storage: pglz, lz4, external (dense terrain, 5,056 chunks, 441-chunk join, p50)

| cache storage | size of the cache | join cold | join warm |
|---|---|---|---|
| pglz (default) | 64.6 MB | 104.3 ms | 103.5 ms |
| lz4 | 80.1 MB | 38.9 ms | 36.4 ms |
| external (uncompressed, out of line) | 261.1 MB | 24.0 ms | 13.0 ms |

The 50 KB packets compress 4.2x with pglz (12.3 KB stored), 3.4x with lz4 (15.4 KB). The single cached read (`chunk_packet`) is 10-20 us in all modes because the PL/pgSQL variable keeps the stored value;
the cost appears where the packet is cut to its body (`substring`, as `net.hook_chunks` does), which decompresses it. Mind the ratio: a dense world repeats 49 chunks, so real terrain may compress worse
(more CPU saved by lz4/external, more disk used by external).

### Section compression, and the mistake in my first diagnosis

`sql/200` sets `toast_tuple_target = 8160` on `mc.chunk_section`, so a section row is compressed only if the whole row exceeds 8,160 bytes. Real sections average 2.9 KB (flat ones 4 KB), so none are, and
the table is 2.4x bigger than it needs to be. After `reset (toast_tuple_target)` and rewriting the rows (6.2 s for 122,520 rows, then `VACUUM FULL` 1.0 s), 47% of the `data` values and 15% of the palettes are pglz-compressed
and the table is 143 MB instead of 345 MB. Latency (5,056 dense chunks, p50, cold / warm), uncompressed -> compressed:

* get_block 194 / 27 us -> 160 / 24 us; set_block 426 / 114 us -> 411 / 134 us; chunk rebuild after an edit 19.0 / 15.1 ms -> 16.9 / 14.4 ms; 441-chunk join unchanged (it does not read sections).
* `blocks_in` **4.5 / 5.2 ms -> 23.9 / 19.8 ms.** My first explanation (the per-block `palette[...]` subscripts in `mc.section_blocks` decompress the palette 4,096 times) was wrong: the fix for
  that alone changed nothing (20.7 / 20.6 ms). The cost was `mc.unpack_longs`, which calls `get_byte(d, ...)` about 12,000 times per section, each on the compressed `data` value, decompressing it again every time.
  Binding the value once (`d || ''::bytea`) brought `blocks_in` to 4.7 / 4.9 ms. `unpack_longs` returns exactly the same arrays (tested on 30 random buffers of every bit width and on real sections).
* It stays opt-in because every later write is stored differently and because any other code that reads a section value thousands of times per call would pay the same decompression: the paths measured here
  (get/set/rebuild/blocks_in) do not, but I did not read every function. `select * from mc.blocks` with no filter (the new view) would also decompress per row on compressed sections.

### UNLOGGED cache and what a crash costs

5,056 dense cache rows: 57 MB of WAL logged (11.8 KB per chunk), 7.8 MB unlogged (1.6 KB per chunk), which is about 15% of the 68 KB of WAL a dense chunk generates. After `pg_ctl stop -m immediate`
the unlogged cache was empty (0 rows) and the first 441-chunk join at three centres took 6,467, 2,613 and 5,933 ms (6-15 ms per chunk to rebuild and re-insert; overlapping joins are cheaper), against
92-141 ms once the cache was full again. So an unlogged cache needs a background re-warm of the chunks players are near before the server accepts joins.

### Backup sanity

`pg_dump -Fc`: 43 s and a 31 MB file for the 200,000-chunk flat world (1.9 GB); 86 s and 406 MB for the 20,032-chunk dense world (1.86 GB); dense 5,105 chunks: dump 14.5 s (73 MB file for about 0.5 GB of world data), restore 11.3 s (`-j 1`).
Dump time is dominated by compression of the dump (user CPU about 90% of wall time).

## Recommended layout

1. Keep the layout: one row per chunk / section / light layer / cache entry with the (dimension, cx, cz[, sy]) primary key. No partitioning, no covering index, no key change, no BRIN.
2. Adopt `sql/290_blocks_view.sql` (done in this branch). Tell users to add `cx`, `cz`, `sy` to `mc.blocks` filters on big worlds, or use `block_at` / `blocks_in`.
3. For dense (terrain) worlds switch on `mc.set_cache_storage('lz4')` (joins 2.8x faster for +24% cache) and consider `mc.set_section_compression(true)` + `mc.rewrite_sections()` (-40 KB per chunk).
   For flat worlds neither matters much (joins are 7-10 ms; a flat chunk is 9.8 KB).
4. (Superseded by [PERF-DISK.md](PERF-DISK.md): `sql/950` made compression the default; flat is now 1.7 KB/chunk, noise terrain 7.0 KB compacted, the imported vanilla world 17.9 KB compacted without the packet cache.)  Plan disk by world type: flat 9.8 KB/chunk (1M chunks = 9.8 GB); real terrain 95 KB/chunk now (95 GB per million chunks), about 54 KB with compressed sections and 40 KB if the cache were dropped.
   WAL while generating: 7 KB (flat) / 68 KB (dense) per chunk, so size `max_wal_size` for the generation rate (6,700 flat chunks/s inserts about 47 MB/s of WAL).
5. Do not use an unlogged cache without a warm-up path. Do not build cache eviction before there is read tracking and a dense world that needs it.

## Extrapolation beyond what was measured

Storage is exactly linear (per-chunk bytes are within 1% from 1,024 to 200,000 chunks). Latency: fits above; no sign of a cliff, but nothing here measures a world larger than the buffer cache by more than
about 7x (1.9 GB against 256 MB shared buffers plus the OS cache); with a much slower disk the cold numbers scale with the number of random reads an operation does (about 3 for `get_block`, 2 x 441 for a cold join).

## Files and merge notes

* `sql/290_blocks_view.sql` (view only; redefinition keeps the `INSTEAD OF` triggers), `sql/291_section_compression.sql` (opt-in functions, `mc.section_blocks` and `mc.unpack_longs` overrides),
  `sql/OVERRIDES.txt` (two lines appended: **expect a textual merge conflict at the end of this file** if another branch appended too; the checker `tools/check_overrides.py` verifies the result).
* The main branch has its own `sql/290_world_batch.sql`: a different file, applied after mine alphabetically (`290_blocks_view` < `290_world_batch`); neither touches the other's objects.
* Tests: `tests/sql/290_blocks_view.sql` (17 checks), `tests/sql/291_section_compression.sql` (21 checks). Full suite on this branch: 1,013 checks (975 on the base, plus 17 and 21) and the structural checks (override allowlist, clean-migration definitions); run with `DBCRAFT_TESTDB=name tests/sql/run.sh`.
* Harness (`tests/bench/scale/`): `setup.sh`, `helpers.sql`, `run_scale.py` (growth + per-size measurements), `dense.sql` (+ `dense_check.sql`), `report.py`, `compare.py`, the lever scripts (`lever_toast.py`,
  `lever_partition.py`, `lever_order.sql`, `lever_unlogged.sql` + `crash.sh` + `crash_measure.sql`, `lever_evict.sql`, `lever_brin.sql`, `lever_sec_compress.sql`), `blocks_view_hazard.sql`, `blocks_view_new.sql`,
  `region_scan.sql`, `dump_restore.sh`, and `results/*.json` (all raw numbers).

```
export DBCRAFT_PGDATA=/tmp/dbcraft-pg-scale DBCRAFT_PGPORT=54444
tools/pg-dev.sh start                       # then ALTER SYSTEM shared_buffers=256MB etc. as in "How this was measured", restart
bash tests/bench/scale/setup.sh scale
python3 tests/bench/scale/run_scale.py flat 1024 10048 50048 100032 200000        # about 25 minutes
bash tests/bench/scale/setup.sh scale_dense && psql -d scale_dense -f tests/bench/scale/dense.sql
python3 tests/bench/scale/run_scale.py dense 1024 5056 10048 20032 --grow grow_dense --db scale_dense --ops get_block,block_at,blocks_in,chunk_packet_cached,set_block,rebuild_after_edit,join441,border_step
python3 tests/bench/scale/report.py flat; python3 tests/bench/scale/report.py dense
```

## Mistakes made on the way (so the numbers can be trusted)

* The first flat run counted the far-away generation test's chunks as part of the world ("1,000 chunks" held 3,584); growth now counts spiral tiles and the far chunks are deleted after that test. All tables use the corrected runs.
* The first explanation of the `blocks_in` regression (palette) was wrong, as described above.
* Four assertions I first wrote in `tests/sql/291` could never fail (one ended in `or true`, one compared a value to itself, one had `and false`, one was mislabelled and trivially true); I found them on re-reading and removed them, they are not in the final test.
* Single runs on this machine vary by 1.5-2x with the load (the same configuration gave set_block warm p50 of 114, 134, 140 and 229 us); conclusions above rest on differences of 2.4x or more, or on deterministic quantities (bytes, plans, WAL).
