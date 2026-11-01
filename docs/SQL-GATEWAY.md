# Can the gateway live in SQL?

Short answer: **not as plain SQL, but yes as database-defined code.**  The network loop and the cipher can be a stored procedure in an
untrusted procedural language (PL/Python here) that runs inside a Postgres backend, calls SQL directly in-process, and is started with one `CALL`.

## What plain SQL cannot do

* Open or accept a socket.  No SQL command does this.
* Run AES-CFB8 fast enough.  Built from pgcrypto's AES-ECB: about 0.7 MB/s per core (`docs/EVALUATION.md`).  Encryption of outbound data is serial per connection, so it can't be vectorised.
* Make HTTPS calls to Mojang, or do raw RSA decrypt (pgcrypto has only PGP-style RSA).

## What a stored procedure in an untrusted PL can do

Prototype: `tests/prototype/pl_gateway.sql` (procedure `net.run`), load generator `pl_gateway_load.py`, runner `run_pl_gateway.sh`.
It listens on a port with epoll, splits frames, inserts each tick's packets with one SQL call, calls the tick function, drains the outbox, and writes the replies.
It `COMMIT`s every tick.  It is offline-mode echo only: it measures the architecture, not Minecraft behaviour.

Measured on the dev container (4 cores shared with the load generator and other benchmark processes, load average about 1):

| Connections x frames/tick | Frames per tick | Busy time per 50 ms tick (avg / p99 / max) | Of which SQL path | Result |
|---|---|---|---|---|
| 1,000 x 5 | 4,950 | 24.1 / 35.5 / 36.0 ms | 15.0 ms | keeps up, all bytes echoed back correctly |
| 3,000 x 5 | falls behind | 196 / 639 / 663 ms | 145 ms | overloaded |
| 6,000 x 5 | falls behind | 619 / 1780 / 1824 ms | 475 ms | overloaded |

Single process ceiling: about 5,000 frames in 24 ms, roughly **200k frames/s**.  At 100 inbound frames per player per second that is about 2,000 players of frame handling,
before the real game tick takes its share.

AES-CFB8 from inside the procedure (`tests/prototype/pl_aes.sql`, `cryptography` library on OpenSSL):

| Case | MB/s | per call |
|---|---|---|
| encrypt 1 KiB blobs | 43 | 24 us |
| encrypt 20 KiB blobs | 54 | 381 us |
| decrypt 64 B frames | 17-21 | 3-3.7 us |

That is native speed (the Rust benchmark got 58 MB/s encrypt).  With the same assumptions as `docs/TCL-EVALUATION.md` (about 20 KB/s outbound and 100 frames/s inbound per player),
frame handling plus encryption costs roughly 0.9 ms per player-second, so about 1,100 players per core at 100% CPU, **estimated, not measured end to end**.

Where the time goes at 5,682 frames (isolated): list-to-array SPI insert 4.7-5.3 ms; the same insert from one `bytea` blob sliced in SQL 2.6 ms; stub tick 2.0-2.2 ms; drain 0.2 ms.
The live run's 15 ms SQL path is higher than these isolated numbers and I did not find out why (candidates: delete churn, autovacuum).

## A bug I made and fixed

The first version of `net.tick` scanned an inbox table that was never emptied, so each tick scanned every earlier tick's rows and time grew linearly (24 ms to 33 ms and rising).
It now consumes the rows with `DELETE ... RETURNING`.  The numbers above are from the fixed version.

## Constraints that come with it

* Untrusted PL: functions can only be created by a superuser, and the code can do anything the postgres OS user can.
* One backend is one thread.  To use more cores, run several `net.run` backends on the same port (`SO_REUSEPORT`; the kernel spreads accepts) with one separate backend calling the game tick.  Not built or measured.
* The backend's open-file limit must be raised: the default soft limit of 1024 made `accept()` fail at about 1,000 connections (`LimitNOFILE` in production; `tools/pg-dev.sh` now sets `ulimit -n 20000`).
* `statement_timeout` and `idle_session_timeout` must be 0 for that role.  `pg_terminate_backend()` is a clean off switch.
* Something outside SQL must start the first `CALL` after boot (a `psql -c` line in the container entrypoint, or a preloaded background worker).
* Crash domain: a Python exception becomes a SQL error, but a segfault in a C library takes the backend down and Postgres restarts all sessions.
* Python's per-frame cost is the ceiling; a Rust `pgrx` background worker would remove it but is not measured.

## Consequence for the design

The gateway code can be stored as rows in the database (`CREATE PROCEDURE` is data in `pg_proc`), so "everything lives in the database" holds literally.
The same contract (`net.inbox`, `net.outbox`, `mc.tick()`) works whether the loop is a PL/Python procedure, an external Rust process, or a later Rust background worker, so this choice can be changed without touching the SQL.
