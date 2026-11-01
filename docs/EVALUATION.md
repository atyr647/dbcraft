# Language and in-SQL evaluation

Measured on the dev container: PostgreSQL 16.15, 4 cores, `fsync=off`, `synchronous_commit=off`.
Scripts: `tests/bench/`.  Numbers are single runs, indicative, not a benchmark suite.

**Correction.** A first run of the varint and AES tests used constant arguments to `IMMUTABLE` functions.
The planner folded them to one evaluation, so those timings were meaningless and are not used.
The numbers below use a different input per row.

## What Postgres does well

| Test | Result |
|---|---|
| Move 10k players, one set-based `UPDATE`, no index on hot columns (HOT) | 14 ms |
| Same, with an index on a column that changes every tick | 33-54 ms (no HOT updates) |
| Same work as a per-row PL/pgSQL loop | 78 ms (5.5x slower than the set-based form) |
| `COPY` of 10k packets into an `UNLOGGED` table (one tick at 10k players) | 5 ms |
| Varint decode, 200k different packets, PL/pgSQL loop | 204 ms |
| Same, as an inlinable `LANGUAGE sql` expression | 28 ms (7.4x faster) |
| Unpack 200 sections x 4096 entries into rows (read-only, simplified byte read) | 19 ms |

## What it does badly

| Test | Result |
|---|---|
| Re-pack 4096 palette indices into 5-bit longs, `generate_series` + `bit_or`, per section | 57 ms per section (about 1.4 s per 24-section chunk) |
| AES-ECB through pgcrypto, one block | 1.2 us |
| AES-CFB8 decrypt built from ECB in PL/pgSQL | 1.4 us per byte, about 0.7 MB/s per core |

AES-NI native CFB8 is roughly 100-200x faster than that, so encryption stays outside SQL.
pgcrypto also has no raw RSA PKCS#1 decrypt (only PGP), and Postgres exposes no zlib function.

## JIT

`jit` is on and `llvmjit.so` is installed, but PG's JIT only compiles executor expressions and tuple deforming.
It does not compile PL/pgSQL bodies.  With the thresholds forced to 0 it made things worse:
the varint query went from 28 ms to 2.9 s and the packing query from 11 s to 26 s, all compile time.
Decision: `jit = off` for the tick.  The usable speedup is writing hot code as inlinable `LANGUAGE sql`.

## Design consequences

* Store sections in wire format (packed longs + palette) and decode them for the readable `blocks` view.
  Never re-pack on the hot path.
* Hot packet decoders are inlinable SQL expressions; rare packets can use plain PL/pgSQL.
* Keep hot columns unindexed so updates stay HOT; use `fillfactor` below 100.
* Tick work is set-based, never per-row loops.
* Not measured yet: in-place bit edits of a wire-format section, the full tick under load, a bgworker `SPI` path.
