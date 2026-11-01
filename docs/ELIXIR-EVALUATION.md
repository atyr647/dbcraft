# Elixir/BEAM as the gateway language: measurements against Rust, Go and Tcl

Question: is Elixir/Erlang (the BEAM) a good language for the tiny dbcraft gateway (sockets, framing, AES-CFB8, zlib, batching to Postgres), on the same
workloads as `docs/TCL-EVALUATION.md` (Rust and Tcl) and `docs/GO-EVALUATION.md` (Go)?

**Short answer: viable, but about 1.5x to 2.5x fewer players per core than Rust or Go, and in return it gives the best fault isolation of the lot.**
The BEAM is 4x to 20x slower than Rust on pure parsing, but the gateway's cost is mostly AES, and `:crypto` (OpenSSL) ties Rust on serial CFB8 encryption
(61.9 against 59.9 MB/s).  One BEAM process per connection costs about 12 KB, 19,000 connections served 1.5 to 1.6 million frames/s on three scheduler threads,
and killing 240 connection processes under load did not disturb the rest.  The things to watch are tick punctuality under saturation (needs a high-priority tick
process), and message passing between processes, which gets slower with more schedulers, so the socket-owning process must parse its own frames.

## Setup

Linux x86-64, 4 cores shared with other benchmark forks, **Elixir 1.14.0 on Erlang/OTP 25 (ERTS 13.2.2.5, JIT)** from apt (`erlang-base elixir`), Rust 1.97 release
build from `tests/bench/tcl/rust`.  `:crypto` has `aes_128_cfb8` (checked).  `postgrex` has to be pinned to 0.17.5: newer versions do not compile on Elixir 1.14.

Same input files and oracle as the Tcl and Rust runs (`tests/bench/tcl/data/`, `expected.txt`).  **Every RESULT line matched the oracle** for `+S 1` and `+S 4`
(zlib output is the same 99,485 bytes as Rust's libz; AES output is byte-identical to `openssl enc -aes-128-cfb8`).

The Rust baseline was **rerun in the same batch** as the Elixir runs (`run_all.sh`: per round Rust x10 repetitions, then Elixir `+S 1:1`, then `+S 4:4`, x5 repetitions each;
2 rounds; the best of all is reported).  Machine load at the start of the two rounds was 1.8 (the other forks were running); CPU pressure `avg10` was 0.06 and 6.0.
Run-to-run spread on this shared machine is 10% to 30%, more for the multi-process rows.

### Commands

```
apt-get install -y erlang-base erlang-crypto erlang-dev erlang-tools erlang-inets erlang-ssl elixir
tests/bench/elixir/run_all.sh                       # micro benchmarks: Rust, Elixir +S 1, Elixir +S 4, summary (about 3 minutes)
# sockets: server (BEAM, cores 0-2, +S 3) and a Go load client on core 3; fd limit here is 20000 so 19,000 is the practical maximum
ulimit -n 20000; cd tests/bench/elixir/client && go build -o gwclient main.go && cd ..
TICK_PRIO=high ./run_sock.sh 19000 closed 12        # NCONN MODE(closed|open|pg) DUR [HOLD_MB] [PERCONN_KB] [FRAMES]; env TICK_PRIO, HOLD_KIND, HOLD_GC, CHAOS
# Postgres batching (own cluster on a free port; needs `mix local.rebar --force` once)
export DBCRAFT_PGDATA=/tmp/dbcraft-pg-ex DBCRAFT_PGPORT=54388; tools/pg-dev.sh start
elixir --erl "+S 4:4" pg_batch.exs                  # isolated: one tick's packets by COPY vs unnest insert
TICK_PRIO=high ./run_sock.sh 2000 pg 12 0 0 5       # sockets -> collector -> one COPY per 50 ms
elixir rsa_check.exs                                # online-mode primitives
```

## Micro benchmarks (single process; best of all runs)

| benchmark | Elixir `+S 1` | Elixir `+S 4` | Rust | Rust / Elixir (`+S 1`) |
|---|---|---|---|---|
| VarInt decode (binary pattern matching) | 59.7 M ops/s | 51.1 M | 303.8 M | 5.1x |
| VarInt encode (binary append) | 54.7 M | 47.0 M | 295.7 M | 5.4x |
| frame split, body kept as sub-binary (zero copy) | 14.3 M | 14.6 M | 55.7 M | 3.9x |
| frame split, body copied out (as Rust and Tcl do) | 11.5 M | 11.9 M | 53.7 M | 4.7x |
| position decode (3 doubles, 2 floats, flags) | 13.4 M | 13.5 M | 264.2 M | 19.7x |
| build 200k frames, iodata list then `iolist_to_binary` | 1.25 M | 1.20 M | 59.6 M | 47.5x |
| build 200k frames, binary append | 9.84 M | 10.34 M | 59.6 M | 6.1x |
| 2,000 connection state machines, one process per connection, one feeder | 2.43 M | 0.52 M | 657 M | n/a |
| same, one process holding all states in a list | 25.3 M | 24.7 M | 657 M | n/a |
| zlib compress 1 MiB, level 6 | 82.8 MB/s | 96.9 MB/s | 84.4 MB/s | 1.0x |
| zlib decompress 1 MiB | 528 MB/s | 641 MB/s | 661 MB/s | 1.3x |
| AES-128-CFB8 encrypt 1 MiB (`:crypto`) | 61.9 MB/s | 55.3 MB/s | 59.9 MB/s | 1.0x |
| AES-128-CFB8 decrypt 1 MiB (`:crypto`) | 64.7 MB/s | 59.0 MB/s | 515.7 MB/s | 8.0x |

AES as one connection's stream cut into calls (includes the call overhead):

| call pattern | `+S 1` | `+S 4` | per call (`+S 1`) |
|---|---|---|---|
| encrypt 1000 B blobs | 49.2 MB/s | 48.3 MB/s | 20.3 us |
| decrypt 150 B | 49.7 MB/s | 48.4 MB/s | 3.0 us |
| encrypt 64 B frames | 47.5 MB/s | 42.5 MB/s | 1.35 us |

Notes:

* **The iodata row is a garbage-collector effect, not frame building.**  A process builds 200k small lists and binaries, and a fresh process grows its heap by repeated
  collections: 150 to 200 ms in a fresh process, 55 to 75 ms once its heap is warm, 41 ms with `min_heap_size` preset, 20 ms with binary append.  A gateway builds
  about 1000 bytes per connection per tick, where none of this matters; the "binary append" row is the realistic one.
* **The "one process per connection" row is not comparable to Rust's enum loop.**  It measures sending 200,000 messages between processes.  It is 4.7x slower with four
  schedulers than with one (cross-scheduler wake-ups), and four feeders did not recover it (1.67 M/s at `+S 4`, 0.69x of the single `+S 1` feeder).
  Consequence: the process that owns the socket should parse its frames itself and send the collector one message per receive, not one per packet (the socket test below does this).
* `:crypto` serial encryption equals Rust's AES-NI (CFB8 encrypt is latency bound: each byte needs the previous ciphertext byte).  Decryption is 8x slower than Rust's hand-written
  four-way pipelining, because OpenSSL's CFB8 decrypt is not pipelined here; it only matters for the 150 inbound bytes per player per tick.
* Go got 153 MB/s encrypt by interleaving four independent connection streams on one core (`docs/GO-EVALUATION.md`).  `:crypto` has no such batch call; the BEAM gets its parallelism across schedulers instead.

### Several processes at once (4 concurrent copies of the same work; aggregate throughput)

| benchmark | single (`+S 1`) | 4 copies, `+S 1` | 4 copies, `+S 4` | speedup |
|---|---|---|---|---|
| VarInt decode | 59.7 M | 53.8 M (0.90x) | 138.7 M | 2.32x |
| frame split (zero copy) | 14.3 M | 13.6 M | 33.3 M | 2.33x |
| frame split (copy) | 11.5 M | 12.3 M | 26.9 M | 2.34x |
| position decode | 13.4 M | 16.0 M | 35.0 M | 2.61x |
| build frames (iodata) | 1.25 M | 2.28 M | 4.27 M | 3.41x |
| connection processes, 4 feeders | 2.43 M | 2.14 M | 1.67 M | 0.69x |
| AES-CFB8 encrypt, 4 streams | 61.9 MB/s | 59.1 | 191.2 | 3.09x |
| AES-CFB8 decrypt, 4 streams | 64.7 MB/s | 66.9 | 197.1 | 3.04x |
| AES encrypt, 1000 B calls | 49.2 MB/s | 62.0 | 161.4 | 3.28x |
| AES decrypt, 150 B calls | 49.7 MB/s | 60.3 | 115.3 | 2.32x |
| zlib compress | 78.9 MB/s | 91.2 | 232.1 | 2.94x |
| zlib decompress | 504 MB/s | 590.6 | 915.1 | 1.82x |

Parsing scales about 2.3x to 2.6x on four cores (the other forks were using the same CPUs), crypto and zlib about 3x.  With `+S 1` four copies give about 1x, as they should.

## Sockets, memory and tick lateness

Server: BEAM `+S 3:3` pinned to cores 0-2, `gen_tcp` with `{active, 64}`, one process per connection that parses 1-byte-length frames and counts them (no AES, no decode, no database here);
16 acceptor processes.  Client: a Go program pinned to core 3 (`client/main.go`).  Closed loop = each connection sends 20 frames, waits for a 1-byte ack, repeats (saturating).
"Tick lateness" is a separate timer-driven process aiming at an absolute 50 ms grid; lateness is actual minus scheduled time (the timer itself is about 1 to 2 ms late at the median).
The fd limit of this container is 20,000 (hard), so "20,000" connections is 19,000.

Runs with CPU pressure `avg10` of 8% or less:

| connections | tick process | frames/s | BEAM memory per connection | RSS per connection | tick lateness p50 / p99 / max | GC pauses over 5 ms |
|---|---|---|---|---|---|---|
| 5,000 | normal priority | 1.84 M | 12.8 KB | 15.8 KB | 1.6 / 6.2 / 9.2 ms | 0 |
| 5,000 | high priority | 1.78 M | 12.4 KB | 14.2 KB | 1.2 / 4.4 / 9.9 ms | 0 |
| 19,000 | normal priority | 1.50 M | 11.9 KB | 13.9 KB | 1.9 / 17.1 / 30.5 ms | 0 |
| 19,000 | high priority | 1.58 M | 11.9 KB | 14.2 KB | 1.3 / 1.4 / 1.6 ms | 0 |
| 2,000, with 240 connection processes killed (below) | high priority | 1.97 M | 13.7 KB | 16.5 KB | 1.9 / 5.5 / 9.4 ms | 1 (7 ms) |

* **Memory:** about 12 KB of BEAM memory and 14 to 16 KB of RSS per connection; 19,000 connections used 342 MB RSS.
* **Throughput:** 1.5 to 2.0 million frames/s of socket receive and frame counting on three scheduler threads.  This is not the gateway's full per-frame work.
* **Tick lateness under saturation varies a lot between runs at normal priority** and is much better with `Process.flag(:priority, :high)`: an earlier 5,000-connection run at normal
  priority (machine quiet, pressure 0.4%) had p99 133 ms and max 136 ms; the same configuration later gave p99 6.2 ms.  I did not find the reason for that outlier.
  With a high-priority tick, p99 was 1.4 to 12 ms and max 1.6 to 19.6 ms across the runs I made without the 1 GB holder (the high end was measured when the machine was busy).  Use high priority for the tick process.
* **Realistic open-loop traffic** (5 frames per connection per 50 ms, 5,000 connections), with the other forks busy (pressure 30%): the server handled the 350k to 385k frames/s the client
  could generate; tick p99 5.3 to 6.5 ms, max 7.8 to 13.3 ms (normal and high priority alike).  The client, not the server, was the limit, so this says "not saturated", not a capacity.
* **Crash isolation, measured:** `CHAOS=1` killed 240 of 2,000 connection processes with `Process.exit(pid, :kill)` during the run, one second apart.  The other 1,760 kept running,
  throughput was 1.97 M frames/s, tick p99 5.5 ms.  Killed connections' sockets close with their owner process.  Nothing in a connection process can take down another.

### Is there a global garbage-collection pause?

Test: one process holds about 1 GB as a list on its own heap (16 B per element) and runs a full-sweep garbage collection every 200 ms, while 5,000 connections run closed loop
(three pairs, GC on against GC off, alternating).  The machine was heavily loaded by the other forks (CPU pressure 27% to 49%), so these numbers are rough.

| holder GC | full sweep of the 1 GB process | frames/s | tick p99 | tick max |
|---|---|---|---|---|
| on (3 runs) | 5.2 to 6.3 s (`long_gc` monitor) | 0.80 to 0.90 M | 13.5 to 23.5 ms | 21.9 to 40.0 ms |
| off (2 valid runs; the third got no connections) | none | 0.91 to 1.49 M | 12.3 to 15.5 ms | 15.8 to 16.0 ms |

A 19,000-connection run with the same holder (pressure 35%): sweeps of 0.9 to 4.9 s, 1.14 M frames/s (the run without it, at pressure 4%, gave 1.12 M), tick p99 32.6 ms, max 67.6 ms.

So there is **no global stop-the-world**: the other 5,000 to 19,000 processes kept their rate and no tick was seconds late while one process spent 5 to 6 s inside a collection.  But a
huge collection in one process is not free for the others: the tick's worst case was 10 to 50 ms higher, probably memory bandwidth (the machine was also contended, so I cannot separate the two).  A run
that held 1 GB as 16,384 off-heap 64 KiB binaries instead (pressure 40%) showed 0.55 M frames/s, p99 63.8 ms and max 137.5 ms with the collections taking 21 to 608 ms; I did not repeat it on a quiet machine and
do not trust it as a cause-and-effect result.  Per-connection live data should be modest (a gateway holds a few KB per connection), which keeps every sweep in microseconds.

## Batching to Postgres (the design's tick)

Postgrex 0.17.5, binary `COPY` into the unlogged `net.inbox (tick, conn_id, body)` of `docs/SQL-GATEWAY.md`, on a dedicated cluster (port 54388, `fsync=off`, `synchronous_commit=off`).

Isolated (one tick's packets of 34 bytes; includes building the rows in Elixir; best of 8):

| packets | binary `COPY` | `INSERT ... unnest($1::int[], $2::bytea[])` | `DELETE ... RETURNING` of them |
|---|---|---|---|
| 10,000 | 5.3 ms | 7.1 ms | 7.9 ms |
| 25,000 | 10.6 ms | 18.7 ms | 17.1 ms |
| 100,000 | 51.2 ms | 93.1 ms | 104.4 ms |

End to end (open-loop clients, each connection sends 5 frames per 50 ms; connection processes forward frames to a high-priority collector, which every 50 ms builds the rows, runs one
`COPY`, then a stand-in for `net.tick()` that consumes the rows with `DELETE ... RETURNING`):

| connections | frames per tick | build rows | `COPY` | consume | busy per tick (avg / max) | tick lateness p99 / max (sockets) |
|---|---|---|---|---|---|---|
| 2,000 | 9,927 | 1.9 ms | 7.4 ms | 19.9 ms | 29.2 / 71.0 ms | 3.7 / 7.1 ms |
| 5,000 | offered about 25,000; the collector fell behind and flushed 154,356 per tick | 50 ms | 120 ms | 172 ms | 342 / 773 ms (flush up to 12 s late) | 13.3 / 23.4 ms |

* The database side is the limit, not the BEAM: at 2,000 connections the sockets stayed punctual while the batch took 58% of the tick.  At 5,000 connections one Postgres connection could not keep
  up with this pipeline (about 2.9 us per packet at 2,000 connections), the same order as the in-database gateway in `docs/SQL-GATEWAY.md` (about 10k packets per 50 ms tick there, about 17k here, both before the real game tick takes anything).
* The consume step cost 19.9 ms live against 7.9 ms isolated; the live table accumulates dead tuples between vacuums.  `TRUNCATE` or a rotating partition instead of `DELETE` would probably fix that;
  I did not test it.
* The collector design (one message per receive, one process, one `COPY`) is cheap on the BEAM side: build 1.9 ms for 10k rows.

## Online-mode primitives (`rsa_check.exs`)

All present in OTP, no native code to write: RSA-1024 key pair, PKCS#1 v1.5 round trip (ciphertext 128 bytes) with `:crypto.private_decrypt` at 218 to 261 us per call; the Minecraft signed-SHA1
server hash reproduces the three published vectors (`Notch`, `jeb_`, `simon`); `:inets` and `:ssl` start (for the Mojang session-server call).  **Not exercised:** the HTTPS call itself (the sandbox has no route to Mojang),
and a full encrypted login against a real client.

## Players one core (and four cores) can serve (gateway work only)

Same assumptions as `docs/TCL-EVALUATION.md`: per player per tick 5 inbound packets (frame split + position decode), 25 outbound frames of about 1000 B, AES-CFB8 over 1000 B out and 150 B in.  AES uses the measured per-call pattern.

| variant | framing + decode | AES-CFB8 | per player-tick | players per core (100% busy) | players per core (70% busy) |
|---|---|---|---|---|---|
| Rust, AES-NI (serial) | 0.5 us | 17.0 us | 17.5 us | 2,855 | 1,998 |
| Go, serial AES (`docs/GO-EVALUATION.md`) | 0.8 us | 19.0 us | 19.8 us | 2,522 | 1,766 |
| Go, 4 interleaved AES streams (same doc) | 0.7 us | 7.6 us | 8.3 us | 6,027 | 4,219 |
| **Elixir `+S 1`, frames built with binary append** | 3.3 us | 23.4 us | 26.6 us | **1,878** | **1,315** |
| **Elixir `+S 1`, frames built as iodata (measured number above)** | 20.7 us | 23.4 us | 44.0 us | **1,136** | **795** |
| Tcl + tcl-aot, native AES hypothetical (`docs/TCL-EVALUATION.md`) | 41.1 us | 17.6 us | 58.7 us | 852 | 596 |
| Elixir `+S 4`, measured aggregate of 4 workers (iodata frames) | 6.1 us | 7.5 us | 13.6 us | 3,666 on 4 cores | 2,566 on 4 cores |

The binary-append row is computed from the same measured per-op times, not a separate run.  The `+S 4` row uses the aggregate rates of the four-copy runs, so it already includes the contention
of the other forks.  These are optimistic: no sockets, no database batching and no scheduling cost beyond what was measured separately above.

## BEAM against Rust, Go and Tcl

| | Rust | Go | Elixir/BEAM | Tcl + tcl-aot |
|---|---|---|---|---|
| parsing and framing per core | baseline | 0.5x to 1.1x of Rust | 4x to 20x slower | 58x to 530x slower |
| serial AES-CFB8 encrypt | 59.9 MB/s | 56 MB/s | 61.9 MB/s (`:crypto`) | 24 kB/s pure Tcl, native binding needed |
| AES decrypt | 515 MB/s | 137 MB/s | 64.7 MB/s | n/a |
| players per core, serial AES, gateway work only | 2,855 | 2,522 | 1,136 to 1,878 | 852 (if AES were native) |
| per-connection memory | not measured here | see GO-EVALUATION | about 12 KB BEAM, 14 to 16 KB RSS | n/a |
| tail latency | no GC | GC adds a tail when the pointer heap is large and the CPU saturated | per-process GC, no global pause; tick needs high priority | n/a |
| a faulty connection | takes the process down unless handled | same | **cannot affect other connections (measured)** | n/a |
| fds in one process | OS limit | OS limit | OS limit (19,000 tested) | 1,024 (`select`) |
| native code to write for crypto | none (written in Rust) | none | none (`:crypto`) | a C binding |

Where BEAM wins: fault isolation (measured), no global GC pause (measured, with the caveat above), no native code for AES, RSA, SHA-1, zlib or the Mojang HTTPS call, lightweight processes (19,000 connections in 342 MB),
and in this design the compute gap matters less because framing and decode are only 3.3 of 26.6 us per player-tick when frames are built with binary append.  Supervision and hot code loading are standard
OTP features that I did not test here.

Where it loses: 1.5x to 2.5x fewer players per core than Rust or Go on the same work; no way to interleave several connections' CFB8 streams on one core (Go's 2.7x trick), only multi-core
parallelism, which scaled 2.3x to 3.4x on four schedulers here; message passing between processes is slow on several schedulers (4.7x slower for 200k messages), so the design must keep one
process per connection and only batch messages to the collector; the tick needs `priority: :high` to stay punctual under saturation; and the apt toolchain is old (Elixir 1.14, OTP 25, `postgrex` pinned to 0.17.5).

Honest ranking for a gateway whose cost is mostly AES, for density: Rust first, then Go, then Elixir, then Tcl.  Elixir is the choice only if surviving bad connections and the
ops story matter more than 40% to 60% of the per-core density.

## What I did not measure, or got wrong along the way

* The Rust and Elixir micro-benchmarks ran in the same batches, but other forks were using the CPUs (load 1.8 to 6, pressure 0.06% to 49% depending on the run); spread is 10% to 30%.
* Harness mistakes found and fixed: the `elixir` launcher script overwrites an environment variable named `MODE` (the first socket run never sent acks; the variable is now `GW_MODE`), and my first tick probe added a constant 1 ms
  per interval by re-arming a relative timer (now an absolute 50 ms grid).
* The 1 GB off-heap-binary run and the pair-3 GC-off run (no connections) are not reliable results.
* Not tested: hot code reload, supervision trees, `io_uring`/`+K` options, `+sbwt`/scheduler binding tuning, the Mojang HTTPS call, a real client login, more than 19,000 connections (fd limit), `TRUNCATE` instead of `DELETE` for the consume step, frame building with a preset `min_heap_size`.
* Frame counting in the socket test is only receive and parse; AES, decode and the database were measured separately and not combined in one run.
