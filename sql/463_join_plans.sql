-- Login-path speed, round 4: plan the entry-burst builder once.
--
-- Measured (docs/PERF-JOIN.md): with the default plan_cache_mode, PL/pgSQL keeps re-planning a statement as long as its custom plans look cheaper than the generic one, and the
-- 27-packet entry burst is one VALUES of about 30 inlined SQL helpers whose planning alone costs about 2 ms: net.play_entry_packets took 3.0 ms per call, 1.0-1.8 ms with a
-- generic plan.  The statement's best plan does not depend on the parameter values, so a function-level SET is metadata only: no body changes, no byte changes.
--
-- Deliberately NOT set on the per-packet handler net.handle (that was the first version of this file, and it measured 10 ms faster per 100 joins on the join path):
-- the setting is inherited by everything the handler calls, and mc.on_leave (called for every leave and every duplicate login) got generic plans that are bad for it:
-- 100 leaves took 24.5 s instead of 14.0 s.  A setting on a leaf function only applies inside that function.
alter function net.handle(bigint, bytea) reset plan_cache_mode;       -- a no-op on a fresh migration; removes the first version of this file where it was applied
alter function net.play_entry_packets(bigint, net.join_info) set plan_cache_mode = force_generic_plan;
