# Function inlining audit

Earlier workers found that one volatile or mis-marked function can silently cost orders of magnitude (`net.frame` 300 us to 8 ns once inlinable; `mc.sid()`).
This work builds a systematic audit, a guard, and the fixes that measured.

Measured on PostgreSQL 16.15, 4 CPUs, `jit = off`, the standard tick benchmark (500 players over 100 x 100 chunks, view distance 10, warm world,
`tests/bench/tick/run.sh`). **The machine was shared with other workers for the whole session** (load average 1.8 to 4); see "Noise" for what that means for
each number.

## The mechanism (three rules, one cost)

1. **A LANGUAGE sql function is inlined only if its body is one pure expression**: no `FROM` (even `from (select ...) s`), not volatile, not
   `SECURITY DEFINER`, no `SET`, a scalar or `SETOF` result (a function with OUT parameters is never inlined), and no immutable-marked body that calls a
   stable function (`convert_to`, `convert_from` and `jsonb_build_*` are STABLE).
2. **A parameter used more than once in the body is substituted only if the argument is cheap** (a column, a constant, a variable: less than about
   10 operator costs). `proto.frame(id, body)` uses `body` four times (twice per branch) and `proto.varint(n)` uses `n` eight times, and every packet builder passes them a *computed*
   expression, so in practice they were **never inlined where it mattered**. The probe has to test with an expensive argument to see this; testing with a column
   says "inlined" and is wrong for the hot path.
3. **A SQL function that is not inlined is planned again in every statement execution** (its `fcache` is per executor run). 20,000 rows through one statement
   amortise it (5 us per call); the tick runs each statement once or a few times per tick, so every call site pays for planning: about **100 us per `proto.frame`
   call-site statement** in the tick profile. PL/pgSQL caches its plans for the session.

Direct proof of rule 3 (`tests/bench/inline/call_cost.sql` for the per-row view; for the per-statement view, 3,000 separate single-row statements calling
`proto.frame` with a computed argument, timed inside the session, three pairs in alternating order):

| | per 3,000 statements | per statement |
|---|---|---|
| SQL `proto.frame` (not inlined: expensive argument) | 1,545 / 1,570 / 1,319 ms | 440 to 520 us |
| PL/pgSQL `proto.frame` (sql/480) | 498 / 438 / 276 ms | 90 to 165 us |

(Most of the remaining 90 to 165 us is parsing and planning the outer statement itself.) Per call inside one big statement, PL/pgSQL is also cheaper than a
non-inlined SQL function: 0.5 us against 5 us for frame, 0.35 us against 2 us for varint (20,000 calls, floor of the argument expression subtracted).

## The audit

`tools/audit_inlining.py` (+ `tools/audit_inlining.sql`), against any database with the dbcraft schemas:

* classifies every function in `proto`, `mc`, `net`, `ref`: language, volatility, STRICT, SECURITY DEFINER, parallel marking, SET clauses, result shape;
* **proves** inlining for every LANGUAGE sql function by planning a representative call over a real table (no constant folding) and looking for the function's
  own name in `EXPLAIN (VERBOSE, COSTS OFF)`, once with column arguments and once with an expensive argument expression;
* names the likely reason for each function that is not inlined (volatile, FROM clause, OUT parameters, CTE, aggregate, declared IMMUTABLE but calls
  `convert_to` (stable), ...);
* `--hot-stats FILE` ranks what a tick actually calls (`tests/bench/inline/run_funcs.sh` writes the file: `track_functions = all` over the standard tick;
  inlined functions never appear in `pg_stat_user_functions`, so the list is exactly the calls that were not inlined, with calls per tick and self time);
* `tests/bench/inline/explain_ticks.sh FUNC` runs three ticks under `auto_explain` (nested, verbose) and prints the statements whose plan still contains a call
  of FUNC, with context. It does not see PL/pgSQL "simple expressions" (they run without an executor).

Result on the baseline (before sql/480): 281 functions: 117 PL/pgSQL, 93 SQL functions inlined, 64 SQL functions not inlined, 7 not probeable (argument types
such as `inet` or a row type, or variadic). Of the 93 inlined (93 again after sql/480: `mc.pie_add` lost its inlining to the marking change and got it back
with its own fix), **31 inline only with cheap arguments** (measured after sql/480; they use a parameter several times: `proto.i16`, `proto.string`,
`net.frame`, `proto.i32_read` ... `i64_read`, `f64_read`, `proto.frame_small_compressed`, ...).

Why the 64 were not inlined (a function can have several reasons; counts from the audit): a `FROM` clause in the body in **54** of them (every key lookup such
as `mc.prop_int`, `net.pkt`, `mc.state_id`, often together with an aggregate or a volatile call), volatile in **13** (`net.send`, `net.close`, `mc.broadcast`, ...:
they write, so they never could be), OUT parameters in **3** (`proto.varint_read`, `string_read`, `position_read`), a CTE in **3**, and the **wrong marking** in
**4** (`proto.string`, `proto.string_read`, `mc.disconnect_json`, `mc.pie_add`: IMMUTABLE but calling a STABLE function).

## The tick profile that ranks them (500 players, all moving, `run_funcs.sh`)

Called (so not inlined) functions, ms of self time per tick, before:

| function | calls/tick | us/call | ms/tick | why |
|---|---|---|---|---|
| `proto.frame` | 37 | 99.5 | 3.72 | expensive `body` argument; per-statement planning |
| `proto.varint` | 1,002 | 2.8 | 2.80 | expensive argument in the movement statement (`octet_length(CASE ...)`) |
| `mc.pkt_remove_entities` (with its callees) | 10 | 51 (290 incl.) | 2.90 | body has a FROM; its callees were the two above |
| `mc.prop_int` | 4 | 56 | 0.22 | FROM clause |
| `net.pkt` | 2 | 113 | 0.23 | FROM clause |
| `mc.chat_type_id`, `mc.world_ready`, `net.handled_play_ids` | 1 each | 60 to 170 | 0.4 | FROM clause |

The same pattern at 2,000 players: `proto.frame` 277 calls x 72 us = 20 ms, `proto.varint` 4,002 calls = 9.4 ms of a 297 ms tick.

## What sql/480 changes (all byte-identical; `tests/sql/480_inlining.sql`, 20 checks, plus every replay in the suite)

* `proto.varint`, `proto.frame` become PL/pgSQL with the same bodies (the SQL versions stay in sql/315 as the first definition).
* Nine key lookups become PL/pgSQL (`mc.prop`, `prop_int`, `prop_bool`, `net.setting`, `net.pkt`, `net.pkt_name`, `mc.chat_type_id`, `mc.permission_level`,
  `mc.world_ready`). Every key is unique (checked), so a scalar subselect cannot see two rows; STABLE is kept, so they use the caller's snapshot.
* Markings: `proto.string`, `proto.string_read`, `mc.disconnect_json`, `mc.pie_add` IMMUTABLE to STABLE. They call STABLE functions; the old marking was wrong and
  blocked inlining (`proto.string` now inlines). No index, default, generated column, constraint or trigger depends on them (checked in `pg_depend`).

Profile after (same workload): `proto.frame` 160 calls x 0.73 us = 0.18 ms (was 3.72), `proto.varint` 5,064 calls x 0.41 us = 2.06 ms (was 2.80; the call count
rose because the cheap-argument sites that used to inline are now calls, which is why the gain is smaller than for frame), `mc.pkt_remove_entities` total 0.21 ms (was
2.90), `mc.prop_int` 59 to 31 us, `net.pkt` 123 to 42 us, `mc.chat_type_id` 90 to 33 us, `mc.world_ready` 62 to 21 us. Sum of the tracked self times: about 7.7 ms
to 2.6 ms per tick, **about 5 ms of a 40 to 44 ms tick**.

## Does the tick get faster? (honest account of the noise)

* **Clean evidence** (load average 2.0, 7 interleaved rounds, only frame and varint changed): the game phase (moves, visibility, where the call sites are)
  **26.3 ms median (24.5 to 28.9) before, 21.5 ms (20.5 to 22.6) after**: non-overlapping ranges, 4.8 ms. Process, blocks and drain phases unchanged.
  A second run of five rounds at load 3.0 pointed the same way in its quiet rounds (21.4 to 23.2 against 23.9 to 24.4) and was ruined by interference in the rest
  (the baseline database also shows a 43 ms chunk-phase outlier, so those are not caused by the change).
* **The final file against the baseline under saturation was inconclusive**: at load 3.5 to 4 (three other benchmarks running on the 4 CPUs) a tick took 100 to
  430 ms instead of 40, and nine alternating rounds gave a minimum game phase of 70.3 ms for the baseline and 71.5 ms with sql/480. I do not claim anything from that run.
  Re-run `tests/bench/inline/ab_phases.sh DB_A DB_B` on a quiet machine (build both with `createdb -T`, apply `sql/480_inlining.sql` to B).
* **Expected**: about 4 to 5 ms per tick at 500 moving players (10 to 12%), from the profile and the clean A/B together; the per-statement cost saved is real
  and measured (349 us per single-row statement).

## What is not fixed, in priority order

1. **`proto.varint`, still 5,064 calls per tick (2.1 ms)**: the movement statement in `mc.apply_player_moves` (sql/431, 432) builds lengths from nested
   expressions. If those sites bind the length once (a lateral subselect or a column of an earlier CTE) the SQL version would inline there, but then the same
   function cannot be both. Cleaner: a second function `proto.varint_i(n)` kept as SQL for call sites with a column argument, and PL/pgSQL `varint` for the rest.
   Needs edits in files other workers own. Upper bound of the gain: about 1.5 ms per tick.
2. **`mc.chunk_packet/3`, 135 to 156 calls per tick at 14 to 17 us (2.2 ms)**: a PL/pgSQL function called per chunk row in chunk delivery. A set-based join to
   `mc.chunk_cache` would remove the per-row call (world and tick code).
3. **`net.pkt` and `mc.pid`** still cost 40 us per call from PL/pgSQL (an SPI plan per call). They are lookups of constants: fold them like the tick worker's
   `mc.pid` constants (the restart-after-reload caveat in `docs/PERF-TICK.md` applies). Gain about 0.15 ms.
4. **31 functions inline only with cheap arguments.** None of them showed up as a call in the profile, so no action; `sql/INLINE_HOT.txt` pins the ones on
   the hot path. `net.frame` is the one to watch: it inlines only with column arguments.
5. **OUT-parameter readers** (`proto.varint_read`, `string_read`, `position_read`) are never inlined (record result). They are not on the tick profile (the
   movement decode uses `proto.f64_read` etc.). If packet decoding moves into the tick they will show up as per-call executor cost.
6. `mc.canon_state` and `net.tag_member_id` are STABLE but call `proto.bad` (volatile, it raises). Left alone: marking `proto.bad` STABLE would be a lie and
   they are not hot.

## The guard

`tools/check_inlining.sh` migrates a clean database and checks `sql/INLINE_HOT.txt` (22 functions) with `tools/audit_inlining.py --check`; `tests/sql/run.sh`
runs it next to `tools/check_overrides.py` and `tools/check_fresh_migration.sh`. Modes: `plpgsql` (must stay PL/pgSQL: frame and varint), `inline` (inlinable
with column arguments), `inline_any` (also with an expensive argument). Shown to fail: re-creating the SQL `proto.frame` gives `REGRESSED proto.frame/2: is sql,
must be plpgsql`; marking `proto.string` IMMUTABLE again gives `BLOCKED proto.string/1 ... declared IMMUTABLE but calls convert_to (stable)`.

`sql/OVERRIDES.txt` lists the new overrides (35 in all).

## Limits of the tool

The probe uses generic argument shapes, so a function can inline in the probe and not at one particular call site (an argument that is volatile, or contains a
subplan, is never substituted several times); the profile (`run_funcs.sh`, `explain_ticks.sh`) is what finds those. Seven functions have argument types the probe
cannot build. `track_functions` shows only functions that were called, not inlining decisions.

## Noise

Two other workers were running benchmarks for the whole session (load average 1.8 to 4 on 4 CPUs). Wall-clock numbers inherit that; the per-function
profiles (calls and per-call time) and the per-statement microbenchmark are less affected and agree with each other. Everything above that rests on a wall-clock
A/B says so.

## Files

`tools/audit_inlining.py`, `tools/audit_inlining.sql`, `tools/check_inlining.sh`, `sql/480_inlining.sql`, `sql/INLINE_HOT.txt`, `sql/OVERRIDES.txt` (updated),
`tests/sql/480_inlining.sql`, `tests/sql/run.sh` (guard wired in), `tests/bench/inline/` (`run_funcs.sh`, `explain_ticks.sh`, `ab_phases.sh`, `call_cost.sql`).
