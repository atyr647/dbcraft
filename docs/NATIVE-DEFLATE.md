# Native deflate: an optional accelerator

`docs/PERF-CHUNKS.md` found that compression written in SQL (`sql/440_deflate.sql`: runs + fixed Huffman) works and is verified, but reaches only **2.2x on real
terrain at about 28 ms per packet**, against zlib's 5.25x. Compression is the one primitive SQL cannot do well, so this is an **optional accelerator**: a
small PostgreSQL C extension, `native/dbcraft_zlib`, with pure functions only (deflate, Adler-32, CRC-32). If it is installed the server uses it; if not,
nothing changes.

Measured on: PostgreSQL 16.15, 4 CPUs (Xeon 2.1 GHz), zlib 1.3, libdeflate 1.19, `jit = off`. **The machine was shared with other jobs the whole time
(load average 3 to 4.4 on 4 CPUs).** Every timing below was taken inside Postgres, with a different input per call (no constant folding), interleaved across
rounds in shuffled order, and reported as the median; min and max are in `tests/bench/native/results.json` and show a spread of 30% to 60% from the load.
Ratios are deterministic and identical in every round. Treat timings as indicative: differences under about 1.5x are noise; the 10x to 30x gaps are not.

## What was built

| Piece | Where |
|---|---|
| the extension (C, PGXS) | `native/dbcraft_zlib/` (`make && sudo make install`; `make WITH_LIBDEFLATE=no` for zlib only) |
| dispatch, a no-op when the extension is absent | `sql/441_deflate_native.sql` |
| tests (skipped with a notice when the extension is absent) | `tests/sql/441_deflate_native.sql` |
| second inflater (Java, what the client uses) | `tests/bench/native/inflate_java.sh` |
| benchmarks | `tests/bench/native/` (`setup.sql`, `bench.py`, `zframe.py`, `throughput.sh`, `leakcheck.sql`, `cache_cost.sh`) |

**Deviation from the brief: the dispatch file is `sql/441`, not `sql/291`.** The SQL deflate it overrides is defined in `sql/440_deflate.sql`, and migrations run in
file order, so a `291` file would run before it and be overwritten.

Functions (schema `dbcraft_zlib`; all `IMMUTABLE STRICT PARALLEL SAFE`, checked by a test against `pg_proc`):

| Function | What |
|---|---|
| `deflate_zlib(data, level = 6, backend = 'auto')` | a complete zlib stream; backend `auto` (libdeflate if built in), `zlib`, `libdeflate` |
| `deflate_raw(data, level, backend)` | a bare deflate stream, one final block |
| `deflate_fragment(data, level, final = false)` | an independent raw fragment ending in a sync flush (`00 00 ff ff`), byte aligned, so fragments concatenate; zlib only (libdeflate cannot sync-flush) |
| `adler32(data)`, `crc32(data)`, `adler32_combine(a1, a2, len2)` | checksums as unsigned 32-bit values in a bigint |
| `backend()` | e.g. `zlib 1.3 + libdeflate` |

Dispatch (`sql/441`): `mc.deflate_zlib` and `mc.adler32` (the two functions on the chunk-compression path, used by `mc.z_frame` and `net.deflate_frame`) call the
extension when it is installed. The SQL implementations stay available as `mc.deflate_zlib_sql` and `mc.adler32_sql`, and `mc.select_deflate('native'|'sql', level)`
switches at any time (`mc.deflate_impl()` tells which is active). The template splice for flat chunks (`sql/245`) is untouched: it costs microseconds and runs
once per template.

Safety: input is capped at 16 MiB (`ERRCODE_PROGRAM_LIMIT_EXCEEDED`); the output buffer is the library's own worst-case bound, checked against the palloc limit;
levels outside 0 to 9 and unknown backends raise; zlib works in 64 KiB slices with `CHECK_FOR_INTERRUPTS()`, so a cancel or `statement_timeout` is honoured
within a few milliseconds (libdeflate compresses in one call and is only interruptible before it starts, at most a few hundred milliseconds for 16 MiB).
Compressors are cached per backend and reset on every call, so output depends only on the arguments.

## Evidence that it is correct

* **911 SQL checks pass with the extension installed, 878 without it** (874 existing + 4 fallback checks): the whole suite, including the real-inflater
  compression tests (`280`), the byte-exact replays (`410`, `420`) and the chunk queue (`430`), ran on the native path.
* **537 streams judged by two real inflaters, none rejected**: Python's `zlib` (checks the Adler-32 too) in the test itself, and Java's `java.util.zip.Inflater`
  (JDK 25) over the same dump. They cover the empty input, one byte, runs, all 256 byte values, 1 MiB of incompressible data, 2 MB of chunk-like data, levels 0
  to 9, both backends, zlib/raw/fragment modes, 25 stitched fragments (as one raw stream, and as a zlib stream with a combined Adler-32), `mc.z_frame` wire
  frames, and **300 fuzz cases** (random mixtures of runs and random bytes, 0 to 30,000 bytes, random level/backend/mode).
* **Checksum vectors**: Adler-32 of "Wikipedia" = 300286872, CRC-32 of "123456789" = 0xCBF43926, and agreement with the SQL Adler-32 on 30 random inputs and with
  `adler32_combine` on 20 splits; the fold of per-fragment Adler-32 values equals the Adler-32 of the whole.
* **Limits and errors**: exactly 16 MiB is accepted, 16 MiB + 1 byte is refused, bad level and backend raise, NULL gives NULL.
* **Interrupts**: a 60 ms `statement_timeout` cancelled a level-9 zlib compression of 8 MiB of random data after 61 ms (the test fails if the cancel takes over 400 ms,
  and says so in a notice if the compression happened to finish before the timeout).
* **Compressor reuse is invisible**: 300 rounds interleaving levels, backends and modes returned bytes identical to the first call every time.
* **Memory is bounded**: four identical passes of about 6,300 compressions each in one backend: resident memory 35,908 kB after pass 1, then 35,916 and
  35,920 kB after passes 2 and 4 (+12 kB). The first pass is what allocates the per-backend compressor caches (`tests/bench/native/leakcheck.sql`).
* **Not done**: no valgrind or ASan run, no formal audit. The functions are small (one 280-line file), allocate only through `palloc` and the two libraries'
  own allocation, and hold no pointers between calls other than the cached compressors.

## Results

Data: the **49 real vanilla terrain chunk packets** of the capture (payload = packet id + body, 2,527,298 bytes, **average 51.6 KB**; note the brief said about
125 KB, which was my early synthetic estimate), 641 pieces of 4 KiB cut from them, and 40 flat-world packets (average 9.3 KB). 9 interleaved rounds.

### Whole real terrain packets

| Variant | ms per packet (median) | min .. max | ratio |
|---|---|---|---|
| **SQL deflate (`sql/440`)** | **27.9** | 24.3 .. 34.3 | **2.19x** |
| zlib L1 | 0.51 | 0.37 .. 0.66 | 4.60x |
| libdeflate L1 | 0.29 | 0.21 .. 0.39 | 4.80x |
| zlib L6 | 1.36 | 1.16 .. 1.84 | 5.25x |
| **libdeflate L6** (the default) | **0.54** | 0.36 .. 0.73 | **5.27x** |
| zlib L9 | 8.99 | 7.38 .. 10.2 | 5.31x |
| libdeflate L9 | 1.57 | 1.36 .. 1.98 | 5.34x |

The CHUNKS worker's estimate ("about 5x at about 1.5 ms") holds for zlib L6. **libdeflate gives the same ratio 2.5x to 3x faster** (0.54 ms vs 1.36 ms at L6,
0.29 vs 0.51 at L1). Level 9 buys 1.3% more ratio for 2.9x (libdeflate) to 6.6x (zlib) the time of level 6: not worth it. L6 over L1 gains 10% in size for about 1.9x the time; because a
compressed chunk is made once and sent to many players, size matters more than compression time, so the default is **level 6, libdeflate**.

### The real code path: `mc.z_frame` (5 interleaved rounds, each measurement its own transaction)

| Implementation | ms per packet (median) | ratio |
|---|---|---|
| SQL | 31.1 | 2.19x |
| native, level 1 | 0.82 | 4.80x |
| native, level 6 (default) | **0.93** | **5.27x** |
| native, level 9 | 2.07 | 5.34x |

`z_frame` adds about 0.4 to 0.5 ms over the bare function (the materialised CTE and the length prefixes), so the real gain is **about 33x in time and 2.4x in size**.
The SQL Adler-32 alone is 4.2 ms of a 51 KB packet (15% of the SQL path) against 0.059 ms native.

### Per 4 KiB piece (641 pieces) and the fragment scheme

| Variant | ms per 4 KiB (median) | ratio |
|---|---|---|
| SQL deflate | 2.1 | 2.18x |
| zlib L1 / L6 | 0.064 / 0.120 | 4.54x / 5.14x |
| libdeflate L1 / L6 | 0.032 / 0.065 | 4.81x / 5.11x |
| one independent fragment, zlib L1 / L6 | 0.055 / 0.114 | 4.58x / 5.18x |

Per-section fragments (docs/COMPRESSION.md: compress only the changed section, concatenate cached fragments, combine the Adler-32) cost little in ratio:

| Whole packet | ms | ratio |
|---|---|---|
| one stream, zlib L6 | 1.36 | 5.25x |
| 4 KiB fragments, zlib L6 | 1.56 | 5.15x (-2%) |
| 16 KiB fragments, zlib L6 | 1.41 | 5.30x (+1%) |
| 4 KiB fragments, zlib L1 | 0.77 | 4.55x (-1%) vs one stream L1 |
| **reassemble a packet from cached L6 4 KiB fragments**, native Adler-32 of the whole | **0.11** | 5.15x |
| the same, folding cached per-fragment Adler-32 values with `adler32_combine` | 0.13 | 5.15x |

So re-compressing one edited 4 KiB section and reassembling the packet costs about **0.23 ms** (0.114 + 0.11), against 1.36 ms for a whole zlib L6 stream, 0.54 ms
for libdeflate (which cannot make fragments) and 28 ms in SQL. **The fragment scheme is not built into the chunk path**: the functions exist and are tested, the
cache table and the SQL that uses them do not. It pays only for heavy edit traffic (see below).

### Flat chunks (9.3 KB packets)

Native costs 0.06 to 0.08 ms and gives 49x to 64x (about 145 bytes); the SQL general encoder gives 8x at 2.8 ms. The existing template splice (microseconds, a few
hundred bytes per chunk) is better than either in time, so **native is not needed for flat worlds**.

### Concurrency (pgbench, real chunk packets per second; load average 3.3 to 4.4 from other jobs)

| Variant | 1 client | 2 clients | 4 clients |
|---|---|---|---|
| libdeflate L1 | 2,748 /s | 5,170 | 7,590 (2.8x) |
| zlib L6 | 664 /s | 1,283 | 1,505 (2.3x) |
| SQL deflate | 33 /s | 67 | 105 (3.2x) |
| one 4 KiB fragment, zlib L6 | 5,612 /s | 6,334 | 10,448 |

Compression is embarrassingly parallel across backends: no locks are involved. (The 4-client figures were taken while other jobs held the CPUs, so they
understate what an idle 4-core machine would do.)

### What this means at 500 players (arithmetic from the measurements above; the assumptions are stated)

* **Exploration.** A player walking at 4.3 blocks/s enters a new row of 21 chunks (view distance 10) every 16 / 4.3 = 3.7 s, about 5.7 new chunks per second. If all
  500 players walked through never-visited terrain that is 2,800 chunks/s. At the measured rates per core (native L6 through `z_frame` about 1,075 packets/s;
  zlib L6 whole packet about 740/s; SQL about 34/s) that is **2.6 cores native, 3.8 cores zlib and 82 cores in SQL**. At a more realistic 5% exploring
  (140 chunks/s): 0.13 core native against 4.1 cores in SQL. Chunk *generation* (not part of this evaluation: the world is flat) comes on top.
* **A join** sends 441 chunks (view distance 9): 22.7 MB raw, 10.4 MB with the SQL ratio, **4.3 MB native**. With serial AES-CFB8 at the 58 MB/s the Rust benchmark
  measured, that is 392 ms, 179 ms and 74 ms of gateway CPU per joining player, plus the network bytes. A chunk is compressed once and the frame is cached
  (`mc.chunk_cache.packet_z`), so a join storm costs compression only for chunks nobody has had compressed yet: a 10,000-chunk world is 2.9 s of one core with
  libdeflate L1 at the bare-function rate, or about 9 s at L6 through `z_frame`, against about 5 minutes in SQL.
* **Edits.** 10k edits across 100 sections touch about 25 chunks: re-compressing those whole is about 700 ms in SQL, **about 23 ms native** (25 x 0.93 ms);
  with the unbuilt fragment scheme about 14 ms (100 x 0.114 + 25 x 0.11).
* **Per-tick**: nothing here belongs on the tick. Compression happens when a chunk is generated or rebuilt, off the tick (the async queue of `sql/430`); at
  0.9 ms per packet native it could also run inline without a visible stall, which the SQL version (28 ms) cannot.

## What the extension adds to a deployment (the decision)

* **A build step**: `postgresql-server-dev-NN`, `zlib1g-dev` and optionally `libdeflate-dev`, then `make && make install` (files: `dbcraft_zlib.so` in `$libdir`, a
  control file and an SQL script in the extension directory). In Docker: build in a build stage and copy three files into the runtime image.
* **Superuser to `CREATE EXTENSION`**: the control file says `superuser = true`, `trusted = false`. `sql/441` catches the privilege error and stays on SQL.
* **Native code inside the database server process.** A defect in the library or the extension can crash the backend, and Postgres then restarts every session.
  That is the same crash domain as any C extension, and the same worry as running the gateway as an in-process worker. The code is about 280 lines, calls only
  zlib/libdeflate, and has no state, no I/O and no syscalls beyond `malloc`.
* **Not on managed Postgres** (RDS, Cloud SQL and similar do not allow custom extensions).
* **Rebuild for every PostgreSQL major version** (`PG_MODULE_MAGIC` checks it).
* **Memory outside Postgres's accounting**: zlib and libdeflate use `malloc`. About 0.9 MB of resident memory per backend that calls the library at all, plus
  about 0.1 to 0.3 MB per cached compressor (zlib stream about 0.28 MB, libdeflate 0.12 to 0.24 MB; `tests/bench/native/cache_cost.sh`). With the default level that
  is roughly 1.2 MB per backend that compresses; nothing is allocated by backends that never call it.
* **Library versions change output bytes, not validity**: the functions are declared `IMMUTABLE` and the output depends on zlib/libdeflate versions. Cached frames
  (`packet_z`) made by an older build remain valid streams; mixing them is harmless.
* **A plan-cache detail for switching**: Postgres keeps the plan of a SQL function for the length of a transaction, so after `mc.select_deflate(...)` a long
  transaction that already called `mc.z_frame` keeps using the old implementation until it ends. New transactions (every tick) pick the new one up. Run
  `select mc.select_deflate('sql')` before `DROP EXTENSION` (SQL function bodies are not dependency-tracked).

**Adopt it when** compression is switched on for clients that are not on a fast local network (`network-compression-threshold >= 0`), and the world is not purely flat,
and the host allows a custom extension: then it turns compression from "works but costs 28 ms per terrain chunk and 2.2x" into "0.9 ms and 5.3x", it is the
difference between needing about 4 cores and 82 cores for an exploring crowd, and it cuts join bandwidth and gateway encryption work by 2.4x.

**Skip it when** the server is LAN-only or has compression off (threshold -1: nothing is compressed), when the world is flat (the template splice already wins), or when
the database must stay free of native code: the SQL implementation is correct and verified, just 30x slower with less than half the ratio.

## What I did not do

* The per-section fragment cache is not wired into the chunk path (functions only).
* No Windows or macOS build, no packaging, no Docker image.
* No rate-limiting of CPU per call beyond the 16 MiB cap and the interrupt checks.
* The terrain sample is one capture of one area (49 chunks); other biomes (oceans, deserts, caves) will compress differently, and the 4 KiB pieces are not real
  section boundaries.
* The throughput estimates at 500 players are arithmetic on measured per-packet costs with stated assumptions, not a measured 500-player run.

## Reproduce

```
make -C native/dbcraft_zlib && sudo make -C native/dbcraft_zlib install
DBCRAFT_PGDATA=/tmp/dbcraft-pg-zlib DBCRAFT_PGPORT=54433 tools/pg-dev.sh start
export PGHOST=/tmp PGPORT=54433 PGUSER=postgres
DBCRAFT_PGPORT=54433 DBCRAFT_TESTDB=dbcraft_zlib tests/sql/run.sh               # whole suite (911 checks with the extension, 878 without)
tests/bench/native/inflate_java.sh                                             # Java's Inflater over the streams the test wrote
export PGDATABASE=dbcraft_zlib
psql -X -q -f tests/bench/native/setup.sql                                     # real terrain packets and flat packets into schema bench
python3 tests/bench/native/bench.py 9                                          # the tables above (results.json)
python3 tests/bench/native/zframe.py 5                                         # the real mc.z_frame path
tests/bench/native/throughput.sh 6                                             # pgbench, 1/2/4 clients
psql -X -q -f tests/bench/native/leakcheck.sql ; tests/bench/native/cache_cost.sh
```
