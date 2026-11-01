# dbcraft gateway

The byte pipe between Minecraft clients and the database.  It does what SQL cannot (sockets, AES-128-CFB8, RSA, the Mojang session check, inflating inbound frames)
and nothing else: no game state, no rules, no packet parsing beyond the one login frame it intercepts in online mode.  Design, contract and test status:
[`docs/GATEWAY.md`](../docs/GATEWAY.md).

```
gateway/
  core/     std-only crate, no dependencies, TESTED: frame splitting (adacraft's rules), inflate, AES-128-CFB8, SHA-1, Minecraft's server hash
  src/      the gateway proper (tokio, tokio-postgres, rsa, reqwest/rustls): config, RSA key, Mojang client, connection tasks, tick loop
```

**Status, in one line:** `core/` builds with plain `rustc` and is tested; `src/` was written where `cargo build` was not permitted and has never been compiled.
Expect a first build to need small fixes.  Everything it must do is specified by running code: the SQL half (`sql/600`, `sql/601`, tested) and the reference
implementation of the same contract (`sql/optional/dev_gateway_online.sql`, end-to-end tested against real RSA/AES).

## Build and test

```
cd gateway/core && rustc --edition 2021 --test src/lib.rs -O -o /tmp/core_tests && /tmp/core_tests     # unit tests of the core (no cargo needed)
cd gateway && cargo build --release                                                                  # the gateway (default feature: aesni, AES-NI blocks from the `aes` crate)
cd gateway && cargo test                                                                             # core + gateway unit tests
tests/gateway/cfb8_openssl.sh                                                                        # the cipher against the openssl binary
```

## Run

```
DBCRAFT_GW_DATABASE_URL="host=/var/run/postgresql user=postgres dbname=dbcraft" \
DBCRAFT_GW_LISTEN=0.0.0.0:25565 \
target/release/dbcraft-gateway [config.toml]
```

Needs the database migrated (`tools/migrate.sh`, which includes `sql/600_gateway.sql` and `sql/601_online_login.sql`) and `mc.server_property` / `net.setting` configured
(`online-mode`, `network-compression-threshold`).  Every setting below has an environment override `DBCRAFT_GW_<NAME>` and can be put in the TOML file.

| setting | default | meaning |
|---|---|---|
| `database_url` | `host=/tmp port=5432 user=postgres dbname=dbcraft` | libpq-style connection string |
| `listen` | `0.0.0.0:25565` | the Minecraft port |
| `tick_ms` | 50 | tick period; `net.setting` key `tick_ms` overrides it, re-read every 5 s |
| `tick_fn`, `drain_fn` | `mc.server_tick()`, `net.drain_outbox()` | what a tick calls (use `mc.server_tick_batched()` for the batched pipeline); `net.setting` keys `gateway_tick`, `gateway_drain` override |
| `max_connections`, `max_connections_per_ip` | 20000, 16 | connection limits (0 = no per-IP limit) |
| `new_connections_per_ip_per_sec`, `login_attempts_per_ip_per_min` | 5, 20 | rate limits (a login attempt = a key response, which costs an RSA decryption) |
| `read_timeout_s`, `write_timeout_s` | 30, 30 | idle or stalled-in-a-frame sockets and blocked writes are closed |
| `max_pending_bytes` | 8 MiB | a client that cannot keep up (unsent bytes above this) is disconnected |
| `prelogin_max_frame`, `prelogin_max_bytes` | 32768, 262144 | frame and total size limits before the play state |
| `session_url`, `session_timeout_ms`, `session_concurrency`, `session_retries` | Mojang, 5000, 64, 1 | the hasJoined check (`session_url` is configurable for tests) |
| `rsa_bits` | 1024 | size of the key pair published to `net.server_key` (vanilla uses 1024) |
| `stats` | true | one row per second in `net.gateway_stats` |
