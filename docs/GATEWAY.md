# The gateway

The gateway is the byte pipe between Minecraft clients and the database.  Everything that is game, protocol or rule lives in SQL; the gateway does the five things SQL
cannot: **sockets**, **AES-128-CFB8**, **RSA decryption of the shared secret**, **the HTTPS check with Mojang's session server**, and **inflating inbound compressed frames**.
It holds no game state and parses no packet except the one login frame it intercepts in online mode.

## Status: what exists and what was verified

| Piece | Where | State |
|---|---|---|
| SQL half: control channel, encryption request, verdicts, profile properties | `sql/600_gateway.sql`, `sql/601_online_login.sql` | **tested**: `tests/sql/600_gateway_online.sql` (46 checks; the control stamp lives in the side table `net.conn_ctl`, so `net.conn` rows stay comparable between runs); override and inlining guards green on a clean migration |
| Reference implementation of the whole contract, as database code | `sql/optional/dev_gateway_online.sql` (`net.run_online`) | **tested end to end** with real RSA and AES-CFB8 (OpenSSL via Python `cryptography`), a stub session server and an encrypting client: `tests/gateway/online_test.py`, 27 checks, with compression off and at threshold 256 |
| Std-only core: frame splitting, inflate, AES-128-CFB8, SHA-1, server hash | `gateway/core/` | **tested**: 22 unit tests + 216 real-zlib inflate vectors + adacraft's corpus + randomised stress + AES-CFB8 against the `openssl` binary (40 random rounds, both directions) |
| The gateway proper (zero crates: std + libpq, libcrypto, libcurl, libc through hand-written FFI) | `gateway/src/`, `gateway/build.sh` | **built and run.** Plain `rustc` and `cargo build --release --offline` (path-only manifest) both work; nothing was denied. 75 unit tests pass (core 30, gateway 45; includes parser, config, limiter, write-queue backpressure, FFI round trips, randomised stress). Offline e2e comparisons pass (`tests/gateway/run_e2e_rust.sh`). Online mode: 27 of 27 checks pass at compression off and at threshold 256 (`tests/gateway/run_online_rust.sh`), also with the gateway under valgrind (0 errors, 0 bytes definitely lost). A **real vanilla 26.3 client**, offline, joined through it, walked (4.3 blocks/s), broke a block and chatted, and stayed connected for a 5-minute soak with 0 gateway errors and 0 protocol errors in the client log. |
| Real Mojang session server | | **never called** (tests use a local stub) |
| A real vanilla client in online mode | | **untested** (it needs a Mojang account) |
| Rust gateway performance | | **measured at 20 and 500 clients and at 2,000 (where the database, not the gateway, gave out); 5,000 not run**: see "Measured: the Rust gateway" |

## Division of labour

```
  client ──TCP──▶ gateway ──▶ one transaction per tick ──▶ PostgreSQL (all logic)
           ◀──────  bytes (framed, compressed, encrypted by the gateway) ◀──┘
```

Per tick (drift-free 20 Hz schedule, period from `net.setting.tick_ms`), all events of the tick go to the database in ONE transaction, in this order:

1. accepted sockets → `net.on_connect(id, ip)`
2. all inbound frames → ONE binary `COPY net.inbox (conn_id, payload)` (payload = the frame without its length prefix, inflated if the connection's compression is on)
3. key responses seen this tick → `net.auth_begun(ids)`
4. session verdicts that arrived → `insert into net.auth_result`
5. `net.apply_auth_results()` (online mode: finishes logins before the game runs)
6. the server tick (`mc.server_tick()` or `mc.server_tick_batched()`)
7. sockets the client closed → `net.on_disconnect(id)`
8. `net.drain_outbox()` → per connection: the bytes to write, and whether to close afterwards
9. `net.gateway_ctl(last_seen)` → control rows (below)

**Two exceptions to "all events of the tick in ONE transaction, in this order"** (`docs/PERF-IDLE.md`; both can be turned off, `lean_ticks = false` / `urgent_chat = false`):

* a **lean tick** (nothing to give the database: no accepted socket, no inbound frame, no key response, no verdict, no closed socket) is ONE prepared autocommit statement, `select mc.server_tick(), net.gateway_pending(last_seen)` (the probe runs after the tick, in its transaction); steps 8 and 9 happen only when the probe reports bytes in the
  outbox, a closing connection, control rows or (bit 4) chunk requests for the generator threads, and the statistics row is written every 20th lean tick (carrying all of them).  On a quiet server the tick itself skips its 17 probes when no transaction has completed since the last quiet one (sql/800, docs/PERF-IDLE2.md).  `client_tick_end` frames of a play connection with fewer than two position packets in the tick are not given to the database at all (`skip_tick_end`; the database ignores them, `sql/800`), which is what lets an idle server's ticks be lean;
* the **urgent chat lane**: when a serverbound `chat` frame of a play connection arrives and the next tick is far enough away, the gateway calls `net.urgent_chat(conns, payloads)` and `net.drain_outbox()` in one transaction at once.  The tick's own handling of chat (`mc.apply_chat`, the same drain) is what runs, so the bytes are identical; commands and
  chat behind a command, or behind another kind of frame of the same connection, are not taken and wait for the tick, which keeps vanilla's arrival order.

**Position frames that pile up** (`coalesce_moves`, default on; `docs/PERF-CAPACITY.md`).  A client sends one position packet and one `client_tick_end` every 50 ms whatever the server does, so a
tick that takes 100 ms is handed two pairs per walking client, and one that takes 800 ms sixteen.  Several position packets of one play connection in one tick, each two of them separated by a
`client_tick_end`, are given to the database as the last one only (`coalesce_positions`): the database applies the last position and the flags of the last packet of a connection anyway, and the
only things an earlier one can do are the three kicks (a length other than 25 or 33 bytes, a NaN or infinite number, two positions in a row), so a connection is touched only when none of them
can fire (every number finite by its exponent bits, exact lengths, one kind of position packet, no rotation-only or status-only frame, a `client_tick_end` between every two positions) and is
left to the database otherwise.  `tests/sql/982` proves on the database side that `[P1 TE P2 TE P3]`, `[TE TE P3]` and `[P3]` leave the same rows, the same output bytes and the same kicks,
with the vanilla tracker and with the classic broadcast; the gateway's unit tests cover the selection.  The stop line of the log counts the merged frames.

After the commit: the drained bytes are queued to each socket's writer (encrypted there when the connection is), `close` rows close the socket after its last bytes, control rows
are applied.  If the transaction fails it is rolled back and that tick's inbound frames are dropped (a poison frame must not stall the server forever); `net.gateway_stats.errors` counts it.

## The contract (SQL), and one change from the first sketch

| Object | Role |
|---|---|
| `net.inbox`, `net.drain_outbox()`, `net.on_connect/on_disconnect` | unchanged from `docs/NET.md` |
| `net.gateway_ctl(after_seq)` | **new.** Rows of `net.conn` that changed since the gateway last asked: `compression` (inflate inbound frames of that connection from now on), `state` (`play` lifts the small pre-login frame limit), `await_key` with `name` and the 4-byte `verify_token` (online mode). Stamped by a trigger on `state`, `compression`, `await_key` only, so the per-tick keep-alive updates of `net.conn` stay in-place updates. |
| `net.server_key` | the gateway's RSA public key (X.509 DER, 1024 bit like vanilla), published at start |
| `net.auth_begun(ids)` | the gateway intercepted a key response: the connection is now `auth_pending` |
| `net.auth_result` | the gateway's verdicts: `ok` + uuid, name, properties (jsonb), or `reason` = `invalid` / `unavailable` |
| `net.apply_auth_results()` | consumes the verdicts: login checks, compression, `login_finished` with the profile properties |
| `mc.player_property`, `mc.profile_props(uuid)` | skins and other profile properties as readable rows; the wire form is built on demand |
| `net.gateway_stats` | one row per second written by the gateway |

The first sketch (`docs/NET.md`) had a `kind` column in the outbox for compression and encryption switches and an `auth_job` table to poll.  Neither is needed: **outbound**
compression is entirely the database's business (it frames and compresses every packet according to `net.conn.compression`, with the native or SQL deflate), and the gateway
learns about **inbound** compression, the play state and a pending key request from `net.gateway_ctl`.  Encryption starts at a byte boundary the gateway itself observes
(the key frame), not one the database announces.

## Online mode, step by step

```
client                         gateway                            database (SQL)                      session server
  │ handshake(intent 2), hello(name) ─────────────▶ frames ──▶ net.h_login: online_mode = true
  │                                                              net.start_encryption: token = 4 random bytes,
  │                                                              await_key = true, queue encryption_request
  │ ◀──────────────── encryption_request(serverId "", publicKey DER, token, true) ◀── drain
  │                                  ◀── gateway_ctl: await_key, name, token (the reader now expects the key frame)
  │ secret = 16 random bytes
  │ POST /join {profile, serverId = hash(secret)} ─────────────────────────────────────────────────────────────▶ records it
  │ key(RSA(secret), RSA(token)) ───▶ reader: ONLY now interprets a frame:
  │                                   RSA-decrypt both (PKCS#1 v1.5), secret must be 16 bytes, token must match;
  │                                   any failure closes the connection WITHOUT a message (same behaviour for every failure)
  │ ═══ everything after the key frame is AES-128-CFB8, key = IV = secret, both directions ═══
  │                                   decrypt the bytes already buffered behind the key frame, start the encryptor
  │                                   ──▶ KeyAccepted ──▶ net.auth_begun
  │                                   hash = signed hex SHA-1(serverId ‖ secret ‖ publicKey DER)
  │                                   GET hasJoined?username&serverId=hash ──────────────────────────────────▶ (pooled, bounded, timeout)
  │                                   ◀───────────────────────────────────────── 200 + profile | 204 | 4xx | 5xx | timeout
  │                                   verdict ──▶ net.auth_result ──▶ net.apply_auth_results (next tick):
  │                                     ok:  ban/whitelist/full checks (vanilla order: after authentication), store properties,
  │                                          [login_compression], login_finished(uuid, name, properties, sessionId)
  │                                     204/4xx: login_disconnect multiplayer.disconnect.unverified_username
  │                                     429/5xx/timeout: login_disconnect multiplayer.disconnect.authservers_down
  │ ◀── (encrypted) login_finished / login_disconnect
  │ login_acknowledged ───▶ configuration ───▶ play   (tab list: player_info_update carries the properties)
```

Choices that follow vanilla (read from the 26.3 bytecode with `javap`, not from memory): the profile Mojang returns is used as it is, including its name (`Quirk1` →
whatever case Mojang says); ban, whitelist and capacity are checked after authentication; an empty or invalid session is `unverified_username`, an unreachable or erroring
session server is `authservers_down`.  The server id sent is the empty string, `shouldAuthenticate` is true, the key is 1024-bit RSA.

**Protocol violations** (wrong token, a secret encrypted with another key, a secret that is not 16 bytes, a frame that is not the key packet, a second hello during the key
exchange) close the connection without a message and **never reach the session server** (tested).  Vanilla also cannot deliver a readable message there: its client has
already switched to encryption.  All failures look the same from outside (no padding-oracle distinction).

**Chat signing.** The server announces `enforcesSecureChat = false` and relays chat unsigned, as on the offline path.  Real online clients still sign their chat messages; they
are accepted and relayed without the signature chain.  Signed chat (chat sessions in the tab list, `player_chat` with signatures, "chat reports") is not implemented.

**Replay and the hash.** The hash covers a fresh random 16-byte secret chosen by the client and this server's key, so a recorded hash is useless for another connection.  The
gateway asks the session server **exactly once** per login (tested: the stub counts queries and the client checks the hash it sent against its own computation); a successful
`hasJoined` is single-use on the real service, so there is no retry after an answer.  Retries (default 1) happen only after "unavailable", with a 100 ms pause.

## Compression and framing rules

* Inbound: the length prefix is a VarInt of at most 3 bytes (value at most 2,097,151); an overlong form, a length of 0, or a length above the connection's limit closes the
  connection (the corpus of adacraft agrees: `tests/corpus`, checked in `gateway/core/tests/corpus.rs`).  Before the play state the limit is `prelogin_max_frame` (32 KiB) and the
  total bytes read are capped at `prelogin_max_bytes`.  A socket with no complete frame for 30 s is closed (vanilla's read timeout; it covers both idle and stalled-mid-frame).
  The log line of such a close now says how old the connection was, how many bytes and frames it had sent, and whether it was in play (docs/PERF-CAPACITY.md, "The dropped clients": the
  500-player drops were joiners held in the configuration state for more than 30 s, which the database now keeps alive with the configuration keep-alive of sql/980).
  The gateway is one thread: it reads every socket once per loop pass, before each tick, and writes after it, so a tick of 800 ms delays a client's bytes by at most 800 ms and loses none;
  nothing in the gateway can make a client that sends bytes look silent for 30 s.
* With compression on: `[VarInt data length][zlib data | raw]`; a data length below the threshold or above 8,388,608 is an error, and the inflated size must match exactly.  The
  std-only inflater enforces the output limit while decoding (a 10 MB bomb announced as 300 bytes stops at 301; tested).
* Outbound framing and compression are the database's (`net.frame`, `net.deflate_frame`).
* Backpressure: bytes queued for a socket and not yet written are counted; above `max_pending_bytes` the client is disconnected (it cannot keep up).  Writes have a timeout.
* Limits: total connections, connections per address, new connections per address per second, login attempts (key responses, each costs an RSA decryption) per address per minute.

## Measured

Everything here ran on a 4-CPU container shared with up to seven other workers (load average 5 to 10), so treat timings as indicative; ratios and pass/fail are exact.

| What | Result |
|---|---|
| std-only AES-128-CFB8 (T-table, one stream) | encrypt 9.3 MB/s, decrypt 7.2 MB/s at load 8.8 (`gateway/core/examples/bench_cfb8.rs`); this is the *reference* cipher, about 7x slower than AES-NI |
| AES-CFB8 with AES-NI, from `docs/TCL-PATH.md` and `docs/GO-EVALUATION.md` | 56 to 70 MB/s serial per stream, 138 MB/s with 8 connections in lockstep, decrypt 137 to 515 MB/s |
| consequence | at about 20 KB/s of outbound traffic per player the std-only cipher supports only a few hundred players per core on encryption alone: the production gateway is built with the `aesni` feature (default) |

**Concurrent online-mode logins** through the PL/Python *reference* gateway (one Postgres backend, one thread) and the SQL half, with the stub session server
(`tests/gateway/run_online.sh THRESHOLD N CONCURRENCY`, load average 8.6 to 9 on 4 CPUs, the client is Python with real RSA and AES, so beyond about 100 concurrent clients the
CLIENT is the bottleneck and these numbers are a floor):

| clients (concurrent) | compression | result | throughput | latency p50 / p95 / p99 (ms) | gateway ticks over budget |
|---|---|---|---|---|---|
| 100 (30) | off | 100 ok, 0 failed | 74 logins/s | 301 / 439 / 455 | 15 of 28 (the machine, not the work: max tick 109 ms) |
| 300 (100) | threshold 256 | 300 ok, 0 failed | 122 logins/s | 618 / 1347 / 1409 | 33 of 45 (max tick 215 ms) |

An uncontended login takes about 3 ticks (hello, key response, verdict): 150 to 250 ms.  `net.conn` was empty afterwards (no leaked rows) in the runs that checked it.

Two things the load test found, neither a gateway bug: (1) the first runs showed 9 to 14% of logins reset right after the encryption request; the cause was the *stub*
session server (`http.server` listens with a backlog of 5, so 30 simultaneous `join` calls overflowed it); fixed in `tests/gateway/stub_mojang.py`.  (2) One login in the
first runs got `authservers_down`: the correct answer to a session-server timeout (1 s in the tests) on a machine at load 10.

Not measured by that test: more than 300 simultaneous logins, a real Mojang round trip.  What the design estimates say about steady-state play traffic
(not logins) is in `docs/TCL-EVALUATION.md`, `docs/GO-EVALUATION.md` and `docs/TCL-PATH.md`: about 2,600 to 3,000 players per core for a native gateway with AES-NI.

## Measured: the Rust gateway

Build: `gateway/build.sh`.  Machine: 4 CPUs shared with other workers (load average 1 to 2.6 during these runs, about 8 other Postgres clusters idle or lightly busy).  Own cluster on port 54655
(54555 was taken by another worker), gateway on 25651.  Load generator: `tests/gateway/load_clients.py` (real offline join per client: handshake, login, configuration, entry, chunks;
then `client_tick_end` at 20 Hz, 20% of clients walking at 4.3 blocks/s; a few probe clients time input to corrective teleport).  Runner: `tests/gateway/run_load_rust.sh`.
Settings: view_distance 2, `max-players` raised, per-IP limits off, `mc.server_tick()`, `inbox_mode=copy`.  All clients spawn at the same point, so every player sees every other (worst case for the SQL fan-out).

| clients | gateway CPU (steady) | Postgres CPU | gateway RSS | tick (avg / max, DB-side) | late ticks | probe latency p50 / p95 / p99 |
|---|---|---|---|---|---|---|
| 1 real client, 5 min soak | not sampled | not sampled | not sampled | 5.1 to 6.3 ms avg, 11 to 13 ms max | 0 | n/a |
| 20 | 1.8% of a core | 14% | 13.6 MB | 8.2 ms / 25 ms | 0 | n/a |
| 500 | 5.8% of a core | 91.5% of a core | 29 MB (58 kB per connection) | 62.8 ms / 123 ms (16 ticks/s) | 296 in the window | 95 / 182 / 1784 ms |
| 2,000 | not meaningful | about 105% of a core | 63 MB at 1,713 connections | seconds per tick | n/a | 1.9 s / 9.6 s / 22 s |

What this says, plainly:

* **The gateway is not the bottleneck; the database is.**  At 500 players the gateway used 5.8% of one core (about 5.8 microseconds per client per tick, including AES off, framing, COPY encoding and the drain) while Postgres was at 91%
  and the tick already overran its 50 ms budget (avg 63 ms).  At 2,000 clients only 1,713 got in (287 timed out in the login storm: join p50 28 s, p95 85 s) and the tick was in seconds.
  So with this SQL server and this spawn pattern the sustainable size on this machine is a few hundred players, far below the design estimate of about 2,800 players per core, which is a *gateway* estimate and still plausible
  for the gateway (extrapolating 5.8 microseconds per client-tick gives about 58% of a core at 5,000, but that is an extrapolation from a run whose ticks were slow, not a measurement).
* The join storm is the dominant cost (every join sends the registry burst and chunks): 500 joins took p50 5.1 s, p95 10.4 s at a ramp of 400 per second.
* RSS per connection 58 kB at 500 (no per-connection thread).
* **5,000 clients: not run**, since 2,000 already showed the database collapsing and a run would have measured the same wall; **the PL/Python gateway comparison and the lockstep AES experiment were not done** (encryption is off in offline mode, so there was nothing to measure for it).
* The load generator itself (Python, 2 to 3 processes on the same 4 CPUs) uses a lot of the machine, so all client-side latencies are upper bounds.
* inbox `copy` versus `unnest` was **not compared**; `copy` was used throughout.

Soak: `tests/gateway/soak_rust.sh 5`.  Caveat: the client did not actually advance across chunk borders in the soak (z stayed about 10; the position oscillated near a hole it had dug earlier), so border crossings are covered by the e2e test (3 crossings), not by the soak.

Real client results (screenshots in `/tmp/mc-client/shots/`, not committed): joined, flat grass world rendered, 2 s of walking moved z from 0.5 to 9.13, a block broken (server holds the block as air), chat and a command recorded in `mc.chat_log`.  The client's nine "Exception" log lines are its own failed calls to Mojang account and Realms services (401), the same as against vanilla.

Things found while building (all fixed): OpenSSL 3.0 implicit rejection in PKCS#1 v1.5 (see the README), `EVP_RSA_gen` is a macro (the binding uses `EVP_PKEY_Q_keygen`), and a stale `net.gateway_control.stop = true` left by a previous run's cleanup made a new gateway exit at once (it now clears the flag at startup).

## Known gaps and next steps

1. Done: built, unit tested, e2e, online (27/27, valgrind clean), real client offline, 5-minute soak.
2. Still open: a real client in online mode (needs a Mojang account), the real session server, 5,000-client run, `copy` versus `unnest` comparison, a comparison with the PL/Python gateway under the same load, and the
   database-side cost of joins and of everybody seeing everybody (that, not the gateway, is what limited the 500 and 2,000 client runs).
3. Optional and only if measurement ever shows encryption matters: several connections' AES in lockstep, multi-block CFB8 decryption.  Not needed offline.
4. The gateway uses libcrypto's AES-NI CFB8 (`EVP_aes_128_cfb8`); the std-only core cipher is kept as the tested reference.
5. **Keep three function copies in sync.**  `sql/601_online_login.sql` redefines `net.h_login` (a copy of the body in `sql/400_integration.sql` plus the online branch),
   `mc.pie_add` (a copy of `sql/310`'s with `mc.profile_props`) and `net.conn_tab_sync` (a copy of `sql/464`'s with the properties).  They are listed in `sql/OVERRIDES.txt`; a
   later edit of the original in its own file is silently overridden by 601 unless it is repeated there.  The clean fix is to move the online branch and the properties into the
   original definitions once nobody else is editing them.
6. Statistics `rejected` (connections refused by a limit) is not counted yet.
7. **Gateway restarts.**  A process numbers its connections from 1, so it calls `net.gateway_start()` first: stale connections of the previous process are disconnected
   through `net.on_disconnect` (the game saves and removes their players) and the queues that could carry bytes for old ids are emptied (tested in
   `tests/sql/600_gateway_online.sql`; both gateways call it).  This assumes ONE gateway process per database; several processes behind one port would need their id ranges
   and a per-process cleanup.
8. Secure chat (signatures), transfer packets, cookies and the real-client online path are out of scope here.
