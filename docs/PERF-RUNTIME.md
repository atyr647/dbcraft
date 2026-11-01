# Runtime: the same SQL on a PGO-built PostgreSQL

**Question.** The tick is CPU-bound executor and PL/pgSQL work on one core. How much faster does it run on a PostgreSQL built for speed (profile-guided optimisation,
`-O3 -march=native`, LTO) than on the distro's 16.15 binary?

**Answer.** About **1.2x to 1.5x less CPU time** on every workload measured, with the PGO build. Plain `-O2` from the same source is no different from the distro binary, and
`-O3 -march=native` + LTO without PGO gives about 1.1x to 1.2x. The speedup is robust: on the three tick workloads the PGO build's CPU-time range does not overlap the distro's.

Scope: only the **distro route** was used: the source is the distro's own patched `postgresql-16` 16.15 package (`apt` `deb-src`), the same version and patches as the binary
in use. Nothing was downloaded from elsewhere; PostgreSQL 17/18 was **not** tested.

## What was built

All from `/tmp/pgsrc-distro/postgresql-16-16.15` (fetched by `tools/pgbuild/fetch_src.sh`), out-of-tree, under `nice -n 15`, installed under `/tmp/pg-runtime-<variant>` only
(never system-wide). Common configure options: `--without-icu --without-llvm --with-openssl --with-zlib` (no JIT: the tick runs with `jit=off` anyway; no plpython3: only the
development gateway needs it).

| Variant | Flags | Notes |
|---|---|---|
| **A** | the distro binary `/usr/lib/postgresql/16/bin` | Ubuntu 16.15-0ubuntu0.24.04.1, its own flags (hardening) and configure options (ICU, LLVM, lz4, zstd ...) |
| **B** | `CFLAGS="-O2"` | control: the same source with plain flags |
| **C** | `CFLAGS="-O3 -march=native -fno-plt -flto=auto" LDFLAGS="-flto=auto"` | |
| **D** | C plus PGO, see below | built twice: D1 instrumented, D2 final |

PGO (`tools/pgbuild/build_variant.sh D1`, `train.sh`, `build_variant.sh D2`):

1. **D1**: C plus `-fprofile-generate=/tmp/pgbuild/pgo-data`. PostgreSQL's own libpq check ("libpq must not be calling any function which invokes exit") rejects the
   profiling runtime's exit handler; the script marks that one check done for D1 only (libpq itself has been built by then).
2. **Training** (`tools/pgbuild/train.sh`, on the instrumented server, which is about 2.7x slower than a normal build): the whole server tick for 500 players all moving (150 ticks), 500 players
   20% moving (100 ticks) and 2,000 players with view distance 5 (60 ticks); 40 x the 441-chunk cached read; 20,000 `mc.set_block` calls; 12 x `mc.generate_batch` of 64 chunks.
   Result: 815 profile files, 4.1 MB. (The directory must be writable by the `postgres` user: the first training run collected nothing because it was root-owned.)
3. **D2**: C plus `-fprofile-use=/tmp/pgbuild/pgo-data -fprofile-correction -Wno-missing-profile -Wno-error=coverage-mismatch`, in the same build directory name (gcc names profile
   files after the object path).

D2 was rebuilt once with `--with-lz4 --with-zstd` after the first suite run failed only in `tests/sql/291_section_compression.sql` ("compression method lz4 not supported": the
distro binary has lz4, my first build did not). The profile was trained before that, so the handful of functions in `src/common/compression.c` whose control flow changed with the new
configure options simply have no profile (gcc warns for them). **B, C and the first D2 were built without lz4/zstd**; the benchmarks never use them (`default_toast_compression` is pglz).

Exact configure line of D2:

```
/tmp/pgsrc-distro/postgresql-16-16.15/configure --prefix=/tmp/pg-runtime-D2 --without-icu --without-llvm --with-openssl --with-zlib --with-lz4 --with-zstd \
  CFLAGS='-O3 -march=native -fno-plt -flto=auto -fprofile-use=/tmp/pgbuild/pgo-data -fprofile-correction -Wno-missing-profile -Wno-error=coverage-mismatch' LDFLAGS='-flto=auto'
```

## How it was measured

One shared, **warmed** database (34,625 chunks generated and with cached packets, built once with variant B so every variant starts from identical data, `tools/pgbuild/setup_base.sh`), copied
byte for byte to one data directory per variant. Identical server settings for all (`tools/pgbuild/cluster.sh`: `fsync=off synchronous_commit=off shared_buffers=256MB jit=off autovacuum_naptime=1s`).
Metric: the backend's **on-CPU time** from `/proc/self/schedstat`, per tick or per call (wall time is inflated by the other jobs on the 4 shared CPUs; on-CPU time barely moves).
Variants were **interleaved**: in every round the order of the variants was freshly shuffled. 80 ticks per tick run, the first 20 dropped. Workloads: `t500_all` 500 players over 100x100 chunks all
moving, view distance 10; `t500_20` the same with 20% moving; `t2000` 2,000 players over 160x160 chunks, view distance 5; `join441` 441 cached chunk packet bodies; `setblock` `mc.set_block` at random
positions (one transaction, plans warm); `gen64` `mc.generate_batch` of 64 chunks. Raw lines: `tests/bench/runtime/results/`. Analysis: `tools/pgbuild/analyze.py`.

## Results

Main run: 5 rounds, A/B/C/D. Median (min-max) of the per-round values; **load average at the start of the runs: median 4.6, min 3.4, max 6.9** on 4 CPUs: everything below carries that noise.
Speedup = median(A) / median(variant): above 1 means less CPU time than the distro binary.

| workload | metric | A distro | B -O2 | C -O3+LTO | D PGO | speedup vs A: B, C, D |
|---|---|---|---|---|---|---|
| t500_all | cpu avg ms/tick | 32.80 (31.10-37.70) | 33.80 (31.60-38.10) | 27.80 (25.40-32.80) | **24.30 (23.60-25.90)** | 0.97x, 1.18x, **1.35x** |
| t500_all | cpu p99 | 54.80 (44.50-59.40) | 54.30 (49.80-59.60) | 44.20 (34.10-47.90) | **37.50 (35.60-41.80)** | 1.01x, 1.24x, **1.46x** |
| t500_20 | cpu avg | 12.70 (11.40-13.90) | 13.80 (10.80-17.90) | 11.20 (9.10-12.10) | **9.40 (9.00-10.00)** | 0.92x, 1.13x, **1.35x** |
| t500_20 | cpu p99 | 24.40 (22.60-26.30) | 26.10 (19.60-29.10) | 19.00 (17.50-24.00) | **18.40 (15.80-30.20)** | 0.94x, 1.28x, **1.33x** |
| t2000 | cpu avg | 97.90 (93.50-106.80) | 96.20 (95.10-108.70) | 84.10 (80.20-101.10) | **68.80 (65.90-71.10)** | 1.02x, 1.16x, **1.42x** |
| t2000 | cpu p99 | 144.60 (133.90-174.80) | 141.60 (133.00-160.70) | 121.20 (106.30-135.90) | **100.70 (84.40-107.90)** | 1.02x, 1.19x, **1.44x** |
| join441 | ms per 441 chunks | 112.88 (105.88-156.41) | 120.99 (102.58-132.37) | 99.16 (89.90-117.42) | **81.35 (61.96-96.78)** | 0.93x, 1.14x, **1.39x** |
| setblock | us per call | 13.29 (11.80-171.74) | 12.10 (10.78-250.80) | 13.27 (10.61-191.26) | **9.78 (8.00-169.06)** | 1.10x, 1.00x, **1.36x** |
| gen64 | ms per 64 chunks | 13.90 (11.53-15.98) | 11.81 (7.91-12.00) | 11.81 (10.54-13.92) | **10.97 (9.62-11.77)** | 1.18x, 1.18x, **1.27x** |

Re-check after rebuilding D2 with lz4/zstd: 3 rounds, A and D only, load 4.1-4.7:

| workload | metric | A | D | speedup |
|---|---|---|---|---|
| t500_all | cpu avg / p99 | 29.40 / 46.70 | 23.90 / 37.40 | 1.23x / 1.25x |
| t500_20 | cpu avg / p99 | 10.30 / 19.30 | 8.30 / 16.50 | 1.24x / 1.17x |
| t2000 | cpu avg / p99 | 101.00 / 135.70 | 69.20 / 96.70 | 1.46x / 1.40x |
| join441 | ms | 108.55 | 80.46 | 1.35x |
| setblock | us per call | 11.99 | 7.99 | 1.50x |
| gen64 | ms | 14.36 | 11.84 | 1.21x |

Reading it:

* **PGO is what matters.** B (plain -O2) is the distro's speed within noise (0.92x to 1.10x). C (O3, native, LTO without a profile) gains 1.0x to 1.2x. D gains **1.2x to 1.5x**, and the rebuilt D confirms it.
* **The gain grows with the work per tick:** 1.2x to 1.35x at 500 players, 1.4x to 1.46x at 2,000, where the tick is almost entirely PL/pgSQL and executor code, the profile's best case.
* **Tail:** p99 improves as much as the mean (1.17x to 1.46x), so ticks that spike are not hiding behind the average.
* `setblock` is a warm loop inside one transaction (about 8-13 us per call); it is **not** comparable to the 230-330 us per edit that `docs/PERF-EDIT.md` measures with one transaction per edit. The maxima (170-250 us) are the first
  call in a round. The ranges are wide, so treat that row as the weakest.

### Whole test suite

| | wall time | checks | notes |
|---|---|---|---|
| A distro | 2,264 s | 1,265 pass | load at the end 4.9; includes the 33 checks of `tests/sql/441_deflate_native.sql`, which run only where the `dbcraft_zlib` extension is installed (it is, system-wide, for the distro binary) |
| D PGO | 1,263 s | 1,232 pass | load at the end 3.6; no extension, so those checks are skipped |

Both runs pass completely (exit 0, structural checks green) with `jit=off` forced on both through `PGOPTIONS` (the distro binary has LLVM JIT and would otherwise default to `jit=on`; the custom builds have none).
**Treat the wall times as indicative only**: the two runs saw different loads, and the 1.8x difference is larger than the CPU-time gain, so most of it is the machine, not the build. The identity result is what counts:
the PGO build produces the same results (every check, including the byte-exact comparisons against recorded vanilla traffic, passes).

## Deployment cost (what adopting it means)

* **A custom PostgreSQL instead of the distro package.** Security and bug-fix releases (16.x) become your job: rebuild on each. A stale profile still works for a minor release (the build tolerates mismatches, as above),
  but retrain when the SQL changes a lot.
* **Build time:** roughly 5-10 minutes per compile on this loaded machine, two compiles for PGO plus a training run of about 10 minutes: plan on **45-60 minutes** on 4 busy cores, perhaps half on an idle build host. A Docker image
  needs a multi-stage build (build stage with compilers, final stage with the installed tree).
* **`-march=native` ties the binary to the build machine's CPU family.** Do not build on one host and run on an older one. Use a fixed baseline such as `-march=x86-64-v3` for a portable image: **not measured here**, expect a
  little less than the native gain.
* **No JIT, no ICU, no plpython3 in these builds.** Production needs none of them (the real gateway is a separate program); the development gateway needs `--with-python`. ICU matters only if you use ICU collations: dbcraft uses none.
* Reproduce: `tools/pgbuild/fetch_src.sh`; `tools/pgbuild/build_variant.sh B|C|D1`; `tools/pgbuild/train.sh`; `tools/pgbuild/build_variant.sh D2`; `tools/pgbuild/setup_base.sh`; `tools/pgbuild/bench_all.sh 5 "A B C D" out.txt`;
  `tools/pgbuild/suite_time.sh A|D`. `tools/pg-dev.sh` accepts `DBCRAFT_PGBIN` for another build's `bin` directory.

## Recommendation

**Offer the PGO build as an optional production build, not the default, and keep developing on the distro package.** A 1.2x to 1.5x cut of CPU time on a single-core tick is as large as the best SQL-level optimisations so far,
for no change to the SQL and no change in results. The price is owning a PostgreSQL build (rebuild per release, CPU-specific unless a baseline is chosen). If the tick budget is the binding constraint, build it; if the gateway or the
world work is, it does not help.

## Limits and not done

* PostgreSQL 17 and 18 were **not** tried (distro-source route only).
* Huge pages: **not tested.** `HugePages_Total` is 0 on this kernel and reserving them is a system-wide setting; the clusters ran with `huge_pages=try` (no effect). Transparent huge pages are in `madvise` mode, which
  PostgreSQL does not use.
* Noise: the machine had load 3.4 to 6.9 on 4 CPUs the whole time. CPU time was used instead of wall time, runs were interleaved and shuffled, but ranges are wide for `setblock` and the tails.
* B, C and the first D2 lack lz4/zstd (see above); the final D2 has them, but its profile predates that.
* The profile covers the workloads listed; paths not exercised in training (login storms, commands, the batched tick `mc.server_tick_batched`, compression) run at the unprofiled speed of variant C at best.
* A second `perf stat`/instruction-count measurement was not possible (`perf` is not installed).
