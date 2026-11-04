# dbcraft gateway

The byte pipe between Minecraft clients and the database.  It does what SQL cannot (sockets, AES-128-CFB8, RSA, the Mojang session check, inflating inbound frames)
and nothing else: no game state, no rules, no packet parsing beyond the one login frame it intercepts in online mode.  Design, contract, verified results and
numbers: [`docs/GATEWAY.md`](../docs/GATEWAY.md).

**Zero crates.io dependencies.**  Only `std` plus the system libraries the machine already has, bound by hand-written `extern "C"` declarations:
libpq (Postgres), libcrypto (OpenSSL 3: RSA, AES-128-CFB8), libcurl (the session-server GET) and libc (epoll, eventfd, signalfd).

```
gateway/
  build.sh      plain rustc build and test runner (no cargo needed)
  Cargo.toml    optional: a manifest with only a path dependency, `cargo build --release --offline` works too
  core/         std-only crate: frame splitting (adacraft's rules), inflate, AES-128-CFB8 reference cipher, SHA-1, Minecraft's server hash
  src/
    main.rs       startup, signals, config
    gateway.rs    the single-threaded epoll loop and the 50 ms tick (one database transaction per tick)
    reader.rs     per-connection read state machine (decrypt, split, inflate, spot the login key frame); pure, socket-free
    mojang.rs     bounded worker pool for hasJoined (libcurl), results come back through an eventfd
    keypkt.rs json.rs config.rs limits.rs wq.rs   login key packet parser, JSON parser, config, per-IP limits, write queue with backpressure
    ffi/          the only unsafe code: sys.rs (libc), pq.rs (libpq), ossl.rs (libcrypto), curl.rs (libcurl); every unsafe block states its invariant
```

## Build and test

```
gateway/build.sh              # release build -> gateway/target/dbcraft-gateway
gateway/build.sh debug        # with debug info and overflow checks (what valgrind runs)
gateway/build.sh test         # core + gateway unit tests (75), built with `rustc --test`
```

Needs the dev libraries' runtime `.so` files only (libpq.so.5, libcrypto.so.3, libcurl.so.4); libcurl is linked by soname because no `libcurl.so` symlink is installed.
Integration scripts (each needs its own Postgres cluster, see the scripts' headers): `tests/gateway/run_e2e_rust.sh`, `tests/gateway/run_online_rust.sh THRESHOLD`,
`tests/gateway/gateway_valgrind.sh`, `tests/gateway/soak_rust.sh`, `tests/gateway/run_load_rust.sh N`.

## Run

```
DBCRAFT_GW_DATABASE_URL="host=/var/run/postgresql user=postgres dbname=dbcraft" DBCRAFT_GW_LISTEN=0.0.0.0:25565 gateway/target/dbcraft-gateway [config-file]
```

The config file is `key=value` lines; every key has an environment override `DBCRAFT_GW_<KEY>`.  SIGTERM / SIGINT shut down cleanly.  Needs the database migrated
(`tools/migrate.sh`).  At startup the gateway publishes its RSA public key (`net.server_key`), calls `net.gateway_start()` and clears a stale stop flag.

| key | default | meaning |
|---|---|---|
| `database_url` | `host=/tmp port=5432 user=postgres dbname=dbcraft` | libpq connection string |
| `listen` | `0.0.0.0:25565` | the Minecraft port |
| `tick_ms` | 50 | tick period (drift-free) |
| `tick_fn` | `mc.server_tick()` | or `mc.server_tick_batched()` (an allowlist; nothing else is accepted) |
| `inbox_mode` | `copy` | how inbound frames reach `net.inbox`: binary `copy` or an `unnest` insert |
| `maintenance_s` | 5 | seconds between maintenance passes: a thread with its own connection runs `VACUUM (ANALYZE, SKIP_LOCKED)` on `maintenance_tables`; 0 = off (then run `tools/janitor.sh` or rely on autovacuum with `autovacuum_naptime = 1s`). See `docs/SOAK.md` |
| `maintenance_tables` | `net.conn, mc.player, mc.visible, mc.chunk_wanted, ...` | schema-qualified tables (a-z, 0-9, `_`) separated by commas or spaces; NOT the queues `net.inbox`/`net.outbox` (the database truncates them itself: `sql/780`) |
| `lean_ticks` | true | a tick with nothing for the database (no new socket, no inbound frame, no key response, no verdict, no closed socket) runs ONE prepared statement, `select mc.server_tick(), net.gateway_pending($1)`, instead of the whole statement set; the outbox is drained and the control rows read only when the probe says so; the statistics row is written every 20th such tick (a stop request is acted on within 1 s). `docs/PERF-IDLE.md`, `docs/PERF-IDLE2.md` |
| `skip_tick_end` | true | `client_tick_end` frames of a play connection that sent fewer than two position packets in the tick are not given to the database (they cannot change anything there; `sql/800`), so idle players leave the inbound queue empty and their ticks run lean |
| `urgent_chat` | true | serverbound `chat` frames are handled between ticks (`net.urgent_chat`, then a drain, one transaction) when the next tick is far enough away; commands, and chat behind a command or behind another kind of frame of the same connection, wait for the tick. false = chat waits for the tick like every other frame. `docs/PERF-IDLE.md` |
| `generators`, `generator_batch`, `generator_exit_idle_ms` | 0, 64, 1500 | chunk generator threads with connections of their own (`call mc.run_generator_until_idle`, sql/970) for `dbcraft.chunk-generation = async`: parked while there is nothing to generate, woken by the tick's probe (`net.gateway_pending` bit 4) when `mc.chunk_request` has a row; a woken thread polls every 5 ms, and parks after `generator_exit_idle_ms` without work. 0 = none (inline generation, or `call mc.run_generator()` loops started by hand, which poll for ever: about 0.003 cores each). `docs/PERF-IDLE2.md` |
| `tick_log` | empty | a file written at shutdown with one line per tick (ms since start, the whole tick in ms as the gateway saw it, flags); `tools/scoreboard/tick_tail.py` reads it |
| `urgent_reserve_ms` | 4 | milliseconds that must remain before the next tick, on top of the measured cost of the last urgent run, for an urgent run to start |
| `urgent_max_per_tick` | 4 | at most this many urgent runs between two ticks (a chat flood must not starve the tick) |
| `max_connections`, `max_connections_per_ip` | 20000, 16 | connection limits (0 = unlimited per IP) |
| `new_connections_per_ip_per_sec`, `login_attempts_per_ip_per_min` | 5, 20 | rate limits (0 = unlimited) |
| `read_timeout_s` | 30 | idle sockets and stalls inside a frame are closed |
| `max_pending_bytes` | 8 MiB | a client that cannot keep up is disconnected |
| `prelogin_max_frame`, `prelogin_max_bytes` | 32768, 262144 | size limits before the play state |
| `session_url`, `session_timeout_ms`, `session_workers`, `session_retries` | (net.setting), 5000, 32, 1 | the hasJoined check |
| `rsa_bits` | 1024 | size of the published key (vanilla uses 1024) |

A note on OpenSSL 3.0 (Ubuntu): RSA PKCS#1 v1.5 decryption uses *implicit rejection*, so a bad padding returns success with pseudo-random bytes.  The gateway therefore
requires a secret of exactly 16 bytes and the verify token it sent, and nothing else is trusted.
