# Tried and not adopted

These two files are NOT part of the migration (`tools/migrate.sh` only applies `sql/*.sql`) and their tests are not run by `tests/sql/run.sh`.
They are byte-identical to the originals and fully tested; they are here because they did not help, and the way they were tested is worth keeping.

| File | What it does | Why it was dropped |
|---|---|---|
| `465_join_text.sql` | `proto.mutf8` / `nbt.mutf8` skip the regular expression for ASCII text (SQL wrapper, original body kept as `*_general`) | No measurable effect on a join |
| `466_join_text_builders.sql` | the NBT / text-component builders (`proto.nbt_text`, `proto.cat`, `nbt_int_array`, `nbt_list_str`, `nbt_list_comp`, `nbt.str`) as inlinable SQL or plan-cached PL/pgSQL | No measurable effect on a join |

What was measured (`tests/bench/join/ab.py`, 200 joiners in one tick into an empty server, interleaved, median of 3):

| database | ms per join |
|---|---|
| rounds 1-5 only (`sql/460-464`) | 13.01 |
| rounds 1-7 | 13.62 |
| the database that had been through all of them | 12.86 |

The differences are inside the noise of the shared machine (run-to-run spread about 5%).  Building the join message with plain variables, the way `mc.on_join` calls it,
went from 233 us to 126 us: a real gain of about 0.1 ms, less than 1% of a 13 ms join.  An earlier micro-benchmark that passed `gen_random_uuid()` as an argument showed 2 ms,
because a volatile argument that is used several times stops Postgres from inlining the function: it measured the benchmark, not the server.

Not adopting them also keeps the change smaller: they touch the NBT builders that chat, commands and kicks use.

## How `test_466_join_text_builders.sql` compares with the original

It does not copy the old functions into the test (a copy can drift).  It computes every result with the new code, runs the ORIGINAL source files
(`sql/110_nbt.sql`, `sql/300_game_nbt.sql`) again, which reinstalls the original functions, computes the same results, reinstalls the new code and compares row by row.
To run it, copy both SQL files back into `sql/`, add the override entries, and run it with `tests/sql/run.sh`.
