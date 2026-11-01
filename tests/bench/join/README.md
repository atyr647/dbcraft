# Login storm benchmarks

Everything runs inside the database: each `jbench.run_tick()` call is one statement, one transaction, like one gateway tick.  Clients are simulated by inserting the five
login packets of each connection (handshake, hello, login_acknowledged, select_known_packs, finish_configuration) into `net.inbox`, then `mc.server_tick()` runs and
`net.drain_outbox()` is read the way the gateway would.  Results and what they mean: `docs/PERF-JOIN.md`.

| File | What it is |
|---|---|
| `storm.sql`, `storm_extra.sql` | the `jbench` schema: `reset`, `feed`, `run_tick`, `reconnect_tick`, `digest`, `tick_digest` |
| `ab.py` | timing of storms on several databases, **interleaved**, median of N: `ab.py --dbs jb_base,jb_new --reps 3 --scen 200:0:1 500:500:5` (joiners:online:ticks); `--setting key=value` for a run |
| `other.py` | reconnect storms (old connections open / closed), idle ticks, steady churn (5 leave and 5 join every tick) |
| `identity.sh` | runs the same storms on two databases and compares what every connection received (md5 of its bytes, the random session id masked): the proof that a change does not alter a byte |
| `cliff.py` | hunts the occasional pathological storm: repeats a storm with `auto_explain` (nested statements) and stops at the first run slower than a limit; the plans are in the server log |
| `rejected/` | two changes that were byte-identical and tested but did not help: not shipped, kept with the reason |

## Setting up the two databases an A/B needs

```
tests/e2e/setup.sh                       # a full dbcraft database (use DBCRAFT_PGDATA / DBCRAFT_PGPORT for your own cluster; never the e2e one if someone else is testing)
createdb -T dbcraft jb_base              # the code as it was
createdb -T dbcraft jb_new               # then apply the new files to it:  for f in sql/46*.sql; do psql -d jb_new -f $f; done
for db in jb_base jb_new; do psql -d $db -f tests/bench/join/storm.sql -f tests/bench/join/storm_extra.sql; done
python3 tests/bench/join/ab.py --reps 3 --scen 50:0:1 200:0:1
tests/bench/join/identity.sh jb_base jb_new
```
(PGHOST/PGPORT/PGUSER as for psql; the scripts default to `/tmp`, 54466, `postgres`.)

## Pitfalls found while measuring (each cost a wrong number once)

* Settings persist in the database: a run with `--setting network-compression-threshold=256` left every later run compressed.  `jbench.reset()` now resets it.
* A `generate_series` whose arguments do not depend on the outer row is evaluated once and reused for every row (random lengths came out constant).
* A micro-benchmark that passes `gen_random_uuid()` as an argument stops the planner from inlining the function it calls: it measured the benchmark, not the server.
* `track_functions = 'all'` also stops SQL functions from being inlined; use `'pl'`.
* Function-level times from `pg_stat_user_functions` are totals: divide by the number of joins, not by the number of calls.
* Statistics: autovacuum/analyze right after `truncate` records tables as empty (see `cliff.py` and `sql/465_join_visibility.sql`).
