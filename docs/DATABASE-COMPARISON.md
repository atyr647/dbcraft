# Database comparison for dbcraft

Question: is PostgreSQL the right database, given the constraint that game logic lives in the database
(stored procedures, triggers, set-based SQL), the gateway stays tiny, and everything is readable rows?

**Short answer: yes, stay with PostgreSQL, but only with the tuning below.**  Untuned it loses to MariaDB on update
speed.  No engine here measured well on parallel writes, so the "region sharding across connections" idea
is unproven (see Open problems).

## What was measured

Same machine, same Python harness (`tests/bench/db/run_bench.py`, SQL in `tests/bench/db/sql/`, raw numbers in
`tests/bench/db/results.json`).  4 vCPU Xeon @ 2.1 GHz container, 16 GB RAM.  Every row has different input
(no constant folding).  All five engines computed the **same checksum** (164162695881) for the varint test, so the
work is equivalent.

| Engine | Version | How it ran |
|---|---|---|
| PostgreSQL | 16.15 | dev cluster, unix socket, `fsync=off`, `synchronous_commit=off`, `jit=off` |
| MariaDB | 10.11.14 | InnoDB, unix socket, `innodb_flush_log_at_trx_commit=0`, 1 GB buffer pool |
| Firebird | 3.0.11 (only 3.0 is in apt) | SuperServer over TCP loopback, forced writes off |
| SQLite | 3.53.1 | in-process, WAL, `synchronous=off` |
| DuckDB | 2.0.0 (pip) | in-process, file database |

Times include the client round trip (Python driver).  Firebird used TCP loopback, the others unix sockets or
in-process, which slightly disadvantages Firebird.  Medians of 3-7 runs, single machine, noisy: treat differences under
about 1.5x as ties.

### Results (ms unless noted; lower is better)

PostgreSQL appears twice: **default** (fillfactor 100) and **tuned** (fillfactor 60, no index on hot columns).

| Workload | PG default | **PG tuned** | MariaDB | Firebird | SQLite | DuckDB |
|---|---|---|---|---|---|---|
| (a) set-based `UPDATE` of 10k players | 62 | **8.9** | 9.9 | 65 | 3.0 | 3.9 |
| (b) per-row loop in a stored procedure, 10k rows | 129 | **46** | 107 | 78 | no procedures (client loop: 49) | no procedures |
| (c1) varint decode, 200k rows, stored function with a byte loop | 185 | **162** | 1405 | 454 | n/a | n/a |
| (c3) varint decode, 200k rows, plain inline SQL expression | 22 | **24** | 52 | 205 | 376 | 61 |
| (d) bulk load 10k rows (best native path used) | 9.1 (`COPY`) | **8.5** | 31 (`LOAD DATA`) | 3077 (row inserts) | 5.6 | 10102 (row inserts) |
| load 200k varint rows | 0.72 s | **0.44 s** | 0.95 s | 43 s | 0.39 s | 0.33 s (CSV) |

Reading it:
* **Stored-function speed is where Postgres wins clearly**: its PL/pgSQL byte loop is 8.7x faster than MariaDB's stored
  function and 2.8x faster than Firebird's.  This is the path game logic would use.
* The fast "inline expression" form is again Postgres (22 ms), roughly 2x MariaDB and 9x Firebird.
* Postgres `COPY` is the only bulk path here that is both fast and in the server's native tooling.  Firebird has no
  `COPY`; I did not try its external tables or `EXECUTE BLOCK` batching, so its 3 s is the naive path, not necessarily its best.
  DuckDB's 10 s is also the wrong path (its bulk path, CSV, loaded 200k rows in 0.33 s).
* SQLite and DuckDB are fastest on raw updates because they are in-process with no network hop, but they have no
  server, no stored procedures, and one writer.  They show the ceiling, not a candidate.

### Update churn (MVCC): 100 rounds of updating the same 10k rows

| Variant | Round 1 | Round 50 | Round 100 | Total | Size before -> after |
|---|---|---|---|---|---|
| PG default (fillfactor 100) | 47 ms | 31 ms | 38 ms | 5.4 s | 1.0 -> **67.8 MB** (bloat) |
| **PG tuned** (fillfactor 60, HOT) | 19 ms | 8.6 ms | 13.7 ms | 1.0 s | 1.5 -> 2.2 MB |
| PG tuned + index on a hot column (`tick`) | 44 ms | 62 ms | 50 ms | 5.9 s | 1.6 -> 44 MB |
| MariaDB (InnoDB) | 13 ms | 13 ms | 16 ms | 1.6 s | table flat; data directory grew 64 MB in the first run (log files, cause not isolated) |
| Firebird | 31 ms | 70 ms | 74 ms | 7.7 s | flat at 15.7 MB (cooperative GC), but rounds slow down |
| SQLite (WAL) | 1.7 ms | 1.5 ms | 1.4 ms | 0.16 s | 3.9 -> 7.7 MB |
| DuckDB | 4.3 ms | 3.1 ms | 3.9 ms | 0.44 s | flat |

**With a long-lived reader open** (someone leaves a SQL tool open in a transaction, which is exactly what "edit the
world with SQL" invites):

| Engine | Round 1 | Round 100 | Size / growth |
|---|---|---|---|
| **PostgreSQL tuned** | 19 ms | **335 ms** | 1.5 -> **77.6 MB** |
| PostgreSQL default | 59 ms | 384 ms | 1.0 -> 83.5 MB |
| MariaDB | 13 ms | 13 ms | flat latency |
| Firebird | 48 ms | 36 ms | 15.7 -> 44.5 MB |
| SQLite (WAL) | 1.4 ms | 3.0 ms | 7.7 -> 36 MB |

This is Postgres's real weakness for this project: **an idle-in-transaction session makes every update 17x slower
within 100 ticks (5 seconds of game time)**, because dead row versions cannot be cleaned up.  MariaDB's undo log
handled the same situation with flat latency.  Mitigations (not measured): `idle_in_transaction_session_timeout`,
`transaction_timeout` (PG 17+), and pointing admin tools at a read replica or using `autocommit`.

### Parallel updates (region sharding): all engines measured poorly

4 worker processes, each updating its own 10k-row region, 20 rounds, versus 1 worker (speedup 4.0 = perfect):

| Engine | Regions as rows of one table | One table per region |
|---|---|---|
| PostgreSQL tuned | 0.81x | 0.49x |
| PostgreSQL default | 1.25x | not run |
| MariaDB | 0.93x | 0.95x |
| MariaDB `READ COMMITTED` | 0.77x | not run |
| Firebird | 0.48x | not run |
| SQLite | 0.74x | 1.48x |
| DuckDB | not run (single process) | not run |

This is a surprising and **unexplained** result.  What I ruled out for Postgres: the container does have 4 usable cores (4 CPU-bound
processes finish as fast as 1; a pure-CPU Postgres query scaled 3.2x on 4 sessions); the Python harness is not the cause
(plain `psql` sessions gave 1.5x); it is not table sharing (separate tables did no better); and it is not WAL (`UNLOGGED`
tables gave 1.6x).  I did not find the cause.  Candidates: memory and lock behaviour of this virtualized container, or
update-heavy workloads genuinely scaling badly at this tiny size (10k rows, 12 ms of work per round).
**Do not rely on parallel region ticking until it is re-measured on real multi-core hardware with a larger workload.**

## Feature checklist

M = measured here.  D = from documentation or knowledge, not measured.

| Feature | PostgreSQL | MariaDB | Firebird 3.0 | SQLite | DuckDB |
|---|---|---|---|---|---|
| Push change notifications to a client | `LISTEN/NOTIFY` (D) | none built in; binlog or a plugin (D) | events: `POST_EVENT` and client event listeners (D) | in-process update hook only (D) | none (D) |
| Native extension / background worker that could run a TCP listener and call SQL on a timer | **yes**: C or Rust background workers with SPI (D) | plugin API allows daemon threads, awkward (D) | UDR external engine plugins, no worker concept (D) | loadable extension, in-process (D) | extensions, in-process (D) |
| Binary type with byte get/set/slice/overlay | `bytea`: `get_byte`, `set_byte`, `substring`, `overlay` (M for get_byte/set_byte) | `VARBINARY`: `SUBSTR`, `ORD`, `INSERT()`; no `set_byte` (M for ORD/SUBSTR) | no `BINARY` type in 3.0, uses `VARCHAR CHARACTER SET OCTETS` with `ASCII_VAL`, `SUBSTRING`, `OVERLAY`, `BIN_*` (M) | `BLOB`: `substr`, `hex`; no byte accessors (M) | `BLOB`: `hex`, `from_hex` (M) |
| Declarative partitioning | yes (D) | yes (D) | no (D) | no | no |
| Parallel query | yes (M: 3.2x on a CPU-bound query) | no intra-query parallelism (D) | no in 3.0 (D) | no | yes |
| Unlogged or in-memory tables | `UNLOGGED` (M, used); in-memory only via tmpfs (D) | `MEMORY` engine, table locks, no BLOB (D) | none (global temp tables are per-connection) (D) | `:memory:` database (D) | in-memory database (D) |
| Stored-procedure language speed | **fastest measured** (M) | slowest measured, 8.7x behind PG (M) | middle (M) | no stored procedures | macros only |
| 20 Hz tick across many connections in parallel | measured poorly in this container (M) | measured poorly (M) | measured poorly (M) | single writer (M) | single process |

## Other candidates (not measured)

| Candidate | Why it was not installed or measured |
|---|---|
| **SpacetimeDB** | Researched only.  It hosts game logic as WebAssembly/V8 modules in Rust, C# or TypeScript, not SQL ([docs](https://spacetimedb.com/docs/index), [module languages](https://spacetimedb.com/docs/databases)).  Reducers are atomic transactions, ticks are scheduled-reducer tables, and clients get pushed row changes through subscriptions.  Its docs say BitCraft Online's backend runs on it.  Unofficial notes say reducers are serialized (single writer) and BitCraft scales by running one module per region; I could not verify that against Clockwork Labs sources.  It stores rows and could be queried, but game logic would live in Rust or C# modules, not SQL, which breaks the stated constraint.  A Minecraft client also cannot speak to it, so a gateway is still needed. |
| CockroachDB / Yugabyte | Distributed SQL with millisecond-scale commit latency per transaction, built for horizontal scale rather than a 50 ms tick; no background-worker extension story (D, not measured). |
| SQL Server / Oracle | Licensed and heavyweight; Oracle PL/SQL is strong but the licensing and deployment cost do not fit a hobby homebrew server (D, not measured). |
| VoltDB / in-memory partitioned SQL engines | Conceptually closest to a tick engine (partitioned, single-threaded stored procedures in Java), but their stored procedures are Java, not SQL, and I could not confirm current open-source availability (D, not measured). |

## Ranking and recommendation

1. **PostgreSQL (tuned)**: best stored-function and expression speed, best bulk load (`COPY`), `bytea` with `set_byte`, `LISTEN/NOTIFY`,
   background workers, partitioning, parallel query.  Costs: needs the tuning below, and an idle transaction hurts badly.
2. **MariaDB**: matches tuned Postgres on set-based updates (9.9 ms) and is the only engine whose latency stayed flat with an
   open reader, but its stored functions are 8.7x slower, bulk load is 4x slower, and it has no notifications or
   `set_byte`.  A credible fallback only if game logic moves out of stored procedures.
3. **Firebird 3.0**: works, and cleans up old row versions without a vacuum job, but update speed, bulk load (3 s for 10k
   rows by the naive path), no partitioning and worst parallel result rule it out.  Firebird 4.0 might change some of this; it was not available in apt, so not measured.
4. **SQLite / DuckDB**: fastest raw updates, but embedded single-process engines with no stored procedures.  Wrong shape for "SQL is the server".

**Tuning the recommendation depends on:**
* `fillfactor` around 60 on hot tables (players, entities).  Measured: 62 ms -> 8.9 ms per 10k-row update, and 68 MB of bloat -> 2 MB.
* **No index on any column that changes every tick** (position, tick counter).  Measured: an index on `tick` costs 6x and 20x the size.
* Use `idle_in_transaction_session_timeout` and keep admin tools out of long transactions.

**Honest caveats:**
* Single runs of small workloads on one noisy 4-vCPU container; differences under about 1.5x are not conclusions.
* Parallel write scaling was poor for every engine and the cause is unknown, so the Folia-style "tick regions on separate connections"
  advantage is not demonstrated.  One connection doing 10k player updates in 9 ms already fits a 50 ms tick for 500 players.
* Firebird was measured over TCP and the naive bulk path; DuckDB over its slow row-insert path; SpacetimeDB and the
  distributed engines were not measured at all.
* All engines ran with durability relaxed (fsync or flush off) to compare engine cost rather than disk speed.

## Reproduce

```
tools/pg-dev.sh start
pip install psycopg2-binary pymysql firebird-driver duckdb
python3 -I tests/bench/db/run_bench.py pg mariadb firebird sqlite duckdb   # DB_FF=60 for tuned Postgres, DB_MARIA_RC=1 for READ COMMITTED
python3 -I tests/bench/db/run_bench.py --par-sep pg mariadb sqlite          # one table per region
```

MariaDB and Firebird need local instances (see the top of `run_bench.py` for the sockets and ports used): MariaDB on
`/tmp/mdb/sock`, Firebird SuperServer on `127.0.0.1:/tmp/fb/bench.fdb`, user `SYSDBA`, password `masterkey`.
