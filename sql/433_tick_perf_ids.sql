-- Tick performance, part 4: reference ids as plan-time constants.  See docs/PERF-TICK.md.
--
-- Packet ids and the entity-type id never change once the reference data (tools/load_reports.py) is loaded, but they were looked up with a table query every time
-- a function started (44 lookups per tick: 1.4 ms to run and 1.2 ms to plan), and one of them sat inside the body of mc.pkt_add_player_entity, whose subquery
-- stopped the planner from inlining proto.frame into it: every new visible pair then cost a separate, freshly planned function call (34 per tick, 86 us of
-- planning each).
--
-- The functions are now IMMUTABLE and not inlinable (PL/pgSQL): called with constant arguments, the planner runs them once while planning and puts the number
-- into the plan, which PL/pgSQL caches.  Consequence, stated plainly: a session keeps the ids it planned with.  After reloading ref.packet or ref.registry
-- (a new Minecraft version), restart the gateway / reconnect the sessions that tick (a fresh database, as in the tests and tools/migrate.sh, is unaffected).

create or replace function mc.pid(pname text) returns int language plpgsql immutable parallel safe as $$
declare v int;
begin
  select protocol_id into v from ref.packet where state = 'play' and direction = 'clientbound' and name = 'minecraft:' || pname;
  return v;
end $$;

create or replace function mc.sid(pname text) returns int language plpgsql immutable parallel safe as $$
declare v int;
begin
  select protocol_id into v from ref.packet where state = 'play' and direction = 'serverbound' and name = 'minecraft:' || pname;
  return v;
end $$;

create or replace function mc.entity_type_id(tname text) returns int language plpgsql immutable parallel safe as $$
declare v int;
begin
  select protocol_id into v from ref.registry where registry = 'minecraft:entity_type' and name = tname;
  return v;
end $$;
