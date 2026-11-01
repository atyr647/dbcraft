# The gateway

The gateway is the byte pipe between Minecraft clients and the database.  Everything that is game, protocol or rule lives in SQL; the gateway does the five things SQL
cannot: **sockets**, **AES-128-CFB8**, **RSA decryption of the shared secret**, **the HTTPS check with Mojang's session server**, and **inflating inbound compressed frames**.
It holds no game state and parses no packet except the one login frame it intercepts in online mode.

## Status: what exists and what was verified

| Piece | Where | State |
|---|---|---|
| SQL half: control channel, encryption request, verdicts, profile properties | `sql/600_gateway.sql`, `sql/601_online_login.sql` | **tested**: `tests/sql/600_gateway_online.sql` (43 checks); override and inlining guards green on a clean migration |
| Reference implementation of the whole contract, as database code | `sql/optional/dev_gateway_online.sql` (`net.run_online`) | **tested end to end** with real RSA and AES-CFB8 (OpenSSL via Python `cryptography`), a stub session server and an encrypting client: `tests/gateway/online_test.py`, 27 checks, with compression off and at threshold 256 |
| Std-only core: frame splitting, inflate, AES-128-CFB8, SHA-1, server hash | `gateway/core/` | **tested**: 22 unit tests + 216 real-zlib inflate vectors + adacraft's corpus + randomised stress + AES-CFB8 against the `openssl` binary (40 random rounds, both directions) |
| The gateway proper (tokio, Postgres, RSA, HTTPS) | `gateway/src/` | **never compiled.** `cargo build` was not permitted in the environment where it was written (the permission system refused to compile and run downloaded crates). It is written against the tested core and the proven contract; `rustc` accepts its syntax and its uses of the core API type-check, the only errors left are the unresolved crates. Expect a first build to need small fixes. |
| Real Mojang session server | | **never called** (tests use a local stub) |
| A real vanilla client in online mode | | **untested** (it needs a Mojang account); the offline path with a real client is tested elsewhere (`docs/REAL-CLIENT.md`) against the SQL server and the PL/Python gateway, not against the Rust gateway |
| Rust gateway performance | | **not measured** (nothing to run); estimates below are from `docs/*-EVALUATION.md` |

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
LOAD_RESULTS_PLACEHOLDER

## Known gaps and next steps

1. **Build it.**  `cd gateway && cargo build --release`, fix what the compiler finds, `cargo test`.  Then run the online test against it:
   `DBCRAFT_RUST_GATEWAY=gateway/target/release/dbcraft-gateway tests/gateway/run_online.sh -1` and `... 256`; the same 27 checks must pass.
2. Run the offline e2e comparisons (`tests/e2e/`) and the real client (`tools/realclient/`) against the Rust gateway.
3. Measure it: 500, 2,000 and 5,000 simulated clients, CPU per tick, memory per connection, tick overrun rate (the load generators of `tests/e2e` and `tests/gateway/online_load.py` are the start).
4. The AES-NI path (`gateway/src/cipher.rs`, the `aes` crate) is written but, like the rest of `gateway/src`, never built; CFB8 *decryption* of inbound data can additionally be
   done several blocks at a time (the keystream depends only on ciphertext), and encryption of several connections can run in lockstep; both only if measurement says so.
5. Statistics `rejected` (connections refused by a limit) is not counted yet.
6. Secure chat (signatures), transfer packets, cookies and the real-client online path are out of scope here.
