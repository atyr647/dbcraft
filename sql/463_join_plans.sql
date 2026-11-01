-- Login-path speed, round 4: plan the join path once.
--
-- Measured (docs/PERF-JOIN.md): with the default plan_cache_mode, PL/pgSQL re-plans a statement for every call as long as its custom plans look cheaper than the generic
-- one; the big statements of the join path (the 27-packet entry burst is one VALUES of about 30 inlined SQL helpers, planning alone about 2 ms) stayed on custom plans:
-- net.play_entry_packets 3.0 ms per call, 1.0-1.8 ms with a generic plan.  Setting plan_cache_mode on the per-packet handler applies to everything it calls
-- (the login, configuration, play-begin and join functions, mc.on_join, the hooks), and a function-level SET is metadata: no body changes, no byte changes.
-- The statements on this path are key lookups and inserts whose best plan does not depend on the parameter values.
alter function net.handle(bigint, bytea) set plan_cache_mode = force_generic_plan;
