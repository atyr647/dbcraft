# Ada (and SPARK) as the gateway language: measurements against Rust, Go and Tcl

Question: is Ada a good fit for the tiny dbcraft gateway (sockets, VarInt framing, packet decode/encode, AES-CFB8, zlib), using the **real adacraft code** where it applies?
Same inputs, logic and oracle as `docs/TCL-EVALUATION.md`.

**Short answer.** Ada the language is fine: hand-written Ada loops reach about 80% of Rust on VarInt and 50-80% on frame splitting, tie it on library-bound work (zlib, OpenSSL AES), and an
epoll server written in Ada handles 10,000 connections on one core.  About 2,600 players per core of gateway work against Rust's 2,960 and Go's 2,520 (same method, optimistic).
Three things hurt, and none of them is the language:

1. **adacraft's own code, as it stands, is slow on the paths a gateway needs.**  `Packet_Encoder` builds 13.6 k frames/s (74 us per frame) because `Start_Packet` zeroes a 2 MiB array
   every time; Rust does 77 M/s.  Used as-is the gateway budget is 27 players per core.  The frame decoder and `Decode_Varint` are 26-39% of Rust.  All fixable, all measured below.
2. **adacraft builds with `-gnata` and no `-O`** (its Makefile and `.gpr`).  That build is 1.4x to 4.1x slower than `-O2` on most loops here (the hand-written frame split is the one exception).
3. **Tasks are not a connection model.**  One Ada task per connection is one OS thread: 19.7 k rendezvous/s (51 us each) against 389 M/s for a plain loop.  The server has to be an event loop.

**SPARK was not measured.**  I could not obtain `gnatprove` (see "SPARK"); the section gives what exists in adacraft and an effort estimate, clearly labelled as an estimate.

## Setup

Linux x86-64, Intel Xeon 2.1 GHz with AES-NI, 4 cores, GNAT 13.3.0 (Ubuntu), OpenSSL 3.0.13, zlib 1.3, Rust 1.97 (same baseline as the Tcl run, **re-run in the same batch**).
Inputs are the files from `tests/bench/tcl/gen_data.py` (same seed).  Every Ada row checks its own output against `data/expected.txt` and prints `CHECK ... OK`;
**0 wrong results in all four builds** (92 checks OK; the "partial" rows are the as-is encoders run on a prefix, compared to the prefix of the expected output).
zlib output is byte-identical in size to Rust's (99,485 bytes: same libz).

The Ada batch ran with the machine quiet (load average about 1, which is the benchmark itself); an earlier batch at load 4-7 (other forks) gave the same shape.
Best of 25 runs for the fast rows (5 rounds x 5 reps over two batches; Rust 10 reps per round), best of 4 for the slow rows (as-is `Packet_Encoder`, task rendezvous, software AES: 2 reps per round, 2 rounds).
**Noise floor is about +/-15%**: the OpenSSL AES rows are not affected by compiler switches and still moved 50-63 MB/s between variants.  Ratios between 0.85 and 1.15 mean "no difference".

Four builds of the same source (`tests/bench/ada/build.sh`):

| name | switches | meaning |
|---|---|---|
| `-O2` | `-O2` | GNAT default checks (range, index, ...), no contracts |
| `-O2 -gnatp` | `-O2 -gnatp` | all run-time checks suppressed |
| `-O2 -gnata` | `-O2 -gnata` | assertions and Pre/Post contracts enabled |
| `-gnata`, no -O | `-gnata` | **exactly adacraft's `Makefile` / `adacraft.gpr` switches** |

"as-is" rows call the unmodified adacraft packages (copied from commit `4d0b0969` into `tests/bench/ada/adacraft/`: `Varnum`, `Frame`, `Packet_Encoder`, `Zlib`).
"hand-written" rows are tight Ada loops of mine over `Octets`, to separate the cost of the existing code's structure from the cost of the language.

## Results

Rates are per second; zlib and AES in MB/s.  Rust column is this batch.

| benchmark | Ada `-O2` | `-O2 -gnatp` | `-O2 -gnata` | `-gnata`, no -O | Rust | `-O2` / Rust | `-gnatp` / `-O2` |
|---|---|---|---|---|---|---|---|
| VarInt decode, adacraft `Decode_Varint` as-is | 118 M | 126 M | 109 M | 47.5 M | 299 M | 39% | 1.07x |
| VarInt decode, hand-written loop | 242 M | 259 M | 250 M | 175 M | 299 M | 81% | 1.07x |
| VarInt encode, adacraft `Varnum.Encode` as-is, 5-byte scratch (how adacraft calls it) | 97.3 M | 150 M | 87.4 M | 24.0 M | 270 M | 36% | 1.54x |
| VarInt encode, adacraft `Varnum.Encode` as-is, **2 MB buffer** | 120 M | 178 M | **7.5 k** | **8.7 k** | 270 M | 44% | 1.49x |
| VarInt encode, hand-written loop | 221 M | 270 M | 249 M | 97.4 M | 270 M | 82% | 1.22x |
| frame split, adacraft `Decode_Frame`, no body copy | 42.0 M | 40.3 M | 44.1 M | 17.9 M | (52.5 M) | 80% | 0.96x |
| frame split, `Decode_Frame` + heap copy of each body | 24.0 M | 25.3 M | 24.7 M | 15.5 M | 55.3 M | 43% | 1.05x |
| frame split, hand-written loop + scratch copy | 26.5 M | **83.9 M** | 27.5 M | 53.1 M | 55.3 M | 48% | **3.16x** |
| frame split, adacraft stateful `Frame.Feed` (4 KiB reads, callback) | 14.2 M | 22.6 M | 18.1 M | 8.7 M | 55.3 M | 26% | 1.59x |
| position decode (200k) | 45.9 M | 79.0 M | 56.2 M | 17.5 M | 257 M | 18% | 1.72x |
| build frames, adacraft `Packet_Encoder` as-is | **13.6 k** | 18.2 k | 17.6 k | 15.9 k | 77.4 M | 0.02% | 1.33x |
| build frames, hand-written | 34.5 M | 87.1 M | 36.4 M | 8.5 M | 77.4 M | 45% | 2.52x |
| connections, plain loop (2000 x 100) | 389 M | 610 M | 446 M | 124 M | 717 M | 54% | 1.57x |
| connections, **Ada task per connection**, no synchronisation | 1.44 M | 1.59 M | 1.40 M | 1.48 M | 717 M | 0.2% | 1.10x |
| connections, Ada task per connection, rendezvous per packet | **19.7 k** | 21.1 k | 18.4 k | 19.9 k | 717 M | 0.003% | 1.07x |
| zlib compress 1 MiB L6 (adacraft binding) | 92 MB/s | 84 | 91 | 107 | 95 | 97% | (noise) |
| zlib decompress 1 MiB | 732 MB/s | 663 | 735 | 835 | 746 | 98% | (noise) |
| AES-128-CFB8 encrypt, portable software Ada | 0.5 MB/s | 0.5 | 0.5 | 0.1 | 7.5 | 7% | - |
| AES-128-CFB8 encrypt, OpenSSL EVP (1 MiB call) | 59.6 MB/s | 50.3 | 58.7 | 62.8 | 61.8 (AES-NI) | 97% | (noise) |
| AES-128-CFB8 decrypt, OpenSSL EVP | 66.0 MB/s | 60.2 | 57.6 | 67.8 | 547.7 (4 blocks in flight) | 12% | (noise) |
| AES-128-CFB8 encrypt, OpenSSL EVP in 1000-byte calls (per message) | 63.3 MB/s | 56.2 | 56.3 | 63.7 | 61.8 | 102% | (noise) |
| AES-128-CFB8 decrypt, OpenSSL EVP in 150-byte calls | 66.7 MB/s | 61.2 | 62.9 | 68.1 | 547.7 | 12% | (noise) |

The Rust frame-split row copies each body (`to_vec`); the "no body copy" Ada row is compared with Rust's no-copy number from `split_index`.
Go (from `docs/GO-EVALUATION.md`, not re-measured here, different load): VarInt decode 241 M/s, frame split with copy 24.7 M/s, position decode 265 M/s, build frames 41.1 M/s, serial AES encrypt 56 MB/s.
Hand-written Ada at `-O2` is level with Go on VarInt (242 M) and frame split (26.5 M), 16% behind on build frames, and 5.8x behind on position decode (see below).

### What the numbers say

**1. Checks cost 1.0x to 1.7x on most rows and 2.5x to 3.2x on loops that copy bytes.**  `-gnatp` vs `-O2`: VarInt 1.07-1.5x; position decode 1.7x; hand-written build frames 2.5x; hand-written frame split 3.2x.
A probe (`tests/bench/ada/src/split_probe.adb`, same loop, three ways to move the body) shows where: with checks on at `-O2`, a slice assignment ran at 22 M frames/s and an explicit byte loop at 17.7 M/s,
against 79.5 M and 83.9 M with `-gnatp`, and 138 M with no copy at all.  Index checks on a global access-to-array turn a copy into a per-byte checked operation.
Odd and not investigated: at `-O0` with checks the slice assignment (a `memmove` call) ran at 42.6 M/s, faster than the `-O2` code.
**This is exactly the cost SPARK proofs remove**: code proven free of range errors can be built with checks suppressed.

**2. adacraft's `Packet_Encoder` is the outlier: 13.6 k frames/s, about 74 us per frame.**  `Start_Packet` executes `E.Storage := (others => 0)` over the encoder's whole 2 MiB array on every packet
(`adacraft-protocol-packet_encoder.adb`), and `Get_Framed` zeroes its output array too.  Compiler switches do not change it (13.6-18.2 k/s in all four builds).  An `Encoder_Type` object is 2 MiB, so it must be
heap-allocated (my first run died with `STORAGE_ERROR` from large stack arrays in the harness; the encoder itself must also stay off task stacks).  Not zeroing the array (only `Count` matters) or sizing storage by `Capacity` should
bring it close to the hand-written 34.5 M/s; I did not make that change because the directive was to measure the code as it is.

**3. `Decode_Varint` and `Decode_Frame` are middling, `Frame.Feed` is slow.**  `Decode_Varint` (record result, strict minimal-form checks) is 118 M/s against 242 M/s for a bare loop: it is 39% of Rust.
`Decode_Frame` without a copy is 80% of Rust.  The stateful `Frame.Feed` that adacraft's network layer actually uses is 26% of Rust: it handles one byte per iteration through a record update and a callback.
Its `Decoder_Type` also embeds a `Body_Bytes` array of 2,097,151 bytes, so every connection carries a 2 MiB decoder: 64 connections (adacraft's `Max_Conns`) is 128 MB, 10,000 would be 20 GB of address space.
That is only a problem at the player counts dbcraft targets, not at adacraft's current 64-connection table.

**4. `Varnum.Encode`'s postcondition copies the buffer when assertions are on and the buffer is large.**  With `-gnata` and a 2 MB caller buffer it ran at 7.5 k calls/s: the failure branch of the
postcondition mentions `Buffer'Old`, and GNAT copies the whole buffer on entry.  adacraft itself calls it with 5-byte scratch buffers, where `-gnata` costs only 10% (87 M/s).  A caller that passes a large buffer would hit this.

**5. adacraft's own build flags are the slowest configuration.**  `-gnata` without `-O`: VarInt decode 47.5 M/s vs 118 M (2.5x), hand-written build frames 8.5 M vs 34.5 M (4.1x),
`Decode_Frame` 17.9 M vs 42.0 M (2.3x), plain connection loop 124 M vs 389 M (3.1x).  Adding `-O2` is free (the `-O2 -gnata` column is within noise of `-O2`, apart from the `Buffer'Old` case in point 4).

**6. Position decode is 5.6x behind Rust because of how I wrote it.**  The hand-written `BE64` assembles 8 bytes with a shift loop; Rust's `from_be_bytes` becomes one load and `bswap`.  `-gnatp` gives 79 M/s.
That is a code-quality gap in my loop (an `Unchecked_Conversion` of an 8-byte slice plus a byte-swap would close most of it), not a language limit; I did not tune it.

**7. Tasks are not a connection model.**  GNAT on Linux maps every Ada task to a pthread.  Creating 2,000 tasks and running a trivial 100-round body takes 0.14 s (70 us per task);
delivering 200,000 packets by rendezvous takes about 10 s (51 us each, dominated by futex wake-ups across 2,000 threads), against 0.5 ms for the plain loop.  The server has to be an event loop (the epoll server below),
or at most a small pool of worker tasks.

**8. AES: OpenSSL through `Interfaces.C` is as fast as the Rust AES-NI code for encryption; my software port is not.**  The EVP binding is about 60 lines (`src/gw_aes.ads` and the first half of `gw_aes.adb`) and
all five AES checks matched `openssl enc` on the first run.  Encrypt: 59.6 MB/s (97% of Rust's 61.8), and 63 MB/s with a persistent context and 1000-byte calls (the per-message pattern).
Decrypt is 66 MB/s: OpenSSL's CFB8 decrypt is not pipelined, where Rust's hand-written 4-blocks-in-flight code reaches 548 MB/s.  That gap is irrelevant to the gateway (about 150 inbound bytes per player per tick).
The portable software AES I ported from the Rust one runs at 0.5 MB/s against Rust's 7.5 MB/s (14x): Gmul by function call, block copies by value and checks.  It is not the right tool and I did not tune it.

**9. zlib through adacraft's binding is libz speed** (92 MB/s compress, 732 MB/s decompress, 97-98% of Rust, same 99,485 output bytes).

## Players one core can serve (gateway work only, 20 TPS => 50 ms budget per tick)

Same assumptions as `docs/TCL-EVALUATION.md`: per player per tick 5 inbound packets (frame split + position decode), 25 outbound frames (about 1000 B), AES-CFB8 over 1000 B out and 150 B in.
Optimistic for every row: no syscalls, no libpq, no zlib, no scheduling.

| variant | framing + decode | AES-CFB8 | per player-tick | players/core (100% busy) | players/core (70% busy) |
|---|---|---|---|---|---|
| Ada `-O2`, **adacraft code as-is** (`Packet_Encoder`, `Decode_Frame` + copy), OpenSSL AES | 1,833 us | 18.1 us | 1,851 us | **27** | 19 |
| Ada `-O2`, hand-written loops, OpenSSL AES, per-message calls | 1.0 us | 18.1 us | 19.1 us | 2,621 | 1,835 |
| Ada `-O2 -gnatp`, hand-written loops, OpenSSL AES, per-message calls | 0.4 us | 20.3 us | 20.7 us | 2,420 | 1,694 |
| Ada `-O2`, hand-written loops, OpenSSL AES, 1 MiB calls (like the Rust row) | 1.0 us | 19.0 us | 20.1 us | 2,493 | 1,745 |
| Rust, AES-NI (this batch) | 0.4 us | 16.5 us | 16.9 us | 2,960 | 2,072 |
| Go, copy-body framing, serial AES (`docs/GO-EVALUATION.md`) | 0.8 us | 19.0 us | 19.8 us | 2,522 | 1,766 |
| Tcl + tcl-aot, native AES (`docs/TCL-EVALUATION.md`) | 41.1 us | 17.6 us | 58.7 us | 852 | 596 |

The `-gnatp` row is lower than `-O2` only because the OpenSSL AES rate happened to be 50 MB/s in that variant's runs (noise); its framing part is 2.5x cheaper.
AES encryption is 95-98% of the per-player cost in the compiled rows other than the as-is one (30% in the Tcl row), so for the compiled languages the cipher, not the language, sets the limit.

## Sockets

`src/sock_select.adb` is a server in the style of adacraft's network layer (`GNAT.Sockets`, `Check_Selector` = `select()`, non-blocking); `src/sock_epoll.adb` is the same server on a hand-written epoll binding
(libc `socket`/`accept4`/`read`/`write`/`epoll_*` through `pragma Import`, 203 lines in total including the per-connection parser; written and working in about 20 minutes).
Protocol and client are the Tcl benchmark's (`tests/bench/tcl/sock_client.py`: batches of 20 frames, one ack byte per batch).  Server CPU is measured with `Ada.Execution_Time`.
The clients are Python and are the bottleneck at low counts, so the CPU column is the capacity figure.

```
tests/bench/ada/sock_run.sh select|epoll NCONN [CLIENT_PROCS] [DUR_SECONDS]      # e.g. sock_run.sh epoll 10000 5 8
```

| server | clients | frames/s | server CPU busy | frames per server-CPU-second |
|---|---|---|---|---|
| `GNAT.Sockets` select | 900 | 872 k | 41% | 2.11 M |
| epoll (libc imports) | 900 | 658 k | 28% | 2.38 M |
| `GNAT.Sockets` select | 2,000 | **crashes**: `raised CONSTRAINT_ERROR : invalid value for socket set: 1024` | | |
| epoll | 2,000 | 551 k (client-bound) | 26% | 2.11 M |
| epoll | 5,001 | 2.15 M | 78% | 2.77 M |
| epoll | 10,000 | 1.88 M | 79% | 2.38 M |

* GNAT.Sockets cannot hold a descriptor numbered 1024 or above in a socket set (it raises a clean `Constraint_Error`, where Tcl 8.6 aborts), so the adacraft `select()` design stops near 1,000 connections, as well as having its 64-entry table.
* On epoll one core serves 2.1-2.8 M frames/s, including parsing and the ack write: a player sends about 100 frames/s, so socket handling alone is nowhere near the limit.
* The 5- and 10-client-process runs shared the 4 cores with the server, so the frames/s there are a lower bound.  The container's descriptor limit is 20,000, so 10,000 is the largest count tested.
* What the epoll server lacks for production: write backpressure (`EPOLLOUT`, partial writes), timeouts, accept error handling, and a thread per core with `SO_REUSEPORT`.

## SPARK

**Not run.**  `gnatprove` is not in the Ubuntu archive here (`apt-cache search gnatprove` is empty).  The documented route is Alire (the release asset `alr-2.0.2-bin-x86_64-linux.zip` is reachable through the proxy),
but downloading and running an external binary was denied by this session's permission policy, and I did not work around that.  Nothing in this section is a measurement.

What exists in adacraft (read from the source): `Adacraft.Protocol.Varnum` is `SPARK_Mode => On` with contracts (`Global => null`, postconditions on `Encode`/`Decode`/`Decode_Varint`); `State`, `State.Table`, `Version` and `Kernel` are `SPARK_Mode`;
`Frame`'s spec is `SPARK_Mode` with `Decode_Frame` in SPARK but `Feed`, `Encode` and `Write_Length_Prefix` set to `Off` (access-to-subprogram callback, 2 MiB state record).
`ROADMAP.md` puts `gnatprove` in Phase 6 and `docs/KERNEL.md` says discharge "is not claimed", so there is no existing proof result to confirm or contradict.

Effort estimate, unmeasured: `Varnum` decode/encode with loop invariants, 1-2 days; `Decode_Frame` (the arithmetic needs `Next <= Buffer'Last + 1` from the `Decode_Varint` postcondition), about 1 day;
`Frame.Feed` would need redesign into a SPARK-friendly iterator (`Next_Frame (Decoder, Chunk, Pos, First, Last, Status)` with no callback and a small bounded buffer), 2-4 days; `Packet_Encoder`, 1-2 days including removing the 2 MiB zeroing.
Commands I would have run (not verified): `gnatprove -P <project>.gpr --mode=all --level=2 -u adacraft-protocol-varnum.adb adacraft-protocol-frame.adb`, with `gnat_native` and `gprbuild` from the same Alire toolchain.

## Hand-binding the other libraries (partly measured)

| library | status |
|---|---|
| zlib | binding already in adacraft (`Adacraft.Protocol.Zlib`); works, libz speed |
| OpenSSL EVP (AES-CFB8) | **written here**: about 60 lines, correct on the first run |
| epoll / sockets | **written here**: about 200 lines including the server loop and parser |
| libpq (async, `COPY` in, pipeline mode, `LISTEN` notifications) | not written.  Estimate 300-400 lines and a couple of days of testing: `PQconnectStart`, `PQsetnonblocking`, `PQputCopyData`/`PQputCopyEnd`, `PQconsumeInput`/`PQisBusy`, `PQnotifies`, `PQenterPipelineMode` |
| libcurl, or an OpenSSL BIO HTTPS client (Mojang session check) | not written.  Estimate 150-250 lines; libcurl needs a C-convention write callback |
| RSA key exchange (online mode) | not written; OpenSSL `EVP_PKEY` calls, similar in size to the AES binding |

Existing Ada libraries that would shorten this (GNATCOLL.SQL for PostgreSQL, AWS for HTTPS) were not evaluated here; from memory neither offers `COPY` or pipeline mode, which this gateway wants.

## Conclusion

* **Speed is not the reason to avoid Ada.**  With the cipher done by OpenSSL, hand-written Ada is within 15-20% of Rust and Go per core (2,600 vs 2,960 and 2,520 players), 3x ahead of Tcl with native AES, and an epoll server in Ada holds 10,000 connections.
* **adacraft's present code is not gateway-ready**, but the problems are specific: the 2 MiB zeroing in `Packet_Encoder`, the 2 MiB-per-connection `Decoder_Type` and byte-at-a-time `Feed`, the `select()` layer, and the unoptimised `-gnata` build.  Together they cost 100x on the encoder path (27 players per core as-is).
* **Compared with the other candidates**, Ada's real disadvantage is the ecosystem and the binding work: Rust (`tokio-postgres`, `rustls`, `aes`/`cfb8`) and Go (`pgx`, `crypto/tls`) have the Postgres `COPY`/pipeline client, the HTTPS client and the async runtime;
  in Ada the first and third would be hand-written (estimates above, only OpenSSL AES and epoll actually done).  Go's collector risk is measured in `docs/GO-EVALUATION.md` (small for a stateless gateway).
* **Is SPARK worth it for a hostile-input parser?  My opinion, not a measurement:** for the framing and VarInt layer, yes.  It is a few hundred lines of loop-free arithmetic, which is what the prover handles best, and it is exactly the code where the 1.0-3.2x cost of run-time checks sits:
  a proof that there is no overflow or out-of-bounds access lets you ship `-gnatp` for that layer.  The cost is the redesign of `Frame.Feed` and the proof effort estimated above, and I cannot say how much would prove automatically until `gnatprove` has been run on it.
  For the rest (sockets, libpq, HTTPS) SPARK gives nothing, because it cannot reach into C libraries.
* **Recommendation:** if the aim is the fastest route to a working, fast gateway, use Rust or Go.  If you want to keep Ada because of adacraft and SPARK, it is viable on performance, provided you (1) fix the encoder and decoder as above,
  (2) build with `-O2`, (3) use an epoll loop, not tasks or `select()`, (4) budget the libpq and HTTPS bindings, and (5) run `gnatprove` on the codec before relying on any of the SPARK claims.

## Files and commands

```
tests/bench/ada/build.sh                 # four builds -> bin/gwbench_{O2,O2_nochecks,O2_gnata,adacraft_flags}
tests/bench/ada/run_all.sh               # Rust baseline + 4 Ada builds, ROUNDS (default 2) x REPS (default 5); SKIP_SLOW=1 skips task rendezvous, software AES and the as-is packet encoder
python3 tests/bench/ada/summarize.py DIR [DIR ...]      # best of all runs in the given output directories
tests/bench/ada/sock_run.sh epoll 10000 5 8             # socket servers (src/sock_select.adb, src/sock_epoll.adb)
# this document: OUT=out_fast SKIP_SLOW=1 ROUNDS=3 run_all.sh, then OUT=out_slow2 ROUNDS=2 run_all.sh, then summarize.py out_fast out_slow2
```

Sources: `tests/bench/ada/src/` (`gwbench.adb`, `gw_aes`, `gw_conns`, `gw_timing`, `sock_select.adb`, `sock_epoll.adb`, `split_probe.adb`), unmodified adacraft units in `tests/bench/ada/adacraft/` (see `SOURCE_COMMIT.txt`).
Build outputs, logs and binaries are gitignored.
