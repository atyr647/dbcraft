# Go as the gateway language: measurements against Rust and Tcl

Question: is Go a good language for the tiny dbcraft gateway (sockets, VarInt framing, packet decode/encode, AES-CFB8, zlib), and is its garbage collector a
real risk for a 20 TPS tick loop?  Same inputs, same logic, same oracle as `docs/TCL-EVALUATION.md`, so the Rust and Tcl columns below are copied from that
run (`tests/bench/tcl/out/*.log`), not re-measured.

**Short answer.** For gateway work Go lands within 0.5x to 1.1x of Rust on the framing and decode rows, ties it on serial AES-CFB8 encryption, and is
6x to 95x faster than Tcl with tcl-aot on those rows (up to about 300x for an event-style state machine).  It is a good fit.  Its costs against Rust are (1) allocation-heavy paths about 2x slower, (2) no control over
AES pipelining through the standard library (decrypt 137 MB/s against 515 MB/s), and (3) a garbage collector that adds a tail to tick lateness when the heap
holds a lot of pointers and the CPU is saturated.  Point (3) is much smaller for a stateless gateway than for a normal server, and it is measured below.

## Setup

Linux x86-64, 4 cores shared with other benchmark forks (load average 1 to 6 while this ran), Go 1.24.7 (`GOTOOLCHAIN=local`),
`github.com/klauspost/compress` v1.17.11 (the module proxy was reachable).  Go's `crypto/aes` uses AES-NI assembly.  The standard library has only
CFB128, so CFB8 is one `Block.Encrypt` call per byte, written by hand (`micro/main.go`).  Microbenchmarks run with `GOMAXPROCS=1` (per-core numbers),
best of 5 to 7 repetitions, over 5 rounds.  Spread between rounds was 4% to 10% for most rows and 20% to 100% for AES, the event-style state machine
and the short zlib rows, because of the other load on the machine.  The Rust and Tcl columns come from an earlier run on the same machine at a different load, so ratios near 1.0 mean "no difference".

All Go `RESULT` lines match the Python/openssl oracle (`tests/bench/tcl/data/expected.txt`); the extra Go-only checks (`split_nocopy`,
`aes_cfb8_x4` against the single-stream encryptor, the `aes_cfb8_dec` round trip, and the 128 KiB zlib round trips) also pass.

### Commands

```
tests/bench/go/run_all.sh        # builds, runs 5 micro rounds (+1 at GOMAXPROCS=4), the oracle check, 9 socket scenarios, and the summary (about 10 minutes)

# or by hand, from tests/bench/go (needs tests/bench/tcl/gen_data.py to have produced ../tcl/data):
export PATH=$PATH:/usr/local/go/bin GOTOOLCHAIN=local GOFLAGS=-mod=mod
go build -o bin/gobench ./micro && GOMAXPROCS=1 REPS=5 bin/gobench ../tcl/data
go build -o bin/sockserver ./sock/server && go build -o bin/sockclient ./sock/client
PACE_MS=500 ./run_sock.sh 19000                                    # about 70% load, no extra heap
PACE_MS=200 ./run_sock.sh 19000 GOGC=10 HOLD_PTR_MB=1024           # saturated, 1 GB of pointer-rich live heap
python3 summarize.py                                               # the tables below
```

## Results

| benchmark | Tcl interp | Tcl + tcl-aot | Go (GOMAXPROCS=1) | Rust | Go / Rust |
|---|---|---|---|---|---|
| VarInt decode (1M) | 3.6 M/s (5 MB/s) | 40.8 M/s (55 MB/s) | 240.7 M/s (325 MB/s) | 269.4 M/s (364 MB/s) | 0.89x |
| VarInt encode (1M) | 7.8 M/s (11 MB/s) | 16.2 M/s (22 MB/s) | 233.0 M/s (314 MB/s) | 249.6 M/s (337 MB/s) | 0.93x |
| frame split, copy body (200k frames) | 803 k/s (34 MB/s) | 826 k/s (35 MB/s) | 24.7 M/s (1,035 MB/s) | 48.1 M/s (2,016 MB/s) | 0.51x |
| frame split, no copy (Go slice into input) | - | - | 137.2 M/s (5,755 MB/s) | - | - |
| position decode (200k) | 2.4 M/s (81 MB/s) | 2.8 M/s (91 MB/s) | 264.9 M/s (8,741 MB/s) | 235.6 M/s (7,775 MB/s) | 1.12x |
| build frames (200k) | 724 k/s (23 MB/s) | 752 k/s (24 MB/s) | 41.1 M/s (1,316 MB/s) | 73.3 M/s (2,344 MB/s) | 0.56x |

Connection state machines, 2000 conns x 100 packets (200k packet deliveries):

| design | packets/s |
|---|---|
| Tcl coroutine per connection, interpreter | 1.15 M/s |
| Tcl coroutine per connection, tcl-aot | 1.23 M/s |
| Go goroutine per connection, unbuffered channel (GOMAXPROCS=1) | 3.40 M/s |
| Go goroutine per connection, 128-slot channel (GOMAXPROCS=1) | 21.26 M/s |
| Go single goroutine, event style (GOMAXPROCS=1) | 389.40 M/s |
| Rust enum state machine | 657.14 M/s |

Same Go channel designs with GOMAXPROCS=4: coro 3.24 M/s, coro_buf 5.67 M/s, coro_event 261.58 M/s

zlib / AES (one core):

| benchmark | Tcl (libz) | Go compress/zlib | Go klauspost | Rust (libz) |
|---|---|---|---|---|
| zlib compress 1 MiB L6 | 89 MB/s | 75 MB/s | 228 MB/s | 85 MB/s |
| zlib decompress 1 MiB | 725 MB/s | 497 MB/s | 461 MB/s | 662 MB/s |
| zlib compress 128 KiB L6 | - | 76 MB/s | 173 MB/s | - |
| zlib decompress 128 KiB | - | 578 MB/s | 540 MB/s | - |

| AES-128-CFB8, 1 MiB | MB/s |
|---|---|
| Tcl pure-Tcl AES (tcllib, tcl-aot, 64 KiB) | 24.1 kB/s |
| Rust AES-NI encrypt, serial | 58 MB/s |
| Rust AES-NI decrypt, 4 blocks in flight | 515 MB/s |
| Go crypto/aes, one Block.Encrypt per byte, encrypt | 56 MB/s |
| Go, encrypt, 4 connection streams interleaved | 153 MB/s |
| Go, decrypt | 137 MB/s |

Notes:

* "copy body" is the like-for-like row (Tcl and Rust copy the body out of the frame); "no copy" is the idiomatic Go loop (a slice into the input buffer) and
  has no Rust or Tcl counterpart, so no ratio is given.  A no-copy Rust loop would also be much faster than Rust's 48 M/s.
* Go's channel designs are for one goroutine per connection.  An unbuffered channel is the closest analogue of the Tcl coroutine resume and costs a goroutine
  switch per packet (3.4 M/s on one core, 3.2 M/s with four, since it is latency-bound).  A 128-slot buffer takes it to 21 M/s.  The event-style single
  goroutine reaches 389 M/s, the same design as the Rust row.  At 100 packets per second per player, even the unbuffered design is not the bottleneck.
* zlib: Go's `compress/zlib` is slower than libz (75 against 85 to 89 MB/s compress, 497 against 662 to 725 MB/s decompress) and, at level 6, produced
  97,065 bytes against libz's 99,485.  klauspost's compress is 2.6x to 3x faster at compress (228 MB/s) and produced 90,777 bytes.  In dbcraft the database
  compresses chunks once (see `docs/COMPRESSION.md`), so the gateway only inflates the rare large serverbound packet; zlib speed is not on the critical path.
* AES: serial encrypt is latency-bound (each byte needs the previous ciphertext byte), and Go and Rust are equal at 56 and 58 MB/s.  Interleaving four
  independent connection streams in Go, with no assembly and no cgo, gives 153 MB/s (2.7x), because the CPU overlaps the independent `Encrypt` calls.
  Rust's decrypt gets 515 MB/s from four blocks in flight; Go's standard `cipher.Block` API cannot express that, so Go decrypt is 137 MB/s.
  Inbound traffic is about 150 B per player per tick, so decrypt speed barely matters.  An interleaved Rust encryptor was **not measured**; it would be
  at least as fast as Go's, so do not read the "Go 4-stream" row below as Go beating Rust.

Players per core, gateway work only (20 TPS; per player per tick: 5 inbound packets, 25 outbound frames, AES over 1000 B out + 150 B in):

| variant | framing + decode | AES-CFB8 | per player-tick | players/core (100%) | players/core (70%) |
|---|---|---|---|---|---|
| Tcl + tcl-aot, native AES (Rust serial AES-NI + dec rates) | 41.1 us | 17.6 us | 58.7 us | 852 | 596 |
| Rust, AES-NI (serial encrypt) | 0.5 us | 17.6 us | 18.1 us | 2,769 | 1,939 |
| Go, copy-body framing, serial AES (same method as Rust row) | 0.8 us | 19.0 us | 19.8 us | 2,522 | 1,766 |
| Go, no-copy framing, serial AES | 0.7 us | 19.0 us | 19.7 us | 2,544 | 1,780 |
| Go, no-copy framing, 4-stream interleaved AES | 0.7 us | 7.6 us | 8.3 us | 6,027 | 4,219 |

How these were computed is the same as `docs/TCL-EVALUATION.md` (gateway work only: no syscalls, no libpq, no zlib, no scheduling or GC cost; optimistic
for every variant).  Go's "no-copy" rows assume the decoder can slice into the read buffer.  The Rust and Tcl rows reproduce the earlier document.

## Sockets, GC pauses and tick lateness

`sock/server` is a loopback gateway-shaped server (goroutine per connection, the same protocol as the Tcl socket test: batches of 20 position frames, one ack
per batch).  To produce garbage like a real gateway it copies every frame body and builds a 1,000-byte outbound buffer per ack.  A 50 ms ticker goroutine
(sleep to a deadline, record how late it wakes) stands in for the 20 TPS loop.  `sock/client` is a separate process.  Server: 2 cores (`taskset 0,1`,
`GOMAXPROCS=2`); client: the other 2.  The first attempt, with both on all four cores, is in the first row only: it shows how sensitive pause and lateness
numbers are to CPU contention.  The container's hard limit is 20,000 file descriptors and cannot be raised, so the "20k" scenarios use **19,000
connections** (the listener, epoll and stdio need descriptors too).  "Paced" clients sleep 500 ms (about 40 frames/s per connection) or 200 ms (about
100 frames/s, a real player's rate) after each ack; "saturated" clients send as fast as acks return.  The GC pause column is the **upper bound of the Go runtime
histogram bucket** (`/sched/pauses/total/gc:seconds`), so it is coarse; total stop-the-world time is exact.

| scenario (server on 2 cores) | frames/s | GC cycles | STW pause, worst bucket bound | total STW | tick lateness p50 / p99 / max | ticks > 25 ms |
|---|---|---|---|---|---|---|
| 5,000 saturated, **unpinned** (4 cores shared with client and other forks) | 2.64 M | 83 | 14.7 ms | 367 ms | 1.6 / 19.5 / 23.7 ms | 0 |
| 5,000 saturated | 3.35 M | 107 | 0.66 ms | 27 ms | 0.01 / 2.8 / 8.5 ms | 0 |
| 5,000 paced 200 ms (about 96 frames/s each) | 478 k | 16 | 2.6 ms | 7 ms | 0.5 / 2.1 / 4.1 ms | 0 |
| 19,000 paced 500 ms (about 70% busy) | 750 k | 6 | 5.2 ms | 6 ms | 0.4 / 6.2 / 23.2 ms | 0 |
| 19,000 paced 200 ms (saturated, target 1.9 M/s) | 1.23 M | 10 | 5.2 ms | 12 ms | 0.1 / 13.5 / 23.5 ms | 0 |
| 19,000 saturated closed loop | 1.51 M | 12 | 8.4 ms | 30 ms | 0.1 / 22.0 / 57.6 ms | 3 |
| 19,000 paced 200 + **1 GB pointer-free buffers**, `GOGC=10` | 1.18 M | 16 | 5.2 ms | 32 ms | 0.6 / 14.0 / 17.0 ms | 0 |
| 19,000 paced 200 + **1 GB pointer-rich objects** (64 B nodes), `GOGC=10` | 873 k | 10 | 7.3 ms | 15 ms | 0.1 / **39.5** / **70.2** ms | 6 |
| 19,000 paced 500 + 1 GB pointer-rich, `GOGC=10` | 639 k | 7 | 1.0 ms | 3 ms | 0.2 / 12.1 / 24.0 ms | 0 |
| 19,000 paced 500 + 1 GB pointer-rich, default `GOGC`, 40 s window | 681 k | 2 | 0.5 ms | 1 ms | 0.4 / 16.0 / 38.5 ms | 4 |

What this says:

* **Go's event loop is not the limit.**  One process on two cores served 19,000 connections at 0.75 M to 1.5 M frames per second.  The Tcl process crashed at
  1,024 connections and peaked at 0.8 M frames/s with 900.  (Not measured: the Rust socket path.)
* **Stop-the-world pauses are small**: 1 to 32 ms in total per 15 s window over 6 to 107 cycles, an average pause of 0.1 to 1.2 ms, and the worst bucket in the
  saturated pinned 5,000-connection run was 0.66 ms.  The bucket bounds of 5 to 8 ms in the 19,000 runs are histogram resolution, not measured pause lengths;
  they are probably inflated by CPU contention (the unpinned row shows 14.7 ms for the same load that pinned showed 0.66 ms).
* **The tail comes from CPU competition, not pauses.**  With no extra heap the 50 ms ticker was still up to 23 ms late at about 70% load.  That is the floor
  of this machine (load average around 5 on 4 cores) and of a saturated server.  1 GB of pointer-free buffers changed nothing measurable.
* **A big pointer-rich live heap does hurt at saturation**: p99 39.5 ms and max 70.2 ms (more than one whole tick) with `GOGC=10`.  At about 70% load the same
  heap gave p99 12 ms (6.2 ms without it) and a similar max (24 against 23 ms).  With the default `GOGC` and a 40 s window (only 2 collections) p99 was 16 ms
  and the max 38.5 ms, with 4 ticks over 25 ms.  So below saturation the pointer-rich heap roughly doubles p99 and the tail stays inside the 50 ms budget in these runs.
* **The scenario that hurts is the one dbcraft avoids**: a gateway that keeps game state in the Go heap.  dbcraft's gateway is stateless; its live heap is per-connection
  byte buffers (pointer-free) plus a small table of connections.  The closest rows are the pointer-free ones, which showed no measurable GC penalty.
* **Caveats**: single run per scenario; the other forks' CPU use (load 3 to 6) affected all rows; the ticker measures scheduler latency, not an actual tick; clients and
  server share one machine; `GOGC=10` is a stress setting, not a recommendation.

## Conclusion

* **Go versus Rust.**  On framing, VarInt and position decode Go is 0.9x to 1.1x of Rust; on rows dominated by allocation (copying frame bodies, building frames)
  it is 0.5x to 0.6x; serial AES-CFB8 encryption is equal.  Go loses on decrypt (no way to pipeline blocks through `crypto/cipher`: 137 against 515 MB/s) and has a GC.
  It wins on development speed, a standard library that already has `net`, AES-NI and a good `epoll` scheduler, simple goroutine-per-connection code, and an
  optional faster zlib (klauspost, 228 MB/s).
* **Go versus Tcl.**  Not close: 1.2 M packets/s for Tcl coroutines against 3.4 M to 21 M for Go's goroutines (389 M for an event-style loop), 6x to 95x on the framing and decode rows, and Go has none of
  Tcl's limits (1,024 sockets, crypto in C only).
* **Players per core (gateway work only, optimistic).**  About 2,500 for Go with the same serial-AES assumption as the Rust row (2,800), against 850 for Tcl
  with a hypothetical native AES; about 6,000 for Go if encryption interleaves four streams (Rust interleaving not measured).
* **Is GC a risk for a 20 TPS loop?**  A manageable one for dbcraft's design.  Pointer-free heaps showed no measurable penalty beyond the machine's own noise; a pointer-rich 1 GB heap roughly doubled p99 at 70% load (max still within
  one tick), and the pathological case (saturated CPU and 1 GB of pointer-rich heap) exceeded one tick.  Mitigations: keep the heap pointer-free (byte buffers), pool buffers,
  avoid per-packet garbage, cap the server below saturation, tune `GOGC` or `GOMEMLIMIT`.  Rust has no such risk at all.
* **Recommendation.**  Rust remains the first choice if tail latency at saturation matters most and AES pipelining is wanted; Go is a legitimate second choice
  that is simpler to write and maintain, and for "as many players as possible" the throughput numbers are comparable.  The decision should rest on whether you
  prefer GC-free tail behaviour (Rust) or faster iteration (Go), not on throughput.
* **Not measured**: the database path (`pgx` `COPY` batching against Rust's `tokio-postgres`), a Rust socket server, zlib deflate of cached chunk fragments in either
  language, and anything over 19,000 connections per process.
