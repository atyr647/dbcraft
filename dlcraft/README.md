# dlcraft: a database-native Minecraft server core on Datalevin, benchmarked against dbcraft's PostgreSQL design

A small experiment next to [dbcraft](../README.md).  dbcraft keeps a Minecraft server's world, players, queues and tick logic in PostgreSQL.  This directory asks:
**what would the same idea look like on [Datalevin](https://github.com/juji-io/datalevin)** (a Clojure database that is an LMDB key-value store with Datalog,
full-text and other indexes on top, embedded in the process), and **how do the two compare, facet by facet?**

It is *not* a playable server.  There is no network protocol, handshake or real client.  What exists is the part that decides a server's performance and shape:
world storage in Minecraft's wire format, terrain generation, block edits, fills, chunk packets, players, spatial indexing, visibility, the 20 Hz tick that turns
inbound move packets into outbound entity packets, scheduled ticks and water, random ticks, chat, inventories, and durability.  Both implementations are driven from
the same deterministic inputs and **must produce byte-identical outputs** before any timing is reported (see "How the comparison is kept honest").

> **Results** ([RESULTS-SUMMARY.md](RESULTS-SUMMARY.md) has the reading and the caveats, [results/RESULTS.md](results/RESULTS.md) every number):
> Datalevin's in-process, byte-level design is **4x to 9x faster on the tick** (500 to 2000 players; only 1.3x in a crowded world where fan-out dominates), 30x to 60x on world and
> chunk operations, and equal on disk size.  PostgreSQL is **6x faster on chat inserts, 10x on full-text search**, scales better with many strict concurrent writers, and uses about
> 5x less memory.  Inside Datalevin, hot data must go in raw KV (0.94 ms per tick of position updates) and not in datoms (16.5 ms).  Both engines produce byte-identical output
> for every workload (78 equivalence checks plus a digest of every frame of every benchmarked tick).

## Layout

```
SPEC.md                  the contract both sides implement: section wire format, generator maths, edit semantics, tick, packets, dynamics, chat, inventory
spec/golden.edn          golden vectors produced by the Clojure reference (hashes, heights, chunk payload SHA-256s)
src/dlcraft/             the Datalevin implementation
   store.clj             one LMDB environment: raw KV DBIs next to the Datalog indexes, durability profiles, an in-memory environment for queues
   codec.clj gen.clj     varints, bit packing, section blobs; the integer-only terrain generator
   world.clj             get/set/fill, palette rules, chunk packets and their cache, world hash, analytics
   game.clj              players, spatial cells, visibility, the tick, packets
   dyn.clj               scheduled-tick queue, water, random ticks
   social.clj            chat (Datalog + full text), inventories (Datalog entities, and one KV record per player)
   workload.clj          deterministic inputs shared by both engines
pg/                      the PostgreSQL implementation in dbcraft's style (schema mc): written for this experiment, see below
bench/                   verify.clj (equivalence), facets1-3.clj (the benchmarks), main.clj (driver + report), pg/bench.sql (benchmark-only SQL)
tools/                   pg.sh (throwaway PostgreSQL 16 cluster with dbcraft's tuning), clj.sh, pg-load.sh
results/                 results.json and RESULTS.md written by `main run`
```

## The Datalevin design

dbcraft's rule is "the world is rows; the logic is SQL; one tick is one transaction".  The Datalevin version keeps the first and third and changes the second, because the
database is a library inside the same process:

* **One LMDB environment holds everything durable**, through Datalevin's `datalog-kv`: raw key-value tables for the hot, binary, ordered data and the Datalog store for
  the relational data.  A write over both commits atomically.
* **World = KV.**  A section is the wire format itself (palette, bits, packed longs) under a 10-byte big-endian key `[cx cz sy]`, so a chunk is one range scan and a
  chunk packet is the concatenation of the values.  A per-chunk version, a packet cache and the block-event queue are KV tables in the same transaction as the edit.
* **Hot per-player state = one packed 65-byte record**, the spatial hash `[cx cz eid]` and the visibility pairs `[viewer target]` are sorted KV tables.  The tick reads,
  computes and applies everything in one atomic batch.
* **Relational, searchable data = Datalog**: chat (with the built-in full-text index) and, as a deliberate comparison, inventories as one entity per stack.
* **Queues (inbox/outbox) = a second, in-memory-only LMDB environment** (Datalevin's `:inmemory?`), the counterpart of PostgreSQL's UNLOGGED tables.
* **Logic lives in the process** (Clojure functions over the database handle), not in stored procedures: there is no client/server round trip and no query planner in the hot path.

Where a Datalog or relational shape and a raw KV shape were both plausible, both were built and measured (hot position updates, inventories): the lesson is in the results.

## The PostgreSQL side

`pg/` is a compact re-implementation of dbcraft's *patterns* (section rows with palette/bits/packed-long `bytea`, HOT-friendly player table with fillfactor 60 and no index on
hot columns, UNLOGGED queue tables, a `mc.visible` pair table, set-based `server_tick()` in SQL, PL/pgSQL for per-row logic), written against SPEC.md and run with the
settings dbcraft itself recommends (`docker/postgresql.conf`: `shared_buffers=128MB`, `jit=off`, `synchronous_commit=off`, ...).  It is **not** dbcraft's 157-file server:
that one needs Mojang's server jar for its reference data, does vastly more per tick (light, heightmaps, survival, containers, ...), and could not be run offline here.
Read every PostgreSQL number as "the cost of this workload done the dbcraft way", not as "dbcraft's tick time".

## How the comparison is kept honest

1. **Same bytes.**  `tools/clj.sh -M -m verify` builds the same world in both engines (the generated world hashes match byte for byte), applies the same edits, fills, palette
   overflows and batch edits, ticks 200 players for 60 ticks (with rejected moves and block broadcasts) and compares the digest of every outbound frame of every tick, then
   dynamics, chat and inventory.  The tick benchmark re-checks a digest of every frame it measures.
2. **Same inputs.**  Every position, move, edit, chat line and click is a pure function of integers (`hash2`), generated once and fed to both.
3. **Where the work happens is stated.**  Datalevin runs in-process; PostgreSQL is a server.  Numbers are reported both as the engine's own work (server-side loops, one
   statement per tick) and as the client sees it (JDBC over loopback TCP, per-call round trips), and the table says which.
4. **Durability is stated.**  Datalevin profiles (`:sync`, `:nometasync`, `:nosync`, WAL) and PostgreSQL settings (`synchronous_commit` on/off, `fsync` off) are not equivalent;
   the durability facet measures each and the main facets use dbcraft's own relaxed setting on the PostgreSQL side and `:nometasync` on the Datalevin side.

## Running it

```bash
# one-off: the Clojure CLI (no root needed; any directory, point DLCRAFT_HOME at it) and a JDK 21
mkdir -p /srv/dlcraft/tools && cd /srv/dlcraft/tools
curl -fsSLO https://download.clojure.org/install/clojure-tools-1.12.0.1530.tar.gz && tar xzf clojure-tools-1.12.0.1530.tar.gz
# (its install.sh needs perl/ruby; instead copy clojure-tools/{clojure,clj} to ./clojure/bin, the jar to ./clojure/libexec and replace PREFIX / BINDIR in the two scripts)

cd dlcraft
tools/pg.sh start relaxed        # PostgreSQL 16 on 127.0.0.1:54340 with dbcraft's settings (needs the Ubuntu postgresql-16 package)
tools/pg-load.sh dlbench         # pg/*.sql and bench/pg/*.sql
tools/clj.sh -M -m verify        # equivalence checks; must all PASS
tools/clj.sh -M -m main run      # every facet (about 15 minutes); or: main run tick chat inv
```

Datalevin 1.2.10 needs `--add-opens java.base/java.nio=ALL-UNNAMED --add-opens java.base/sun.nio.ch=ALL-UNNAMED --enable-native-access=ALL-UNNAMED` on JDK 21 (set in `deps.edn`'s `:run` alias).
