# Odin as the dbcraft gateway language

Question: is [Odin](https://odin-lang.org) a good language for the tiny dbcraft gateway (sockets, framing, AES-CFB8, optional zlib, libpq batching, Mojang HTTPS), measured against the
same workloads as the Rust and Tcl benchmarks (`docs/TCL-EVALUATION.md`)?

**Short answer: as fast as Rust where it was measured, but not a good fit for the network-facing part.** With the right idiom (arena or no per-frame allocation, bounds checks
switched off only inside audited hot loops) Odin matched the Rust baseline within noise on VarInt decode, position decode, state machines, zlib and AES-CFB8 (about 1.0x), and beat it on
frame building. Its weak points are the things around the loops: no memory safety, a small and still-moving ecosystem, a Linux async I/O layer that needs `io_uring`
(blocked by Docker's default seccomp profile), and no ready bindings for libpq or OpenSSL, nor CFB8 in its own crypto.

## Setup

* Odin `dev-2026-10` (tag, commit `84bc3fc`), **built from source** in 1.5 minutes with LLVM 18.1.3 (`build_odin.sh release`). The release binaries and the GitHub API are blocked by this
  container's proxy, but anonymous `git clone` works.
* Same machine and inputs as the other evaluations: Linux x86-64, 4 cores, `tests/bench/tcl/data` (fixed seed), the Rust baseline from `tests/bench/tcl/rust` (opt-level 3, LTO).
* **Load:** other benchmark processes were running throughout; the load average was 2.4 during the timed run and 4 to 5 during the socket test.
  Every row is the best of 20 samples (4 rounds, alternating Rust, Odin checked, Odin unchecked, 5 repetitions each).
  The checked-vs-unchecked columns disagree in both directions (for example "checks cost" of 0.77x, where the checked build was faster), so **differences below about 25% are noise**.
* Correctness: all three programs print the same `RESULT` lines as the Python/openssl oracle (`gen_data.py`), including the extra Odin variants.

```
git clone --depth 1 https://github.com/odin-lang/Odin && cd Odin && git fetch --depth 1 origin tag dev-2026-10 && git checkout dev-2026-10
apt-get install llvm-18-dev libclang-18-dev clang-18                      # LLVM 17 to 22 are supported (SUPPORTED_LLVM_VERSIONS in build_odin.sh)
LLVM_CONFIG=/usr/lib/llvm-18/bin/llvm-config ./build_odin.sh release
python3 tests/bench/tcl/gen_data.py                                       # shared inputs and oracle
ODIN_ROOT=/path/to/Odin tests/bench/odin/run.sh                           # builds, runs 3 rounds (ROUNDS=4 REPS=5 used here), writes out/summary.md
ODIN_ROOT=/path/to/Odin tests/bench/odin/echo/run_echo.sh 5000 200        # nbio echo server against tests/prototype/pl_gateway_load.py
```

Compile flags: `-o:speed` ("checked", Odin's default keeps bounds checks and assertions) and `-o:speed -disable-assert -no-bounds-check` ("no checks").

## Results

| benchmark | Rust | Odin `-o:speed` | Odin / Rust | Odin no checks | no checks / Rust |
|---|---|---|---|---|---|
| VarInt decode (1M) | 320.45 M ops/s | 325.11 M ops/s | 1.01x | 251.10 M ops/s | 0.78x |
| VarInt encode (1M) | 285.86 M ops/s | 239.66 M ops/s | 0.84x | 201.40 M ops/s | 0.70x |
| frame split, `make` + `delete` per body (200k) | 60.19 M ops/s | 27.32 M ops/s | **0.45x** | 22.37 M ops/s | 0.37x |
| frame split, arena per body | 60.19 M ops/s | 43.46 M ops/s | 0.72x | 36.06 M ops/s | 0.60x |
| frame split, non-zeroed malloc | 60.19 M ops/s | 26.43 M ops/s | 0.44x | 26.95 M ops/s | 0.45x |
| position decode (200k) | 283.95 M ops/s | 283.91 M ops/s | 1.00x | 287.56 M ops/s | 1.01x |
| build frames, straight port (200k) | 86.00 M ops/s | 26.74 M ops/s | **0.31x** | 22.34 M ops/s | 0.26x |
| build frames, no per-frame allocation | 86.00 M ops/s | 94.24 M ops/s | 1.10x | 86.09 M ops/s | 1.00x |
| 2000 connection state machines x 100 rounds | 796.50 M ops/s | 747.11 M ops/s | 0.94x | 623.23 M ops/s | 0.78x |
| zlib compress 1 MiB, level 6 (system libz) | 107.9 MB/s | 102.5 MB/s | 0.95x | 96.6 MB/s | 0.89x |
| zlib decompress 1 MiB | 801.4 MB/s | 803.8 MB/s | 1.00x | 779.4 MB/s | 0.97x |
| AES-CFB8 encrypt, hand-written AES-NI, bounds checks on | 70.2 MB/s | 35.1 MB/s | **0.50x** | 74.5 MB/s | 1.06x |
| AES-CFB8 decrypt, hand-written AES-NI, bounds checks on | 622.4 MB/s | 88.0 MB/s | **0.14x** | 672.8 MB/s | 1.08x |
| AES-CFB8 encrypt, AES-NI, `#no_bounds_check` on the two procs | 70.2 MB/s | 73.6 MB/s | 1.05x | 74.0 MB/s | 1.05x |
| AES-CFB8 decrypt, AES-NI, `#no_bounds_check` on the two procs | 622.4 MB/s | 648.6 MB/s | 1.04x | 642.3 MB/s | 1.03x |
| AES-CFB8 encrypt, OpenSSL EVP via FFI | 70.2 MB/s | 60.7 MB/s | 0.87x | 60.2 MB/s | 0.86x |
| AES-CFB8 decrypt, OpenSSL EVP via FFI | 622.4 MB/s | 65.4 MB/s | 0.11x | 68.0 MB/s | 0.11x |

"Rust" in the AES rows is the Rust hand-written AES-NI (window trick; decrypt keeps four blocks in flight); it is the reference for both hand-written and EVP rows.

What the table says:

* **Parsing, decoding, state machines: parity.** VarInt decode, position decode (big-endian doubles and floats through `byte_swap`), and the connection state machine are within noise of Rust.
  zlib is the same C library in both, so it matches.
* **Allocation is where a straight port loses.** The `make`-per-frame versions run at 0.3x to 0.45x. Non-zeroing the memory did not help (0.44x), so the cost is in Odin's allocator path rather
  than in zeroing (`make` zero-initializes by default; the default allocator is libc `malloc`, `base/runtime/heap_allocator_unix.odin`); I did not investigate further, and
  Rust's allocator-plus-optimizer may also have removed work I intended to measure. Written the way Odin encourages (an arena reset every 1,024 frames, or a stack buffer and a reserved
  output), it reaches 0.72x on frame split and **1.10x** on frame building.
* **Bounds checks cost almost nothing in parsing loops but ruin a tight crypto loop.** The checked-versus-unchecked differences for VarInt, framing and position decode are inside the noise.
  The hand-written AES-NI loops are the exception: with checks they were **2.1x (encrypt) and 7.6x (decrypt) slower**, because the checks sit in the loop that interleaves four AES blocks.
  Putting `#no_bounds_check` on the two loop procedures was not enough (decrypt still 109 MB/s in a first run); it also had to go on the inlined helper they call. With both marked, encrypt and decrypt are
  at **1.05x and 1.04x of Rust**, with checks left on everywhere else. So Odin has a surgical opt-out, but it is easy to apply to the wrong scope.
* **AES-CFB8 has no Odin implementation**, so the choice is the hand-written AES-NI above (a few dozen lines, verified byte for byte against `openssl enc -aes-128-cfb8`) or OpenSSL through FFI.
  OpenSSL's CFB8 decrypt (65 MB/s) is about 10x slower than the four-way AES-NI decrypt (649 MB/s) because it does not interleave. Encrypt is serial either way (about 60 to 74 MB/s). In a gateway, outbound encrypt is the
  bottleneck and is the same in both.
* **Players per core** with the same optimistic, gateway-work-only assumptions as `docs/TCL-EVALUATION.md` (5 inbound packets, 25 outbound frames of about 1000 B, 150 B decrypted per player-tick, 50 ms tick):
  Odin (arena split, allocation-free build, hand AES-NI with the opt-out) about 14.2 us per player-tick, **about 3,500 players per core at 100% busy (2,500 at 70%)**; Rust with the same table about 14.9 us, 3,360 (2,350 at 70%).
  Ignores syscalls, libpq, scheduling and allocator pressure from many connections, so real numbers are lower for both.

## Socket check: `core:nbio` echo server with 5,000 clients

`tests/bench/odin/echo/echo.odin`: one thread, `nbio.listen_tcp`, `accept_poly`, `recv_poly`/`send_poly` per connection (io_uring underneath). The Python load generator
(`tests/prototype/pl_gateway_load.py`) opens 5,000 connections and sends 5 frames of 31 bytes per connection every 50 ms for 10 s, then compares the echoed byte count.

| clients | result |
|---|---|
| 1,000 | all 15,500,000 bytes echoed back, peak 1,000 connections |
| 5,000 | **all 155,000,000 bytes echoed back**, peak 5,000 connections, one thread, 357k frames/s averaged over a 14 s window including connection ramp-up |

Limits of this test: the Python client (about 500k frames/s offered at 5,000 connections) shares the 4 cores and was the pacing side, so this is not a server ceiling; there is no latency measurement, no
encryption, no framing and no database; the server's CPU use was not separated from the client's (the shell's `times` summed both: about 2.8 s user and 11.9 s system for the 5,000-client run); and there is no Rust server
number to compare against. It shows that the nbio layer works and holds 5,000 sockets on one thread **where `io_uring` is available**, which was the case here (kernel 6.18).

## Facts about the language and library (checked against the Odin source tree at the tag above unless a URL is given)

| Topic | What is there |
|---|---|
| Networking | `core:net`: TCP/UDP sockets (`listen_tcp`, `accept_tcp`, `set_blocking`, socket options including `Reuse_Port`), blocking by default. `core:nbio`: an event-loop layer, one loop per thread, `accept`, `recv`, `send`, `dial`, `timeout`, `poll`, with optional per-operation timeouts. |
| Async I/O backend | On Linux `core:nbio` is built only on `io_uring` (`core/nbio/impl_linux.odin`, `core/sys/linux/uring`); there is no epoll fallback in `core:nbio` or `core:net` (epoll appears only as raw syscall bindings in `core:sys/linux`). The docs note `acquire_thread_event_loop` may return `.Unsupported` if the syscalls are unavailable, that timeouts are "intentionally slightly inaccurate", and that `poll` is a compatibility aid ([package nbio](https://pkg.odin-lang.org/core/nbio)). **Docker's default seccomp profile blocks `io_uring_setup`, `io_uring_enter` and `io_uring_register`** ([Docker seccomp docs](https://docs.docker.com/engine/security/seccomp/)), so a containerised gateway needs a custom profile. |
| Crypto | `core:crypto` has AES as ECB, CTR and GCM only (`core/crypto/aes`), and no CFB mode anywhere in `core/crypto` (searched). SHA-1 and MD5 are in `core:crypto/legacy` (needed for Minecraft's Mojang digest). `core:crypto/rsa` has OAEP, PSS and PKCS#1 signatures and key generation, plus a TLS pre-master-secret decrypt, but no general PKCS#1 v1.5 decrypt; Minecraft's login uses that padding, so it needs OpenSSL by FFI (I did not check whether the TLS variant could be adapted). The simd package exposes `_mm_aesenc_si128` and friends (`core/simd/x86/aes.odin`), which is what the hand-written AES-NI here uses. |
| Compression | `core:compress/zlib` can only **inflate** (no deflate in the file). `vendor:zlib` binds the system libz including `deflate`, `compress2` and `uncompress`. |
| HTTP, Postgres | `vendor:curl` exists (for the Mojang session server call). There is **no libpq binding** and no OpenSSL binding in `vendor`; both would be written by hand with `foreign import`. |
| Threads | `core:thread` (including a thread pool) and `core:sync` (futexes, channels). |
| Memory | Manual. Allocators are values carried in an implicit `context` (arenas, stacks, pools in `core:mem`); `context.allocator` defaults to libc `malloc` on Linux and `context.temp_allocator` is a built-in arena. The FAQ states Odin has no ownership semantics and the programmer can do unsafe things; bounds checking can be toggled per statement ([FAQ](https://odin-lang.org/docs/faq/)). |
| Safety tooling | `-sanitize:address`, `-sanitize:memory`, `-sanitize:thread` exist (`odin help build`). I found **no fuzzing option** in the compiler's build flags, and there is no borrow checker or lifetime analysis. Use-after-free, double free, and data races are the programmer's responsibility; the checks Odin does give by default are bounds and type assertions. |
| Stability | Releases are monthly tags (`dev-2026-09`, `dev-2026-10`). The FAQ says the language is "pretty much done" but the compiler, toolchain and core library are still in development, there is no 1.0 and no official roadmap, and there will never be an official package manager (vendoring is recommended) ([FAQ](https://odin-lang.org/docs/faq/)). |
| Size | `core` has 1,288 `.odin` files; `vendor` has 34 packages, mostly graphics, audio, windowing and bindings (box2d, raylib, SDL, Vulkan, curl, zlib, lua...). |
| Production users | JangaFX (EmberGen and other real-time simulation tools) is the commercial user reported ([Wikipedia](https://en.wikipedia.org/wiki/Odin_(programming_language)), [a JangaFX engineer's review](https://graphitemaster.github.io/odin_review)). I found no named user running a network server at scale. A forum thread collects commercial users ([Odin forum](https://forum.odin-lang.org/t/featuring-your-commercial-odin-business-application-game/1755)). |

## Opinion

**Where Odin fits.** The speed is real, so it is a good fit for the parts that handle data we produce ourselves: chunk and section packing, the compression fragment assembler,
the world importer and exporter, load generators and benchmark tools, and any inner loop where the author controls both sides. The code is short and readable, the arena idiom suits per-tick work (reset the arena once per
tick), the `-sanitize:address` mode exists for testing, and the 5,000-socket echo test worked on the first attempt.

**Where it is risky.** A gateway that parses bytes from thousands of hostile clients is exactly the case where memory safety matters most, and Odin offers bounds checks (which we saw are cheap in parsers, and which a perf-minded
author will be tempted to disable, as the AES case shows) but nothing for lifetimes or races. Per-connection state with manual allocation and callbacks is where use-after-free bugs appear. Around that, the practical costs add up:
`nbio` needs `io_uring` (blocked in Docker's default profile and in many hardened hosts) with no fallback, so we would write an epoll loop ourselves for the safe default; libpq, OpenSSL (RSA PKCS#1 v1.5, EVP) and the Postgres wire batching would all be hand-written FFI;
there is no CFB8; there is no fuzzing support; the standard library is still moving; and there is no server-side production track record to lean on. Each of these is solvable alone, but together they mean most of the gateway would be built from scratch.

**Ranking for this project** (the order is my judgement; only Odin and Rust were measured by me, and Go's numbers are in a separate evaluation if it has finished):

1. **Rust**: same speed in every row where both were measured, memory safe, mature async runtime, crypto, zlib and Postgres crates, fuzzing tools.
2. **Go**: memory safe and mature for servers; the open question is whether the garbage collector disturbs a 20 TPS loop (see `docs/GO-EVALUATION.md` if present). Not measured here.
3. **Ada/SPARK**: memory safe, with proofs possible for the parser, but thin ecosystem and the bindings would be hand-written. Not measured here.
4. **Odin**: fastest to write of the unsafe languages and measured at parity, but see the risks above.
5. **Zig**: I would place it with Odin (similar trade: fast, manual memory, young ecosystem), with better C interop and a larger community, but I did not measure it.
6. **C**: the most libraries and the most mature tooling, and the least safety for a hostile-input parser.

**Recommendation.** Do not choose Odin for the gateway's network and parsing path. Use it, if at all, for offline tools and benchmarked inner loops. The measurements that would change this opinion: a safe-by-default
resource model for connections (not available), an epoll fallback and libpq/OpenSSL bindings in the standard distribution, or a fuzzing story.

## Not measured, and caveats

* No Rust or Go socket server for the 5,000-client comparison; the echo test has no encryption or database.
* One machine, shared with other benchmark processes; noise about 25%. Rust and Odin code are straightforward implementations, not tuned by experts.
* The cause of the 0.45x frame split with `make`/`delete` was not isolated.
* The players-per-core numbers are estimates from microbenchmarks.
* Zig, Ada and C were ranked from general knowledge and the other evaluations, not benchmarked by this fork.
