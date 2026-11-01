# Elixir/BEAM as the gateway language: measurements against Rust, Go and Tcl

Question: is Elixir/Erlang (the BEAM) a good language for the tiny dbcraft gateway (sockets, framing, AES-CFB8, zlib, batching to Postgres, the Mojang call), on the same
workloads as `docs/TCL-EVALUATION.md` (Rust and Tcl) and `docs/GO-EVALUATION.md` (Go)?

This document was **redone once**: the first run happened while three other benchmark forks loaded the CPUs; the second run (this text) is on a much quieter machine, with
`uptime`, load and CPU pressure recorded before every run and medians of 5 where tick latency is the metric.  "What changed" below lists every number that moved.

**Short answer: viable, but about 1.8x to 3x fewer players per core than Rust and 1.3x to 2.2x fewer than Go, and in return it gives the best fault isolation of the lot.**
The BEAM is 3.5x to 17x slower than Rust on pure parsing.  `:crypto` (OpenSSL) encrypts CFB8 at 49 MB/s against Rust's 74 (1.5x slower; an earlier "tie" does not hold up).
One BEAM process per connection costs about 12 KB, 19,000 connections served 1.5 million frames/s on three scheduler threads, and killing 240 connection processes under load did not disturb
the rest.  Things to watch: the tick process **must run at high priority** (at normal priority the tick's p99 lateness had a median of 52 ms at 5,000 saturated connections, against 5.5 ms at high priority),
message passing between processes gets slower with more schedulers (the socket-owning process must parse its own frames), and `:httpc` serialises concurrent HTTPS calls (use your own pool of TLS connections).

## What changed versus the first run

| item | first run | rerun |
|---|---|---|
| machine | load 1.8 to 6, CPU pressure 0.06% to 49% | load 0.5 to 3.3, pressure 0.1% to 25% (3 background workers; the value is printed with each run) |
| Rust AES-CFB8 encrypt / decrypt | 59.9 / 515.7 MB/s | **73.9 / 668.1 MB/s** (Rust ran faster on the quiet machine; Rust players per core 2,855 -> 3,517) |
| Elixir AES-CFB8 encrypt, 1 MiB | 61.9 MB/s ("ties Rust") | **49.1 MB/s** (1.5x slower than Rust; the per-call pattern gave 49.2 MB/s in both runs, so 49 is the stable figure and 61.9 was a lucky repetition) |
| Elixir parsing rows | e.g. VarInt decode 59.7 M/s | 51.2 M/s (same order, 10 to 15% lower) |
| Elixir players per core (gateway work only) | 1,136 to 1,878 | 1,165 to 1,905 |
| four-copy scaling on `+S 4` | 2.3x to 3.4x | **3.2x to 4.0x** for parsing and crypto (the first run was contended); message passing 0.69x -> 0.80x |
| tick lateness, normal priority, 5,000 connections | one run: p99 133 ms, then 6.2 ms ("unexplained outlier") | **5 runs: p99 14 to 117 ms, median 51.8 ms**; the outlier was real |
| tick lateness, high priority, 5,000 connections | p99 1.4 to 12 ms | 5 runs: p99 1.8 to 6.3 ms, median 5.5 ms |
| cost of a 1 GB process in 3.6 to 5.1 s full-sweep GCs | "tick worst case 10 to 50 ms higher" (contended) | **about +4 ms**: p99 median 8.5 against 4.3 ms, max 10.8 against 6.6 ms, throughput about 5% lower |
| 1 GB as off-heap binaries, 19,000 connections | 0.55 M frames/s, p99 64 ms, max 138 ms (marked unreliable) | **not reproduced**: 3 runs at 1.55 to 1.67 M frames/s, p99 3.3 to 6.9 ms; the first result was contention |
| "GC off" control pair 3 (no connections) | failed run | replaced by 3 complete on/off pairs |
| Postgres consume step | `DELETE ... RETURNING` 19.9 ms, "TRUNCATE not tested" | `DELETE` degrades with repeated runs (14 -> 55 -> 108 ms); **`TRUNCATE` keeps up at 5,000 connections (22.5 ms busy)** |
| multi-row `INSERT ... VALUES` | not measured | **10x slower than COPY** (50 to 66 ms for 10,000 packets) |
| Mojang session-server call pattern | not tested | measured against a local TLS stub (never Mojang): see below |

## Setup

Linux x86-64, 4 cores, **Elixir 1.14.0 on Erlang/OTP 25 (ERTS 13.2.2.5, JIT)** from apt (`erlang-base elixir`), Rust 1.97 release build from `tests/bench/tcl/rust`.
`:crypto` has `aes_128_cfb8` (checked).  `postgrex` has to be pinned to 0.17.5: newer versions do not compile on Elixir 1.14.

Same input files and oracle as the Tcl and Rust runs (`tests/bench/tcl/data/`, `expected.txt`).  **Every RESULT line matched the oracle** for `+S 1` and `+S 4`, in both runs
(zlib output is the same 99,485 bytes as Rust's libz; AES output is byte-identical to `openssl enc -aes-128-cfb8`).

The Rust baseline was **rerun in the same batch** as the Elixir runs (`run_all.sh`: per round Rust x10 repetitions, then Elixir `+S 1:1`, then `+S 4:4`, x5 repetitions each; 2 rounds; best of all reported).
Load at the start of the two rerun rounds: 0.51 and 1.12, CPU pressure `avg10` 0.12% and 3.43%.  The first run's logs are kept in `tests/bench/elixir/out/first_run/` (gitignored).

### Commands

```
apt-get install -y erlang-base erlang-crypto erlang-dev erlang-tools erlang-inets erlang-ssl elixir
tests/bench/elixir/run_all.sh                       # micro benchmarks: Rust, Elixir +S 1, Elixir +S 4, summary (about 4 minutes)
# sockets: server (BEAM, cores 0-2, +S 3) and a Go load client on core 3; fd limit here is 20000 so 19,000 is the practical maximum
ulimit -n 20000; cd tests/bench/elixir/client && go build -o gwclient main.go && cd ..
TICK_PRIO=high ./run_sock.sh 19000 closed 10        # NCONN MODE(closed|open|pg) DUR [HOLD_MB] [PERCONN_KB] [FRAMES]; env TICK_PRIO, HOLD_KIND, HOLD_GC, CHAOS, PG_CONSUME
# Postgres batching (own cluster on a free port; needs `mix local.rebar --force` once)
export DBCRAFT_PGDATA=/tmp/dbcraft-pg-ex DBCRAFT_PGPORT=54388; tools/pg-dev.sh start
elixir --erl "+S 4:4" pg_batch.exs                  # isolated: one tick's packets by COPY vs unnest vs multi-row VALUES
TICK_PRIO=high PG_CONSUME=truncate ./run_sock.sh 5000 pg 12 0 0 5   # sockets -> collector -> one COPY per 50 ms (omit PG_CONSUME for DELETE ... RETURNING)
elixir rsa_check.exs                                # online-mode primitives
DELAY_MS=50 elixir --erl "+S 4:4" mojang_stub.exs   # session-server call pattern against a local TLS stub
```

## Micro benchmarks (single process; best of all runs, rerun)

| benchmark | Elixir `+S 1` | Elixir `+S 4` | Rust | Rust / Elixir (`+S 1`) |
|---|---|---|---|---|
| VarInt decode (binary pattern matching) | 51.2 M ops/s | 51.1 M | 315.9 M | 6.2x |
| VarInt encode (binary append) | 46.7 M | 48.0 M | 268.2 M | 5.8x |
| frame split, body kept as sub-binary (zero copy) | 14.0 M | 14.6 M | 49.4 M | 3.5x |
| frame split, body copied out (as Rust and Tcl do) | 11.8 M | 13.8 M | 52.2 M | 4.4x |
| position decode (3 doubles, 2 floats, flags) | 13.6 M | 13.5 M | 235.8 M | 17.4x |
| build 200k frames, iodata list then `iolist_to_binary` | 1.29 M | 1.26 M | 72.1 M | 55.7x |
| build 200k frames, binary append | 9.41 M | 11.75 M | 72.1 M | 7.7x |
| 2,000 connection state machines, one process per connection, one feeder | 2.23 M | 0.51 M | 796 M | n/a |
| same, one process holding all states in a list | 25.4 M | 25.6 M | 796 M | n/a |
| zlib compress 1 MiB, level 6 | 82.4 MB/s | 83.6 MB/s | 102.2 MB/s | 1.2x |
| zlib decompress 1 MiB | 533 MB/s | 546 MB/s | 797 MB/s | 1.5x |
| AES-128-CFB8 encrypt 1 MiB (`:crypto`) | 49.1 MB/s | 49.5 MB/s | 73.9 MB/s | 1.5x |
| AES-128-CFB8 decrypt 1 MiB (`:crypto`) | 61.8 MB/s | 52.7 MB/s | 668.1 MB/s | 10.8x |

AES as one connection's stream cut into calls (includes the call overhead):

| call pattern | `+S 1` | `+S 4` | per call (`+S 1`) |
|---|---|---|---|
| encrypt 1000 B blobs | 49.2 MB/s | 49.0 MB/s | 20.3 us |
| decrypt 150 B | 58.9 MB/s | 49.3 MB/s | 2.5 us |
| encrypt 64 B frames | 51.8 MB/s | 43.1 MB/s | 1.24 us |

Notes:

* **The iodata row is a garbage-collector effect, not frame building.**  A process builds 200k small lists and binaries, and a fresh process grows its heap by repeated
  collections: 150 to 200 ms in a fresh process, 55 to 75 ms once its heap is warm, 41 ms with `min_heap_size` preset, 20 ms with binary append (measured separately in a scratch script, not kept).
  A gateway builds about 1000 bytes per connection per tick, where none of this matters; the "binary append" row is the realistic one.
* **The "one process per connection" row is not comparable to Rust's enum loop.**  It measures sending 200,000 messages between processes.  It is 4.4x slower with four
  schedulers than with one (cross-scheduler wake-ups), and four feeders did not recover it (1.79 M/s at `+S 4`, 0.80x of the single `+S 1` feeder).
  Consequence: the process that owns the socket should parse its frames itself and send the collector one message per receive, not one per packet (the socket test below does this).
* `:crypto` serial encryption is 1.5x slower than Rust's AES-NI here.  Decryption is 10.8x slower than Rust's hand-written four-way pipelining, because OpenSSL's CFB8 decrypt is not pipelined here; it
  only matters for the 150 inbound bytes per player per tick.
* Go got 153 MB/s encrypt by interleaving four independent connection streams on one core (`docs/GO-EVALUATION.md`).  `:crypto` has no such batch call; the BEAM gets its parallelism across schedulers instead.

### Several processes at once (4 concurrent copies of the same work; aggregate throughput, rerun)

| benchmark | single (`+S 1`) | 4 copies, `+S 1` | 4 copies, `+S 4` | speedup |
|---|---|---|---|---|
| VarInt decode | 51.2 M | 51.2 M (1.00x) | 194.3 M | 3.79x |
| frame split (zero copy) | 14.0 M | 13.5 M | 49.7 M | 3.55x |
| frame split (copy) | 11.8 M | 11.3 M | 42.3 M | 3.58x |
| position decode | 13.6 M | 13.4 M | 42.8 M | 3.16x |
| build frames (iodata) | 1.29 M | 2.40 M | 4.91 M | 3.79x |
| connection processes, 4 feeders | 2.23 M | 2.17 M | 1.79 M | 0.80x |
| AES-CFB8 encrypt, 4 streams | 49.1 MB/s | 50.0 | 195.0 | 3.97x |
| AES-CFB8 decrypt, 4 streams | 61.8 MB/s | 60.6 | 209.7 | 3.39x |
| AES encrypt, 1000 B calls | 49.2 MB/s | 58.8 | 155.6 | 3.16x |
| AES decrypt, 150 B calls | 58.9 MB/s | 63.3 | 132.3 | 2.24x |
| zlib compress | 78.6 MB/s | 101.8 | 267.2 | 3.40x |
| zlib decompress | 508 MB/s | 554 | about 1,080 | 2.13x |

Parsing and crypto scale 3.2x to 4.0x on four cores (the first, contended run gave 2.3x to 3.4x), the short-call decrypt and zlib decompress 2.1x to 2.2x, and message passing does not scale (0.80x).
With `+S 1` four copies give about 1x, as they should.

## Sockets, memory and tick lateness

Server: BEAM `+S 3:3` pinned to cores 0-2, `gen_tcp` with `{active, 64}`, one process per connection that parses 1-byte-length frames and counts them (no AES, no decode, no database here);
16 acceptor processes.  Client: a Go program pinned to core 3 (`client/main.go`).  Closed loop = each connection sends 20 frames, waits for a 1-byte ack, repeats (saturating).
"Tick lateness" is a separate timer-driven process aiming at an absolute 50 ms grid; lateness is actual minus scheduled time (the timer itself is about 1 to 2 ms late at the median).
The fd limit of this container is 20,000 (hard), so "20,000" connections is 19,000.  Each run was 10 seconds after all connections were up.

### Normal against high tick priority (rerun: 5 runs at 5,000 connections, 3 at 19,000)

| connections | tick process | runs: tick p99 lateness (ms) | **median p99** | runs: tick max (ms) | **median max** | median frames/s |
|---|---|---|---|---|---|---|
| 5,000 | normal priority | 104.5, 16.3, 116.7, 14.4, 51.8 | **51.8** | 104.6, 28.4, 131.0, 14.9, 58.9 | **58.9** | 2.00 M |
| 5,000 | `priority: :high` | 6.1, 1.8, 6.3, 5.5, 4.3 | **5.5** | 8.3, 2.0, 7.3, 11.0, 5.9 | **7.3** | 1.91 M |
| 19,000 | normal priority | 14.5, 7.9, 32.3 | **14.5** | 23.3, 8.5, 45.7 | **23.3** | 1.52 M |
| 19,000 | `priority: :high` | 4.5, 8.6, 6.6 | **6.6** | 5.0, 18.3, 23.4 | **18.3** | 1.53 M |

CPU pressure `avg10` at the start of these runs: 2% to 26% (the other workers); the high-priority 5,000 runs saw 26, 15, 18, 11, 8% and the normal ones 2, 17, 8, 11, 8%.
At normal priority the tick queues behind thousands of runnable connection processes, so under saturation it is sometimes 100+ ms late; high priority fixes that.  Use `Process.flag(:priority, :high)` for the tick.

* **Memory:** 11.8 KB of BEAM memory and 13.7 to 14.0 KB of RSS per connection at 19,000 (earlier 5,000 runs: 12.4 to 12.8 KB BEAM, 14.2 to 15.8 KB RSS); 19,000 connections used about 340 MB RSS.
* **Throughput:** 1.5 to 2.0 million frames/s of socket receive and frame counting on three scheduler threads.  This is not the gateway's full per-frame work.
* **Realistic open-loop traffic** (5 frames per connection per 50 ms, 5,000 connections), first run only (pressure 30%, not repeated): the server handled the 350k to 385k frames/s the client
  could generate; tick p99 5.3 to 6.5 ms, max 7.8 to 13.3 ms (normal and high priority alike).  The client, not the server, was the limit, so this says "not saturated", not a capacity.
* **Crash isolation, measured (first run, quiet machine, not repeated):** `CHAOS=1` killed 240 of 2,000 connection processes with `Process.exit(pid, :kill)` during the run, one second apart.  The other 1,760
  kept running, throughput was 1.97 M frames/s, tick p99 5.5 ms.  Killed connections' sockets close with their owner process.

### Is there a global garbage-collection pause? (rerun)

One process holds about 1 GB as a list on its own heap (16 B per element) and runs a full-sweep garbage collection every 200 ms while 5,000 connections run closed loop, high-priority tick.
Three alternating pairs, GC on against GC off (CPU pressure 7% to 21%):

| holder GC | full sweep of the 1 GB process (`long_gc` monitor) | frames/s (runs) | tick p99 (runs) | **median p99** | tick max (runs) | **median max** |
|---|---|---|---|---|---|---|
| on | 3.6, 5.1, 5.0 s | 1.98, 1.94, 1.75 M | 8.2, 8.5, 13.9 ms | **8.5 ms** | 10.8, 10.8, 14.3 ms | **10.8 ms** |
| off | none (but see below) | 1.90, 2.05, 2.21 M | 4.3, 2.8, 8.7 ms | **4.3 ms** | 6.6, 4.1, 9.1 ms | **6.6 ms** |

So there is **no global stop-the-world**: the 5,000 other processes kept about 95% of their rate and no tick was seconds late while one process spent 3.6 to 5.1 s inside each collection.  A huge collection in one process costs
the others a little (median tick p99 +4 ms, max +4 ms, probably memory bandwidth).  One "off" run still logged a 3.5 s collection, probably the holder's own heap growth during its build, so the off baseline is not perfectly
collection-free.  A gateway holds a few KB per connection, which keeps every sweep in microseconds (the 19,000-connection runs show 0 or 1 collection over 5 ms).

**1 GB as 16,384 off-heap 64 KiB binaries, 19,000 connections, rerun (3 runs, pressure 7% to 14%):** 1.67, 1.55, 1.60 M frames/s; tick p99 3.3, 6.1, 6.9 ms; max 4.7, 14.2, 14.3 ms; at most one
collection over 5 ms (10 ms).  The first run's 0.55 M frames/s and p99 64 ms was not reproduced; it was measured at 40% CPU pressure, so contention is the likely cause (not proven).

## Batching to Postgres (the design's tick)

Postgrex 0.17.5, binary `COPY` into the unlogged `net.inbox (tick, conn_id, body)` of `docs/SQL-GATEWAY.md`, on a dedicated cluster (port 54388, `fsync=off`, `synchronous_commit=off`).

Isolated (one tick's packets of 34 bytes; the `COPY` and `unnest` times include building the rows or arrays in Elixir; best of 8; three repetitions of the whole script, range shown):

| packets | binary `COPY` | `INSERT ... unnest($1::int[], $2::bytea[])` | multi-row `INSERT ... VALUES ($1,$2,$3),(...)` | `DELETE ... RETURNING` of them |
|---|---|---|---|---|
| 10,000 | **5.2 to 6.1 ms** | 6.9 to 7.8 ms | 50 to 66 ms | 7.1 to 10.1 ms |
| 25,000 | 9.4 to 11.7 ms | 15.6 to 18.5 ms | 140 to 151 ms | 18.1 to 20.0 ms |
| 100,000 | 34.8 to 36.0 ms | 76 to 85 ms | 775 to 795 ms | 76 to 82 ms |

COPY is the best per tick: 1.2x to 2.4x faster than `unnest` and about **10x faster than a multi-row VALUES insert** (the 25,000 and 100,000 VALUES rows are split into statements of 20,000 rows to stay under
Postgres's 65,535-parameter limit; the cost is mostly statement parsing).

End to end (open-loop clients, each connection sends 5 frames per 50 ms; connection processes forward frames to a high-priority collector, which every 50 ms builds the rows, runs one
`COPY`, then a stand-in for `net.tick()` that consumes the rows).  Run in sequence on the same table; CPU pressure at the start in the last column:

| consume stand-in | connections | frames per flush | build rows | `COPY` | consume | busy per tick (avg / max) | tick lateness p99 / max (sockets) | pressure |
|---|---|---|---|---|---|---|---|---|
| `DELETE ... RETURNING`, run 1 (fresh table) | 2,000 | 9,952 | 1.6 ms | 6.6 ms | 14.3 ms | 22.5 / 55.6 ms | 2.0 / 2.9 ms | 0.4% |
| `DELETE ... RETURNING`, run 2 (same table) | 2,000 | 13,089 (falling behind) | 2.2 ms | 8.0 ms | 54.8 ms | 65.0 / 115 ms | 3.6 / 4.6 ms | 7.4% |
| `DELETE ... RETURNING`, run 3 (same table) | 2,000 | 26,440 (behind) | 7.1 ms | 18.1 ms | 108.4 ms | 133.6 / 222 ms | 5.0 / 8.8 ms | 9.5% |
| `DELETE ... RETURNING`, 2 runs | 5,000 | 472,163 and 296,251 (overloaded) | 733 and 144 ms | 572 and 239 ms | 397 and 341 ms | 1,701 and 724 ms | 11.4 / 19.9 and 11.0 / 23.9 ms | 12%, 23% |
| `TRUNCATE` | 2,000 | 9,909 | 1.5 ms | 6.3 ms | 3.2 ms | **11.0** / 115 ms | 1.9 / 2.5 ms | 24% |
| `TRUNCATE` | 5,000 | 23,725 | 4.6 ms | 13.0 ms | 4.9 ms | **22.5** / 89.4 ms | 5.1 / 6.5 ms | 8% |

* **`DELETE` as the consume step degrades from run to run** (14 -> 55 -> 108 ms for the same load): the table fills with dead tuples faster than vacuum removes them.  The first run's 19.9 ms was this effect too.
  With `TRUNCATE` the same 2,000-connection load took 11.0 ms busy per tick (22% of the budget) and 5,000 connections (23.7k packets per tick, 100 frames/s per player) took 22.5 ms (45%): about 0.95 us per packet.
  The maximum busy time was 89 to 115 ms in single ticks (one hiccup each), so occasional ticks overrun.
* **Caveat for `TRUNCATE`:** it is a stand-in for `net.tick()` reading and discarding the rows.  It takes an exclusive lock and is not transaction-safe against concurrent readers.  A real design could use a rotating
  partition or `DELETE` inside the transaction that reads the rows; I did not test those.  Do not read 22.5 ms as the cost of the real tick.
* The sockets stayed punctual in every row (tick p99 at most 5.1 ms, ignoring the overloaded 5,000 `DELETE` runs at 11 ms): the database path, not the BEAM, sets the limit.
* The collector design (one message per receive, one process, one `COPY`) is cheap on the BEAM side: 1.5 ms to build rows for 10k packets.

## Online-mode primitives

### `rsa_check.exs`

All present in OTP, no native code to write: RSA-1024 key pair, PKCS#1 v1.5 round trip (ciphertext 128 bytes) with `:crypto.private_decrypt` at 218 to 261 us per call; the Minecraft signed-SHA1
server hash reproduces the three published vectors (`Notch`, `jeb_`, `simon`); `:inets` and `:ssl` start.

### The Mojang session-server call pattern, against a local stub (`mojang_stub.exs`)

**Mojang was never contacted.**  The real call is `GET https://sessionserver.mojang.com/session/minecraft/hasJoined?username=<name>&serverId=<hash>` answered with 200 and a JSON profile (about 1 to 2 KB).
The stub is a local `:ssl` server on loopback with a throwaway CA and a server certificate for `localhost`; the client does full chain and hostname verification (`verify_peer`, `server_name_indication`).
A self-signed leaf certificate is rejected by OTP as `selfsigned_peer`, so my first attempt failed every request (those numbers were discarded) until I used a CA plus a signed server certificate.
Response body 1,637 B, optional artificial upstream delay (`DELAY_MS`, models Mojang's round trip).  Client and stub share one VM, so each figure includes **both** ends' TLS and HTTP work.
CPU pressure at the start of the two runs: 0.2% and 0.9%.  Failures were 0 in every row.

| client | concurrency | upstream delay 0 ms | upstream delay 50 ms |
|---|---|---|---|
| `:httpc`, sequential | 1 | 5,614/s, p50 143 us, p99 597 us | 19.5/s, p50 51 ms |
| `:httpc` | 64 | 4,783/s, p50 12 ms, p99 24 ms | **20/s**, p50 3,272 ms (256 logins in 13.1 s) |
| `:httpc` | 256 | 3,982/s, p50 61 ms | not run |
| `:httpc` | 1,024 | 4,347/s, p50 230 ms | not run (the first 50 ms attempt crashed `httpc` under this load) |
| pool of persistent `:ssl` connections | 64 | 21,599/s incl. 64 TLS handshakes, p50 1 ms, p99 5 ms | 1,218/s, p50 51 ms, p99 56 ms (the limit is 64 / 50 ms = 1,280/s) |
| pool of persistent `:ssl` connections | 256 | 13,570/s, p50 5 ms, p99 21 ms | 3,952/s, p50 51 ms, p99 79 ms |
| pool of persistent `:ssl` connections | 1,024 | 5,318/s incl. 1,024 handshakes, p50 5 ms, p99 46 ms | 4,322/s, p50 57 ms, p99 99 ms |

* **`:httpc` is not usable for a login storm:** with a 50 ms upstream it processed one request at a time (20/s at any concurrency, despite `max_sessions: 512`), because it queues requests on one keep-alive session.
  With no upstream delay it is fast enough (4,000 to 5,600/s).  Use your own pool of TLS connections (or an HTTP client library with a pool; none other than `:httpc` was tried).
* With a pool, a login storm is bound by upstream latency: 256 connections sustained about 4,000 verifications/s at 50 ms (1,000 players logging in would take about 0.25 s).  At 1,024 connections the
  handshakes dominate (about 1.5 ms of CPU for both ends per handshake in this setup, all in one VM).
* **Not measured:** Mojang's real latency, rate limits and failure behaviour (204 responses, timeouts), HTTP/2, and the encrypted login with a real client.

## Players one core (and four cores) can serve (gateway work only, rerun)

Same assumptions as `docs/TCL-EVALUATION.md`: per player per tick 5 inbound packets (frame split + position decode), 25 outbound frames of about 1000 B, AES-CFB8 over 1000 B out and 150 B in.  AES uses the measured per-call pattern.

| variant | framing + decode | AES-CFB8 | per player-tick | players per core (100% busy) | players per core (70% busy) |
|---|---|---|---|---|---|
| Rust, AES-NI (serial), this rerun's batch | 0.5 us | 13.8 us | 14.2 us | 3,517 | 2,462 |
| Rust, first batch (also the figure in `docs/GO-EVALUATION.md`) | 0.5 us | 17.0 us | 17.5 us | 2,855 | 1,998 |
| Go, serial AES (`docs/GO-EVALUATION.md`) | 0.8 us | 19.0 us | 19.8 us | 2,522 | 1,766 |
| Go, 4 interleaved AES streams (same doc) | 0.7 us | 7.6 us | 8.3 us | 6,027 | 4,219 |
| **Elixir `+S 1`, frames built with binary append** | 3.4 us | 22.9 us | 26.2 us | **1,905** | **1,334** |
| **Elixir `+S 1`, frames built as iodata (measured rate above)** | 20.1 us | 22.9 us | 42.9 us | **1,165** | **815** |
| Tcl + tcl-aot, native AES hypothetical (`docs/TCL-EVALUATION.md`) | 41.1 us | 17.6 us | 58.7 us | 852 | 596 |
| Elixir `+S 4`, measured aggregate of 4 workers (iodata frames) | 5.3 us | 7.6 us | 12.9 us | 3,883 on 4 cores | 2,718 on 4 cores |

The binary-append row is computed from the same measured per-op times, not a separate run.  The `+S 4` row uses the aggregate rates of the four-copy runs.  These are optimistic: no sockets, no database
batching and no scheduling cost beyond what was measured separately above.  The Go row came from a different batch than either Rust row, so compare Elixir with the Rust row from its own batch.

## BEAM against Rust, Go and Tcl

| | Rust | Go | Elixir/BEAM | Tcl + tcl-aot |
|---|---|---|---|---|
| parsing and framing per core | baseline | 0.5x to 1.1x of Rust | 3.5x to 17x slower (up to 56x for the iodata build) | 58x to 530x slower |
| serial AES-CFB8 encrypt | 73.9 MB/s (59.9 in the first batch) | 56 MB/s | 49.1 MB/s (`:crypto`) | 24 kB/s pure Tcl, native binding needed |
| AES decrypt | 668 MB/s | 137 MB/s | 61.8 MB/s | n/a |
| players per core, serial AES, gateway work only | 3,517 (2,855) | 2,522 | 1,165 to 1,905 | 852 (if AES were native) |
| per-connection memory | not measured here | see GO-EVALUATION | about 12 KB BEAM, 14 KB RSS | n/a |
| tail latency | no GC | GC adds a tail when the pointer heap is large and the CPU saturated | per-process GC, no global pause; **tick needs high priority** | n/a |
| a faulty connection | takes the process down unless handled | same | **cannot affect other connections (measured once)** | n/a |
| fds in one process | OS limit | OS limit | OS limit (19,000 tested) | 1,024 (`select`) |
| native code to write for crypto | none (written in Rust) | none | none (`:crypto`) | a C binding |
| HTTPS to Mojang | a crate | `net/http` | built in, but `:httpc` serialises: own TLS pool needed (4,000/s at 50 ms upstream) | not tested |

Where BEAM wins: fault isolation (measured once), no global GC pause (measured), no native code for AES, RSA, SHA-1, zlib or TLS, lightweight processes (19,000 connections in about 340 MB),
and in this design the compute gap matters less because framing and decode are only 3.4 of 26.2 us per player-tick when frames are built with binary append.  Supervision and hot code loading are standard
OTP features that I did not test here.

Where it loses: 1.8x to 3x fewer players per core than Rust (1.3x to 2.2x fewer than Go) on the same work; no way to interleave several connections' CFB8 streams on one core (Go's 2.7x trick), only multi-core
parallelism, which scaled 3.2x to 4.0x on four schedulers here; message passing between processes does not scale across schedulers (4.4x slower for 200k messages), so the design must keep one
process per connection and only batch messages to the collector; the tick needs `priority: :high` to stay punctual under saturation; `:httpc` cannot serve concurrent Mojang calls; and the apt toolchain is old
(Elixir 1.14, OTP 25, `postgrex` pinned to 0.17.5).

Honest ranking for a gateway whose cost is mostly AES, for density: Rust first, then Go, then Elixir, then Tcl.  Elixir is the choice only if surviving bad connections and the ops story matter more than losing
roughly half to two thirds of Rust's per-core density.

## What I did not measure, or got wrong along the way

* Both batches shared the machine with other workers (rerun: load 0.5 to 3.3, pressure 0.1% to 25%; the number is printed with each run); spread is about 10% to 30% for the micro rows, larger for tick tail latencies, which is why those
  are reported as runs plus a median.
* Harness mistakes found and fixed: the `elixir` launcher script overwrites an environment variable named `MODE` (the first socket run never sent acks; the variable is now `GW_MODE`); my first tick probe added a constant 1 ms
  per interval by re-arming a relative timer (now an absolute 50 ms grid); the Mojang stub's first run used a self-signed leaf certificate and every request failed (fixed with a CA chain; those figures were discarded).
* Single-run items that were not repeated in the rerun: the open-loop 5,000-connection traffic, the crash-isolation test (240 killed processes).
* Not tested: hot code reload, supervision trees, `io_uring`/`+K` options, `+sbwt`/scheduler binding tuning, the real Mojang call and a real client login, more than 19,000 connections (fd limit), frame building with a preset `min_heap_size`
  as a kept benchmark (measured once in a scratch script), a rotating partition or in-transaction `DELETE` as the consume step, HTTP clients other than `:httpc`.
* Frame counting in the socket test is only receive and parse; AES, decode and the database were measured separately and not combined in one run.
