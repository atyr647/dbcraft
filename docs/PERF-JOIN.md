# Login storms: what they cost, and how far the login path got faster

Question: what does it cost when many players log in at the same time (a restart, a popular moment), and how far can the login path be sped up **without changing a byte**?
Everything here ran inside the database (`tests/bench/join/`, see its README), through `net.inbox` -> `mc.server_tick()` -> `net.drain_outbox()`, on the shared 4-CPU development
container with the load average between 2 and 7 for the whole session (other workers were running).  Every comparison is **interleaved** (baseline database and new database
alternate, so drift hits both) and reported as the median of 3 runs; the min-max range is given where it matters.  Treat differences under about 15% as noise.

**Byte identity.**  `tests/bench/join/identity.sh` runs the same storms (into an empty server, into a populated one, spread over ticks, an idle tick, a duplicate login, a
reconnect after disconnect) on the baseline and on the new database and compares what every connection received (md5 of its bytes, the random session id in `login_finished`
masked): **380 connection digests, identical**.  A negative control (a changed brand setting) makes it report DIFFERENT.  The suite (`tests/sql/run.sh`) passes with 1,072 checks
including the replays that compare the join bursts with recorded vanilla traffic.  `tests/e2e` was not run here (fixed ports; the parent runs it).

## Result

Storm of N players logging in during one tick (and over five ticks), view distance 2, chunks already generated and cached, compression off.
"Connection layer" is `net.process_fast` (login checks, configuration burst, entry burst, `mc.on_join`, chunk batch); "tick" is the whole `mc.server_tick()`.

Measured at load average 10-11 (other workers' Java clients and test runs), baseline and new interleaved, median of 3; the 500-joiner baseline rows are from an earlier battery at load about 3.

| Scenario | Baseline | New | Speed-up |
|---|---|---|---|
| 50 joiners, 1 tick, empty server | 30.0 ms/join (tick 1.50 s, connection layer 1.46 s) | 12.1 ms/join (0.61 s, 0.56 s) | 2.5x |
| 200 joiners, 1 tick, empty | 34.8 ms/join (6.95 s, 6.32 s) | 17.9 ms/join (3.58 s, 2.75 s) | 1.9x (connection layer 2.3x) |
| 100 joiners into 250 online | 50.8 ms/join (5.08 s, 3.96 s) | 21.8 ms/join (2.18 s, 1.11 s) | 2.3x (connection layer 3.6x) |
| 500 joiners, 1 tick, empty | **25.5 s, 428 s, 429 s** (three runs; connection layer 94 s median) | **12.5 s** (12.1-12.6 s; connection layer 7.3 s) | 2.0x against the best baseline run; the two 428 s runs are the visibility cliff below |
| 500 joiners over 5 ticks, empty | 22.8 s (connection layer 18.4 s) | 12.2 s (6.4 s) | 1.9x (2.9x) |
| 500 joiners into 500 online, 1 tick | not measured (the baseline would take over an hour) | 25.7 s (connection layer 8.3 s, drain 2.4 s, gateway drain 6.5 s) | |
| 500 joiners into 500 online, 5 ticks | not measured | 30.1 s (connection layer 9.7 s) | |

Per phase for a join (150-250 joiners, new code, ms per join): `mc.on_join` 2.4-3.0, chunk batch (`send_chunks` + `hook_chunks`) 2.5-3.0, entry burst 1.0-1.4, configuration burst 0.6-0.8, tab list 0.4-0.6, login checks 0.4, handler glue 0.4;
the rest of the tick (visibility for everybody who can see the joiners, drain) is outside the connection layer.  Bytes per joiner: 0.66 MB (329 MB / 501): configuration 216,662 bytes, chunks about 350 KB, the rest the entry burst;
into 500 online it is 0.87 MB because every online player is sent a join message and a tab entry per joiner and every joiner the whole tab list.  WAL for 500 joiners: 1,104 KB baseline, 596-734 KB new.
**Deviations from vanilla's bytes: none** (nothing was batched, dropped or reordered).

**Targets from the brief**

| Target | Result |
|---|---|
| 500 joins in one tick <= 1.5 s | **not met**: the connection layer takes 7.3 s (5.7 s on a quieter run) and the whole tick 12.5 s for 500 joiners in one tick, 5-8x over the target.  What is left per join is about 3 ms chunk copying (another worker's reference outbox), 2.4 ms `mc.on_join`, then many small pieces; only a set-based multi-joiner path could approach 3 ms per join (not attempted, see below) |
| configuration burst <= 0.3 ms per joiner | **not met**: 0.6-0.7 ms per joiner uncompressed (216,662 bytes copied into the outbox); **met for a compressed connection**: 0.49 ms -> see below, the cached burst is 37,988 bytes |
| joiner-to-existing-players broadcast not quadratic in bytes beyond what vanilla does | **met by construction**: nothing was batched or dropped, the bytes are identical, so the quadratic part is vanilla's own (every online player is sent one join message and one tab entry per joiner, every joiner is sent the whole tab list: 500 into 500 online is 437 MB against 329 MB into an empty server) |

## Where a join went (baseline, one join, 50 joiners into an empty server)

Profile with `track_functions = 'pl'`, totals divided by the number of joins.  The original code, per join:

| Step | ms per join |
|---|---|
| everything in `net.handle` (5 packets) | 31 |
| `finish_configuration` -> `net.play_begin` | 18.0 |
| ...of which `net.hook_join_info` (`mc.on_join` 5.0) | 5.9 |
| ...of which `net.send_chunks` (49 cached chunk packets, 0.35 MB) | 5.4 |
| ...of which `net.play_entry_packets` (the 27-packet burst) | 3.9 |
| `select_known_packs` -> `net.send_config_data` (33 packets, 216 KB) | 3.6 |
| `login_acknowledged` -> `net.config_begin` (3 packets) | 2.7 |
| `hello` -> `net.h_login` | 2.0 |
| `handshake` -> `net.h_handshake` | 1.0 |

and in isolation (a connection among about 300 online): `net.send` 603 us per call, `proto.varint_read` 158 us, `proto.string_read` 208 us, `net.player_info_body` 3.1 ms for 400 entries.
Those four are why a handshake (one UPDATE and four decoder calls) cost 1.5 ms.

## What was changed (each byte-identical)

| Round | File | Change | Evidence |
|---|---|---|---|
| 1 | `sql/460_join_codec.sql` | `proto.varint_read`, `proto.string_read`, `net.send` (both), `net.close`, `net.need`, `net.on_connect` as PL/pgSQL.  A `language sql` function Postgres cannot inline (CTEs, OUT parameters, DML, void result) is **planned again on every call** from PL/pgSQL | `varint_read` 158 -> 3.4 us, `string_read` 208 -> about 6 us, `net.send` 603 -> 15 us.  `tests/sql/460`: 40,000 random and malformed varint buffers and 20,000 strings give the same value or the same error as the originals |
| 2 | `sql/461_join_on_join.sql` | `mc.on_join` builds each broadcast packet once (a MATERIALIZED CTE: a stable function with a PL/pgSQL variable argument is not hoisted otherwise) and `net.hook_join_info` asks it not to build the joiner's own rows, which it deleted right afterwards.  **That delete was `DELETE FROM mc.play_out WHERE seq > $1 AND conn_id = $2` on a table with no index at all**, so every join scanned the whole queue: quadratic in the storm size | `mc.on_join` 17.7 -> 2.2 ms per join at 100 online; `hook_join_info` own time 32 ms -> 0.3 ms per join at 600 online.  `tests/sql/461` compares the rows other players receive with the original's, for a plain join and a duplicate login |
| 3 | `sql/462_join_config_burst.sql` | the configuration burst (32 `registry_data` + `update_tags`) is one cached, pre-framed row per (known packs, compression threshold, deflate implementation) in `net.config_burst` (a cache: unlogged, rebuilt on first use, emptied by the existing triggers through `net.config_cache`, also on TRUNCATE, keyed by the active deflate implementation); `net.outbox.data` is `STORAGE EXTERNAL` (Postgres was trying to pglz-compress every large row: 2.2 of the 3.6 ms) | 3.6 -> 0.6-0.7 ms per joiner uncompressed; **10.0 -> 0.49 ms with compression threshold 256** (the 33 packets were deflated again for every joiner; the burst is 37,988 bytes against 216,662).  `tests/sql/462`: byte-equal to per-packet framing at thresholds -1, 256 and 1, invalidation on delete/truncate/edit, implementation switch |
| 4 | `sql/463_join_plans.sql` | `net.play_entry_packets` plans once (`plan_cache_mode = force_generic_plan`, function level).  Its statement is one VALUES of about 30 inlined helpers: planning alone was about 2 ms | 3.0 -> 1.0-1.8 ms per call |
| 5 | `sql/464_join_constants.sql` | the tab-list entry head (uuid + name) is cached per connection in `net.conn_tab` (a cache kept by a trigger, outside `net.conn` which is updated every tick); `net.player_info_body` is PL/pgSQL; the three packets that start the configuration phase are one cached row per threshold (`net.config_begin_cache`, emptied when `net.setting` changes) | `player_info_body` 5.5 -> 2.3 us per entry (3.3 -> 1.4 ms for 600 players); `config_begin` 0.84 -> 0.13 ms.  `tests/sql/464` compares with the original on random connections incl. missing uuid/name and connections the trigger never saw |
| 6 | `sql/465_join_visibility.sql` | `mc.refresh_visibility` records new pairs with `INSERT ... ON CONFLICT DO NOTHING` instead of `NOT EXISTS` against the table it inserts into | see "The cliff" |

## The cliff: a storm that takes 6 minutes instead of 10 seconds

`tests/bench/join/cliff.py` repeats a 500-joiner storm with `auto_explain` (nested statements) and stops at the first slow run.  Run 5 took **362 s** while the connection layer took the normal 7 s.
The slow statement, in `mc.refresh_visibility` (game tick, called every tick):

```
insert into mc.visible ... select ... from w where not exists (select 1 from mc.visible v where v.viewer_eid = w.viewer_eid and v.target_eid = w.target_eid)
  Nested Loop Anti Join  (actual rows=250500)
    -> Function Scan on w (actual rows=250500)
    -> Seq Scan on visible v (cost=0.00..0.00 rows=1) (actual rows=0 loops=250500)
```

`mc.visible` has a primary key on the pair, but autovacuum/autoanalyze had just recorded the table as **empty** (it does that on a quiet server, or right after a restart), so a sequential scan of 0 pages looked free.
The statement inserts 250,500 rows into that very table and every one of the 250,500 inner scans reads all the pages inserted so far: quadratic, 349 s.  The original code had the same statement:
the baseline's 500-joiner storm took 25.5 s, 428 s and 429 s in three runs (the first battery), and 5.2 minutes for one of three runs of the new code before the fix.
This is exactly the case that matters: a server restarts and 500 players reconnect in one tick.

`ON CONFLICT (viewer_eid, target_eid) DO NOTHING` uses the primary key whatever the statistics say and skips existing pairs as `NOT EXISTS` did (the pairs in `w` come from a UNION, so they are unique).
Reproduction in `tests/sql/465_join_visibility.sql`: statistics poisoned with `TRUNCATE` + `ANALYZE`, 400 players at one spot: **original 119.6 s, new 2.6 s**; and the same result as the original on a join / move / disconnect scenario (6 digests).
After the fix `cliff.py` ran 10 storms with no slow run, including runs where autoanalyze had recorded `mc.player` as one row.

## Compression

With the compression threshold at 256 the configuration burst is **37,988 bytes instead of 216,662** (native deflate; 5.7x), built once per (variant, threshold, implementation) and cached; a whole join is about 56 KB instead of 560 KB.

Measured with rounds 1-5 installed, threshold 256, native deflate (baseline -> new): 50 joiners 3.39 s -> 1.06 s (67.7 -> 21.3 ms per join; bytes 28 MB -> 3 MB), 100 joiners 10.4 s -> 2.6 s (104 -> 26 ms per join).
The configuration step alone: 10.0 ms -> 0.49 ms per joiner.  What dominates a compressed storm afterwards is the drain, which re-frames and deflates every game frame: 500 joiners at threshold 256 took 34.5 s, of which 21.1 s drain and 9.7 s connection layer (68 MB sent).
That is `net.reframe` deflating per frame (chunk and native-deflate owners), not the login path.

## Reconnect storms, idle players, churn (300 online, 100 reconnecting)

| Scenario (300 online, 100 reconnecting) | Baseline | New |
|---|---|---|
| reconnect with the old connections still open (duplicate login) | 24.9 s | 20.0 s |
| reconnect after the old connections closed | 7.7 s | 3.1 s |
| idle tick, 300 online | 5.9 ms | 6.5 ms (within noise; nothing on the idle path calls changed code; consistently 0.2-0.5 ms higher in four runs, cause not found) |
| churn: 5 leave and 5 join every tick, 20 ticks | 405 ms per tick | 182 ms per tick |

The duplicate-login case is dominated by `mc.on_leave` (game module, unchanged): 14.4 s for 100 calls in the baseline, 144 ms each at 300 online.  My cause is only a suspicion (it scans and deletes in the unindexed-by-OR `mc.visible`
for every leaver, and builds the leave message per recipient like `on_join` did); I did not trace it.  Round 4 first made it worse (24.5 s) until the setting was removed from `net.handle`.

## Tried and not adopted

* **Text component builders** (`proto.mutf8` ASCII fast path; `nbt_text`, `cat`, `nbt_int_array`, `nbt_list_str`, `nbt_list_comp`, `nbt.str` inlinable or PL/pgSQL), byte-identical and tested, **no measurable effect on a join**
  (200 joiners: 13.01 ms per join without them, 13.62 with, 12.86 on the database that had them for a day; building the join message with variables went 233 -> 126 us, under 1% of a join).  A micro-benchmark with
  `gen_random_uuid()` as an argument had shown 2 ms: a volatile argument used several times stops the planner inlining the function, so it measured the benchmark.  Kept in `tests/bench/join/rejected/` with the technique used to test them (run the ORIGINAL source files again as the reference).
* **`plan_cache_mode = force_generic_plan` on `net.handle`** (the first version of round 4): about 10 ms faster per 100 joins, but the setting is inherited by everything the handler calls, and `mc.on_leave` got generic plans that are bad for it:
  100 duplicate-login leaves took **24.5 s instead of 14.0 s**.  Found by profiling the reconnect scenario; the structural check `tools/check_fresh_migration.sh` now fails if the setting returns.
* **Not attempted**: a set-based path that handles all joiners of a tick in a few statements (entry burst for many joiners in one statement, login checks as one pass, one coalesced broadcast row per recipient per tick).  It is the only way to approach 3 ms per join, but capacity checks (`server full`) depend on the order in which joiners complete within the tick,
  the duplicate-login kick interleaves with the broadcast, and every ordering has to stay byte-identical; I judged the risk too high for the time available.  Tab-list batching ("one `player_info_update` for all players that joined this tick") was therefore not needed and not done: **there is no deviation from vanilla's bytes anywhere in this work.**

## What remains (and who owns it)

* **Chunk copying**: about 3 ms per join (49 cached packets, 0.35 MB, copied into the joiner's outbox rows).  A reference-based outbox is the lever (the batched-pipeline worker's variant 8).
* **`mc.on_join`** 2.4-3.0 ms per join: two inserts of one row per online player per joiner (coalescing them per recipient per tick preserves the bytes but must interleave correctly with leaves and duplicate logins) plus its fixed statements.
* **`mc.on_leave`**: 144 ms per call at 300 online (see above): the biggest single cost of reconnect storms and churn; game module.
* **Visibility** for a crowd at one spot is inherently quadratic (500 joiners into 500: 250,000 `add_entity` pairs, vanilla does the same) and not part of the connection layer.
* **Compressed storms** are drain-bound (21 s of 34.5 s for 500 joiners): `net.reframe` deflates per frame.
* **The set-based multi-joiner path** (not attempted, see above) is the only route to about 3 ms per join.
* **The batched tick (`mc.server_tick_batched`, sql/380-389)**: see the merge note below.

## Files

* `sql/460`-`465` (migration), `sql/OVERRIDES.txt` (every redefined function with the reason), `tools/check_fresh_migration.sh` (structural checks of a clean migration), `tools/check_overrides.py`
* `tests/sql/460`, `461`, `462`, `464`, `465`; `tests/sql/140`, `410`, `420`, `430` adjusted (they re-include `sql/400`, which reinstalls the original hooks, so they now re-include 460-462 after it)
* `tests/bench/join/`: harness, `ab.py`, `other.py`, `identity.sh`, `cliff.py`, README (with the pitfalls that each cost a wrong number once), `rejected/`
