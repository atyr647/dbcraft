# What it would take to get Tcl + tcl-aot to a viable dbcraft gateway

Follow-up to `TCL-EVALUATION.md`.  Question: what would it take to get there, measured, not guessed.
Code, data generators and scripts: `tests/bench/tclpath/` (`run_all.sh` reproduces everything below in about 10 minutes).
tcl-aot (`/home/user/atyr647/tcl-aot`) was **not modified**: experiments ran on a patched copy; the patch is `tests/bench/tclpath/patches/binary-format-pure.patch`.

Machine: 4 cores, shared with other jobs for the whole session (load average 1.2 to 5.5 while measuring; every wall-time number is best of 5 and still carries
10% to 25% noise; instruction counts do not).  Tcl 8.6.14 static build, OpenSSL 3.0.13, valgrind callgrind.

## Short answer

* **tcl-aot is not what stands between this gateway and the target.** Once the database decodes packets (the dbcraft design), the gateway does framing, AES-CFB8, socket
  I/O and batching.  Compiled Tcl code speeds up the Tcl loop around those by 15% to 25% (`tclonly` row below) and the work is in the native core and the event loop.
* **A small native core plus an epoll notifier gets Tcl to about 1,500 to 1,800 players per core on real loopback sockets today** (measured; 300 lines of C, no Tcl patch), up from
  about 1 with pure-Tcl AES and a hard cap of about 1,000 connections per process.  With native batched socket I/O (not built; estimated 400 to 600 more lines of C) the estimate is
  about 3,000 per core.  A Rust gateway built from the same native parts would land in the same range, because both are bound by AES-NI and the kernel.
* **So it can be made viable, but at that point most of the gateway is C and Tcl is configuration and database glue.** Whether that is worth doing instead of Rust is a
  preference, not a performance question (see the end).

## 1. Amdahl: how much of the time can tcl-aot touch

Method (`amdahl/run_callgrind.sh`, `amdahl/classify.py`): callgrind instruction counts for one call of each proc, interpreter alone vs tcl-aot module, startup removed
function by function, then every function put in one of four classes: **executor** (bytecode executor, variable lookup, command dispatch: what compiling removes),
**library** (`binary scan`, `binary format`, list and string C code), **objects** (Tcl_Obj alloc/free, thread-data lookups), **compiled** (generated code and `tbc_*` helpers).
Inputs: 20,000 frames (640 KB) / 100,000 VarInts / 20,000 positions.

| proc | interpreter (M instr) | executor | library | objects | tcl-aot (M instr) | measured speedup | bound if library+objects stay as they are |
|---|---|---|---|---|---|---|---|
| `vi_decode_all` | 617.8 | 460.9 | 72.3 | 84.6 | 41.5 | **14.9x** | (3.9x: not a bound here, typed code also removes the list objects) |
| `split_scan` (`binary scan @off`) | 308.6 | 142.0 | 96.2 | 70.5 | 293.8 | 1.05x | 1.85x |
| `split_index` (`scan cu*` + lindex) | 239.4 | 88.4 | 120.6 | 30.4 | 61.1 | **3.92x** | (1.59x: same remark) |
| `pos_decode_loop` (`scan QQQRRcu`) | 149.7 | 80.3 | 47.7 | 21.7 | 125.3 | 1.19x | 2.16x |
| `build_frames` (`binary format`) | 351.5 | 147.7 | 139.8 | 64.0 | 365.3 | **0.96x** | 1.72x |

Reading it:

* Where a proc is mostly executor work and tcl-aot can type it (`vi_decode_all`, `split_index`), the gain is large, 4x to 15x in instructions.
* Where the proc is built around `binary scan` forms or `binary format`, tcl-aot hands over to boxed code at every call and gains nothing or loses (0.96x).
  Even with perfect compilation of everything around the library calls, the bound is only 1.7x to 2.2x, because 40% to 60% of the instructions are Tcl's own C code.
* **Correction to `TCL-EVALUATION.md`:** it measured `split_index` at 1.03x on one 8.4 MB buffer.  That builds an 8.4 million element list and is memory-bound.
  At the sizes a gateway sees (a read of 160 B to 1 KB per connection per tick), wall time is:

| split at gateway sizes (`amdahl/small_split.tcl`) | interpreter | tcl-aot | native `dbc::split` |
|---|---|---|---|
| `split_index`, 5 frames (160 B) | 6.64 us | **2.68 us** (2.5x) | 0.78 us |
| `split_index`, 30 frames (960 B) | 25.2 us | **11.2 us** (2.3x) | 2.46 us (30 frames, 1020 B) |
| `split_scan`, 5 frames | 6.35 us | 7.52 us (0.84x) | |
| `split_scan`, 30 frames | 35.0 us | 38.8 us (0.90x) | |

### An artefact to know about (found while measuring)

tcl-aot's default **lazy attach** puts a one-shot `trace add execution ... enter ::tbc::lazy` on every proc.  On the proc's first call Tcl's trace code turns the whole command into a
string, **arguments included**: calling `split_index` once with a 640 KB buffer cost about 100 M extra instructions (a one-time 30 ms, and the first run of my callgrind
numbers was wrong because of it).  Gateway procs should be attached eagerly (`TBC_EAGER=1` or `tbc::attach eager`); all the compiled numbers above use eager.

### tcl-aot gaps, and the cheapest one tried

1. **`binary format` is not in `tbcPureBuiltins`** (`src/translate.tcl:82`; the bytecode names it `tcl::binary::format`).  One word added in a copy:

   | | interpreter | tcl-aot stock | tcl-aot + patch |
   |---|---|---|---|
   | `build_frames` (M instr) | 351.5 | 365.3 (0.96x) | **192.2 (1.83x)** |
   | `vi_encode_all` (M instr) | 347.0 | 175.6 (1.98x) | 175.4 (no change: its cost is the per-byte `lappend`) |

   Safety: tcl-aot's own `tests/run.sh quick` passes on the patched copy (16,980 calls compared, 0 mismatches, lazy and eager) **but that suite has no `binary format` in `tests/procs.tcl`**,
   so it proves nothing about this change.  I wrote a differential test for it (`difftest/`: results, return codes, `errorCode`, `errorInfo` of bad formats and missing arguments,
   `c` wrap-around, a list argument, a local variable alongside, an execution trace on the command, `info level`, a namespace proc, and the command renamed and replaced).  Stock and
   patched translators both give output identical to the interpreter, 18 lines, 10 procs running compiled.  Not exhaustive; the cases should go into tcl-aot's suite.
2. **Inlined `binary scan` covers only `c s S i I` (+`u`) with `*`** (`tbcScanFmt`, line 85).  `Q`, `R` and single-value or `@offset` scans hand over at each call.  I did not extend it
   (it needs runtime support in `include/tbc_hook.h`, not a one-line change).  It matters only if packets are decoded in Tcl, which the database-decodes design avoids.
3. **Procs that `yield` run the interpreter's version** (documented).  One coroutine per connection is the natural Tcl design, so a design with per-connection coroutines gets no compiled code.
4. Lazy-attach first-call cost above.
5. Pinned to Tcl 8.6.14 static builds: no Tcl 9 notifier, no `-reuseport`.

## 2. Tcl as glue over a small native core

`native/dbcnative.c` (about 280 lines with the AES-NI part), statically linked into a Tcl shell (`native/dbcshell.c`):

| command | what it does |
|---|---|
| `dbc::cipher` / `dbc::encrypt` / `dbc::decrypt` | AES-128-CFB8, stateful, OpenSSL EVP (iv defaults to the key, as in Minecraft's login) |
| `dbc::nicipher` / `nienc` / `nidec` / `nienc_batch` | the same stream with AES-NI intrinsics: decrypt 8 positions at once; encrypt up to 8 connections' streams in lockstep |
| `dbc::split` | whole `[VarInt length][VarInt id][body]` frames from a byte buffer: `{consumed id body id body ...}` |
| `dbc::tick` | decrypt + split + encrypt in one call |
| `dbc::nop` | measures the cost of calling a C command |

Correctness: EVP output matches `openssl enc -aes-128-cfb8` on 64 KiB; the AES-NI implementation matches EVP for lengths 1 to 3,000 with state carried over three chunks per stream and
for ragged lanes in a batch; the splitter matches a hand-built buffer including a trailing partial frame (`native/crypto_rates.tcl`, `native/run_tick.tcl`).

### AES-128-CFB8 rates (1 KiB messages, called from Tcl)

| | MB/s | us per KiB |
|---|---|---|
| OpenSSL EVP encrypt | 48.8 | 21.0 |
| OpenSSL EVP decrypt | 52.3 | 19.6 |
| AES-NI encrypt, one stream (serial: each byte needs the previous ciphertext byte) | 69.9 | 14.7 |
| AES-NI decrypt, 8 positions in flight | **171.0** | 6.0 |
| AES-NI encrypt, 2 / 4 / 8 connections in lockstep | 60.3 / 110.5 / **138.0** | 17.0 / 9.3 / **7.4** |

CFB8 encryption cannot be parallelised inside one stream, but a server has thousands of streams.  Interleaving 8 of them is 2.8x the OpenSSL path and 2.4x the Rust serial
AES-NI figure of `TCL-EVALUATION.md` (57.8 MB/s).  This is language independent: a Rust gateway should do the same.  (Rust's 515 MB/s decrypt vs 171 MB/s here is my loop shape and the
shared loaded machine; I did not tune it.)

### The per-tick pattern: 2,000 connections, each tick 5 inbound frames (170 B encrypted) and one 1 KiB outbound blob

Per connection: decrypt, split, add the frames to a COPY-text batch (`binary encode hex`), encrypt, `puts` to `/dev/null` (a real write syscall).  No sockets, no database.

| variant | ms per tick (interpreter) | ms per tick (tcl-aot) | players per core at 100% of a 50 ms tick |
|---|---|---|---|
| Tcl side only (no crypto, no split call) | 5.15 | 3.81 | about 19,000 to 26,000 |
| EVP, separate calls (decrypt, split, encrypt) | 47.1 | 47.0 | about 2,100 |
| EVP, one fused `dbc::tick` call | 52.5 | 44.6 | about 1,900 to 2,200 |
| **AES-NI, decrypt per connection + one lockstep batch encrypt per tick** | **21.1** | **20.3** | **about 4,700 to 4,900** |

* The cost of calling a C command from Tcl: 38 to 78 ns per call (empty loop 0.7 to 22 ns), so call overhead is irrelevant at 10 calls per player per tick.
* Fusing calls does not help (separate 47.1 vs fused 52.5 are within noise).  AES dominates; with EVP it is about 45 of the 50 ms.
* The Tcl-side work (loop, list handling, hex encoding of five bodies, one write syscall) is 1.9 to 2.6 us per connection-tick, 3.8 to 5.2 ms per tick of 2,000.  tcl-aot makes that 15% to 25% cheaper.
* The Rust figure in `TCL-EVALUATION.md` (about 2,800 per core) used serial AES encryption.  With lockstep encryption Rust's crypto cost falls the same way, so the comparison
  that holds is: crypto about 8.4 us per connection-tick in both; Tcl's own work about 2 us, Rust's about 0.5 us.  About 15% apart in compute.  I did not run the Rust variant.

## 3. The 1,024 descriptor limit

Tcl 8.6.14's Unix notifier (`unix/tclUnixNotfy.c`, 1,496 lines, select()-based with a notifier thread) aborts the process on any fd at or above `FD_SETSIZE`.  Confirmed on the
gateway-shaped server below: **2,000 connections crash it** (`*** bit out of range 0 - FD_SETSIZE on fd_set ***: terminated`).

* **Backport an epoll notifier to 8.6.14, as a patch to Tcl core:** not needed.  8.6 has a documented embedding hook, `Tcl_SetNotifier()`, which replaces the whole notifier from the
  application.  Tcl 9.0.1's own `unix/tclEpollNotfy.c` is 844 lines because it also runs a notifier thread for Tcl threads; a single-threaded version is `epoll/epollnotify.c`,
  **about 85 lines**, installed from `main()` before `Tcl_Main` (`DBC_NOTIFIER=epoll` in my shell).  Level-triggered, one epoll set, an eventfd for `Tcl_AlertNotifier`.  Effort: one afternoon,
  done.  Limits: single-threaded Tcl only; not stress-tested beyond this benchmark (`fileevent`, `after`, `vwait`, channel close all worked in it).
* **Several processes on one port:** Tcl 8.6 `socket -server` has no `SO_REUSEPORT`.  Cheapest options: a native listener in the C core (accept loop, `SO_REUSEPORT`, hand each fd to Tcl with
  `Tcl_MakeTcpClientChannel`), or one port per process behind the kernel/hardware balancer.  Estimated at 1 to 2 days with the native I/O loop in section 4; not built.

### Measured (`epoll/run_sockets.sh`, `gwserver.tcl`, `loadgen.c`)

Server: Tcl `socket -server`, one `fileevent readable` per connection (read, AES-NI decrypt, `dbc::split`, hex-encode rows into a COPY batch); every 50 ms one lockstep encrypt of a 1 KiB blob per
connection and a `puts` to each socket.  Client: one C process over loopback, each connection sends a 170 B encrypted batch every 50 ms.  10 s windows.

| notifier | connections | TPS reached | server CPU (user / kernel) | CPU per connection per 50 ms tick |
|---|---|---|---|---|
| select | 500 | 19.7 | 60% of a core | 59.7 us |
| epoll | 500 | 19.6 | 29% | 28.7 us |
| select | 700 | 19.4 | 66% (41 / 25) | 47.3 us |
| epoll | 700 | 19.4 | 43% (33 / 10) | 30.8 us |
| epoll | 900 | 19.1 | 51% | 28.1 us |
| select | 2,000 | **crashes** (FD_SETSIZE) | | |
| epoll | 2,000 | 13.4 | 78% | not meaningful (see below) |
| epoll | 5,000 | 3.8 | 76% | not meaningful (see below) |

* **5,000 connections in one Tcl process work** (all accepted, 336,000 frames per second handled, no abort).
* **Do not read the 2,000 and 5,000 rows as capacity.**  The load generator is one thread on a machine already shared with other jobs; it could not offer the full rate at those sizes (its
  writes failed with EAGAIN, the server's CPU stayed below 80% of a core and its ticks ran late).  They show the process holds the connections, not how many it can serve.
* The reliable figure is CPU per connection-tick at 500 to 900 connections: **about 28 to 33 us with epoll, 45 to 60 us with select**.  About 75% is user time.  That is
  **1,500 to 1,800 players per core at 100% busy (about 1,100 to 1,300 at 70%)**.  Of the 28 to 33 us, 8.4 us is crypto; the rest is Tcl's channel layer and event dispatch
  (a Tcl callback per readable socket, `read`, `puts`) plus the kernel.

## 4. Work list to reach the Rust-class number, in order

Players per core means one core, 20 TPS, 100% busy / about 70% busy, gateway work only (the database is separate).  "Measured" rows ran here; "estimated" rows did not.

| step | what | effort | players/core | status |
|---|---|---|---|---|
| 0 | stock Tcl 8.6 + tcllib AES, select notifier | | about 1; capped at about 1,000 connections | measured (`TCL-EVALUATION.md`) |
| 1 | C extension: AES-CFB8 (EVP) and `dbc::split` | about 150 lines C | about 2,000 compute-only | measured; with select notifier real sockets are limited to 1,000 connections |
| 2 | AES-NI: pipelined decrypt, lockstep multi-connection encrypt | about 130 lines C | about 4,800 compute-only (2.3x step 1) | measured |
| 3 | epoll notifier through `Tcl_SetNotifier` | about 85 lines C | **1,500 to 1,800 on real loopback sockets (1,100 to 1,300 at 70%)**; 5,000 connections held | measured |
| 4 | native batched socket I/O: C epoll accept/read/write loop with `SO_REUSEPORT`, per-connection buffers, one native call per tick; frames appended to a native COPY-binary buffer; one libpq pipeline/`COPY` call per tick; Tcl runs O(1) per tick | 400 to 600 lines C | about 3,000 (about 2,200 at 70%) | **estimated**: crypto 8.4 us + kernel about 7 us (from the user/kernel split above) + about 1 us |
| 5 | one process per core | trivial after step 4 | about 4 x step 4 on this box, bounded by the database | estimated |
| (tcl-aot) | `binary format` pure builtin; add its cases to the test suite; eager attach | 1 word + tests | speeds the Tcl loop 15% to 25%; irrelevant at step 4 | measured as above |

Step 4 is where the gateway stops being Tcl in any meaningful sense: the per-event Tcl code (about 12 to 15 us of the 28 to 33 us per connection-tick) disappears into C, and
what Tcl keeps is startup, configuration, login orchestration and the database session.  tcl-aot has nothing left to compile there.

## Opinion

* **Is it worth getting there?**  As a performance route, no.  Every step that matters (AES-NI interleaving, epoll, batched I/O, COPY building) is native code that Rust would use too, and
  at the end both are bound by AES-NI and the kernel, about 3,000 players per core.  Rust gets there with one language, threads, and no pin to Tcl 8.6.14 static builds; the Tcl route needs
  the notifier hook, a native I/O loop and a libpq binding, and then runs the Tcl interpreter beside them.
* **When it is still the right call:** if you want the gateway to be a small Tcl program that you can read and change at runtime (login rules, routing, rate limits, logging), with a roughly
  1,000-line C core underneath, and about 1,500 players per core is enough for the first milestones: it is viable today at step 3.  Moving to step 4 later does not change the Tcl side.
* **What I would do for tcl-aot itself, independent of this project:** merge the `binary format` change with tests; make lazy attach avoid stringifying arguments of the first call
  (or document `TBC_EAGER`); consider inlining the other `binary scan` forms.  These help any program that parses or builds binary data in Tcl.

## Caveats

Single machine, shared with other jobs; wall times are best of 5 with 10% to 25% noise; the socket test used one single-threaded load generator and a closed loopback; the 2,000 and 5,000
connection rows show feasibility only; steps 4 and 5 are estimates; the Rust variant with lockstep AES was not run; the epoll notifier is a prototype (single-threaded Tcl only, no
exceptional-condition handling beyond `EPOLLPRI`); `difftest/` is not exhaustive; the AES-NI code was checked against OpenSSL, not audited.

## Commands

```
tests/bench/tclpath/run_all.sh            # everything, about 10 minutes
# individual pieces
amdahl/run_callgrind.sh ; python3 amdahl/classify.py out eager         # section 1 (set TBC_EAGER=1 TAG=eager)
native/build.sh ; out/dbcshell native/crypto_rates.tcl                 # section 2
TBC_EAGER=1 out/dbcshell native/run_tick.tcl ; TBC_EAGER=1 COMPILED=1 out/tkshell native/run_tick.tcl
epoll/run_sockets.sh epoll 700 10                                      # section 3 (select | epoll, connections, seconds)
(cd out/aotcopy && BUILD=/home/user/atyr647/tcl-aot/build tests/run.sh quick)   # tcl-aot's own suite on the patched copy, 4 minutes
```
