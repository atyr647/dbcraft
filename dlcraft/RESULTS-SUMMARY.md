# dlcraft results: Datalevin-native vs PostgreSQL (dbcraft style)

One clean pass of every facet (`tools/clj.sh -M -m main run`, 272 rows, no failures, [results/RESULTS.md](results/RESULTS.md) has all of them) after
`tools/clj.sh -M -m verify` passed **78 of 78** equivalence checks.  In every tick scenario the digest of every outbound frame of every tick was identical
between the two engines, so the two are doing the same work.

**Machine:** 4 vCPU virtual machine, 15 GB, JDK 21, PostgreSQL 16.15 with dbcraft's recommended settings (`shared_buffers=128MB`, `jit=off`, `synchronous_commit=off`),
Datalevin 1.2.10 with the `:nometasync` profile, JVM `-Xms2g -Xmx4g`.  fsync costs about 250 us on this disk.  One run, no repetitions across runs; inside a run most
numbers are medians of 3 to 10 passes.  Single-digit-percent differences are noise; the ones that matter are 2x and up.

## The short version

* **Where Datalevin wins, it wins big, and the reason is mostly structural:** it is a library in the same process, so the world is a byte range you read and write
  directly, and the tick is Clojure code over sorted byte keys.  There is no SQL to interpret, no round trip, no tuple/MVCC overhead per value.
  Tick **4x to 9x faster** at 500 to 2000 players, point reads **58x**, chunk generation **33x**, analytics scans **3x to 42x**.
* **Where PostgreSQL wins**, it is on what a relational database is *for*: full-text search (**10x**), group-by aggregation, indexed lookups, group commit under many
  concurrent strict writers, much smaller memory footprint, and it is the only one of the two that gives a second client a normal way in (`psql`).
* **The sharpest design lesson is internal to Datalevin:** its Datalog layer is for relational data, not hot data.  The same per-tick position update costs
  **0.94 ms as raw KV puts but 16.5 ms as datoms** (PostgreSQL: 2.0 ms), and inventories are **20x slower** as Datalog entities than as one KV record per player.
  The winning design uses both layers in one atomic transaction (`datalog-kv`), which is what `src/dlcraft/` does.
* **Almost every PostgreSQL number here is "the cost of this workload done the dbcraft way in SQL/PL/pgSQL", not a limit of PostgreSQL**; several are the result of one
  agent's tuning effort (see "What to distrust").

## Headline numbers

Lower is better unless stated.  "pg" values are server-side unless marked; where a client round trip is part of the cost it is said.

| facet | Datalevin | PostgreSQL | ratio |
|---|--:|--:|--:|
| generate a chunk (24 sections, noise terrain) | 0.82 ms | 27.4 ms | 33x |
| `get_block`, 100k random, one transaction | 0.88 us | 51.5 us | 58x |
| `set_block`, 50k random, one transaction | 1.9 us | 15.8 us | 8x |
| `set_block`, one commit per call | 2.3 us (nometasync) | 131 us (sync_commit=off, incl. JDBC round trip) | n/a (different boundary) |
| assemble 256 chunk payloads from sections | 6.3 ms | 195 ms | 31x |
| 256 cached chunk packets (a join burst) | 2.2 ms in-process | 1.7 ms server side, 8.1 ms shipped over JDBC | about equal |
| **tick, 100 players, 20% moving** | 1.9 ms (p99 6.8) | 5.1 ms (p99 8.2) | 2.6x |
| **tick, 500 players, 20% moving** | 6.0 ms (p99 11) | 24.0 ms (p99 42) | 4.0x |
| tick, 500 players, 100% moving | 21 ms (p99 33) | 158 ms (p99 254) | 7.5x |
| tick, 500 players, 20% moving + 20 block edits/tick | 7.7 ms | 19.4 ms | 2.5x |
| tick, 500 players **crowded** (~79 in view of each) | 34 ms (p99 47) | 44.7 ms (p99 67) | 1.3x |
| tick, 1000 players, 20% moving | 10.7 ms | 63.9 ms | 6.0x |
| tick, 2000 players, 20% moving | 19.9 ms | 181 ms | 9.1x |
| fill 40^3 (27 partial sections) | 4.5 ms | 92.6 ms | 21x |
| fill 16^3 (one whole section) | 0.81 ms | 0.46 ms | PG 1.8x faster |
| fill 128x32x128 (128 whole sections) | 5.0 ms | 2.0 ms | PG 2.5x faster |
| count blocks by type, 256x256 columns | 428 ms | 1,428 ms | 3.3x |
| find every diamond ore, 256x256 columns | 60 ms | 2,489 ms | 42x |
| water burst, 1600 sources, 70 ticks | 49 ms | 96 ms | 1.9x |
| random ticks over 256 chunks, per tick | 4.2 ms | 546 ms | 130x |
| bulk import of 512 chunks | 70 ms | 209 ms (145 ms COPY alone) | 3x |
| hot rows: 1000 player updates per tick | 0.94 ms (KV) / 16.5 ms (Datalog) | 2.0 ms | KV 2.2x faster, Datalog 8x slower |
| **chat insert, 100-message batches** | 9.1k msg/s | 56k msg/s | PG 6.2x faster |
| **full-text search, newest 20** | 4.9 ms (cache off) | 0.48 ms | PG 10x faster |
| group-by over 50k messages | 7.1 ms (cache off) | 5.6 ms | PG 1.3x faster |
| inventory, 20k clicks in one transaction | 2.3 us (KV) / 44 us (Datalog) | 15.3 us | KV 6.7x faster, Datalog 2.9x slower |
| inventory load (a join) | 3.0 us (KV) / 974 us (Datalog) | 82 us (incl. round trip) | KV 27x faster, Datalog 12x slower |
| who holds item 7 (28k stacks) | 0.85 ms (Datalog AVE) | 1.4 ms (0.15 ms with an index) | PG indexed 5.8x faster |
| resident memory after loading and ticking | 1.7 to 2.0 GB | 160 to 420 MB | PG about 5x smaller |
| size of 512 chunks on disk | 38.5 KB/chunk | 38.7 KB/chunk | equal |

## What the tick numbers mean

The tick is the one facet that resembles dbcraft's real bottleneck.  Datalevin is 4x to 9x faster until the world gets crowded, where it collapses to 1.3x.  That is
informative rather than embarrassing: at 500 players with about 79 in view of each, both engines spend their time building and moving about 40k outbound frames
a tick (every mover's packet to every viewer), which is the same amount of byte shuffling in both.  The advantage Datalevin shows elsewhere is overhead removed; the
crowded case is the part of the tick that has no overhead left to remove.  It also bounds what "database-native logic" can give a Minecraft tick: fan-out cost
is inherent.

Tick latency while other sessions read chunks (500 players, 20% moving): Datalevin's average stayed at 5.0 to 5.6 ms and its p99 went 8.0 to 12 ms with 0 to 3
concurrent chunk readers; PostgreSQL's average went 15.4 to 22 ms and p99 27 to 41 ms.  PostgreSQL's zero-reader baseline moved between 15 and 22 ms across passes of this
benchmark (see noise), so the shape (neither blocks the tick; both degrade slightly as readers share 4 cores) is more reliable than the exact figure.

## The idle reader ("psql left open")

dbcraft's own docs identify this as PostgreSQL's real weakness.  Reproduced: with a transaction left open, the same 1000-row update goes from **2.3 ms to 25 ms** per tick
within 200 ticks and the table from 0.3 to 14.2 MB.  Datalevin (LMDB) with a read transaction held open (a lazy `range-seq`) shows the same **file growth, 0.3 to 14.2 MB**,
because LMDB cannot reuse pages an old reader can still see, but **latency stayed flat (0.92 to 1.0 ms)**.  So the failure mode is different, not absent: PostgreSQL gets slow
and bloated, LMDB stays fast and grows until the map is full.  (dbcraft mitigates PostgreSQL's with `idle_in_transaction_session_timeout`; LMDB has no equivalent that I used.)

## Durability and crashes

* **Commit latency, one edit per commit:** Datalevin `:sync` 420 us (p99 1.2 ms), `:nometasync` 266 us, `:nosync` 14 us, WAL strict 727 us, WAL relaxed 288 us.
  PostgreSQL `synchronous_commit=on` 492 us (p99 1.1 ms), `off` 136 us, `fsync=off` 136 us (all including a JDBC round trip).  PostgreSQL's relaxed mode is cheaper per commit
  than any Datalevin mode that fsyncs, because it returns before flushing; the Datalevin equivalent that does not fsync is `:nosync`, which is unsafe against an OS crash.
* **Concurrent single-commit writers:** PostgreSQL scales with writers (group commit): strict 3.5k, 12k, 17.6k commits/s at 1, 4, 8 writers; relaxed 6.7k, 21.7k, 27.5k.
  Datalevin `:sync` 7.6k, 14k, 22.7k; `:nometasync` stays at 9 to 13k (one serialised writer); WAL strict 3.3k, 9.1k, 17k.  Neither is clearly ahead; both are far above a Minecraft server's need (one tick = one commit).
* **`kill -9` of the whole server (the OS survives, so this is process crash, not power loss):** Datalevin lost **0** acknowledged commits under `:sync`, `:nometasync` and WAL relaxed
  (about 7.6k to 12k acknowledged each) and reopened in 12 to 13 ms (220 ms for WAL replay).  PostgreSQL strict lost 0 of 6,021; **PostgreSQL relaxed (dbcraft's setting) lost 5 of 15,970**,
  the window `synchronous_commit=off` documents (unflushed WAL dies with the process).  Restart with crash recovery took about 290 ms.
  **Not measured: power loss.**  A VM cannot tell you what an fsync really guarantees, so `:nometasync`'s "may lose the last commit but not corrupt" and PostgreSQL's equivalent are as documented, not tested.

## Which Datalevin design choices mattered (and what bit me)

* **Same transaction across Datalog and KV** (`datalog-kv`) works as documented and is what makes a tick atomic.  Keep hot data out of datoms (above).
* **Datalevin's index-result cache makes repeated identical queries absurdly fast** (a search that costs 4.9 ms uncached shows as 0.3 ms, "last 50 messages" as 2.5 us).  My first pass benchmarked
  the cache.  The tables above use the cache-disabled numbers (`datalog-index-cache-limit` 0); `RESULTS.md` has both, labelled.  A real server issuing varied queries between writes is closer to the uncached figure.
* **Full-text `fulltext` returns the top 10 by default** and silently truncates: pass `{:top n}`.  It also drops English stop words.  My equivalence test caught the first.
* **WAL mode is much slower for bulk writes** in one probe (20,000 puts of 2.7 KB values in one transaction: 2.5 s versus 0.22 s without WAL); the WAL profiles are slower in the commit-latency table too.
  I did not investigate further; treat as "measure before using WAL for big batches".
* **`transact-kv` arity**: key/value types go per operation when the operations name their own tables, or as trailing arguments when one table is named once.  Getting it wrong gives a misleading "is not open" error.

## What to distrust

1. **The PostgreSQL side is a re-implementation, not dbcraft.**  It follows dbcraft's patterns and settings but is 700 lines written for this experiment, in about 50 minutes of an agent's time with
   byte-identical equivalence as the hard constraint.  dbcraft's real tick does far more (light, heightmaps, survival, containers), so none of these are dbcraft's tick times.
2. **Several large ratios come from implementation effort, not the engine.**  `random ticks` (130x), `find every diamond` (42x) and chunk generation (33x) reflect that the Datalevin version reads
   section headers (palette skip) and works on bytes in a tuned loop, while the PostgreSQL version unpacks through SQL.  dbcraft itself reaches about 4 ms per chunk with a native C accelerator,
   which this PostgreSQL side deliberately does not use; a native-extension PostgreSQL would close much of the generation gap.  Conversely, the fills where PostgreSQL wins (whole-section) are a
   Datalevin implementation inefficiency: it parses and compares before replacing, PostgreSQL just writes.
3. **In-process versus server.**  Datalevin never crosses a socket; the rows marked "round trip" or "shipped" are where PostgreSQL pays for that, and they are labelled, but the in-DB loops
   (PL/pgSQL, one statement per tick) are the fair server-side comparison.  The tick numbers include one `select mc.server_tick()` round trip for PostgreSQL (about 0.1 ms) and zero for Datalevin.
4. **Datalevin's memory is a JVM's.**  RSS includes the mapped LMDB file, a 2 GB initial heap and the JVM itself (heap *used* was under 120 MB throughout).  PostgreSQL's RSS excludes the OS page cache that holds
   its data.  The 5x gap overstates the true cost difference but the JVM floor is real.
5. **One inconsistency I could not explain.**  In the very first full pass (before several harness fixes) the dynamics facet reported different per-tick results between the engines and a Datalevin burst
   time of 355 ms.  Two later runs and the clean final pass produced identical results and 48 to 49 ms.  I never found the cause, and the first pass also had other harness bugs, so I discarded it.
   The final pass reran everything from an empty world.
6. **The workload is synthetic.**  Players do a bounded random walk; there are no mobs, no redstone, no light engine, no real clients and no protocol handshake.  Block states, ores and palette sizes are the experiment's own.
7. **A shared, noisy 4-core VM.**  PostgreSQL's zero-reader tick baseline varied 15 to 22 ms between passes.  Treat ratios under about 1.5x as ties.

## What I would do next

* Put the Datalevin tick behind a real protocol front end (reusing dbcraft's Rust gateway through the same inbox/outbox contract) and run a real client.
* Give PostgreSQL its native accelerators (dbcraft's `dbcraft_set` and `dbcraft_zlib`) and a palette-skip `find_state`, then repeat the world facets.
* Repeat the whole matrix three times on quieter hardware and report ranges.
* Try Datalevin's client/server mode and HA to see what the "no round trip" advantage costs once the database is shared.
