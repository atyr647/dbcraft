-- Inlining audit fixes (docs/PERF-INLINE.md; tools/audit_inlining.py found them, tests/bench/inline/ measured them).  Applied late on purpose: every function
-- here replaces an earlier definition, byte-for-byte the same result, and is listed in sql/OVERRIDES.txt.
--
-- Three findings:
--  1. A LANGUAGE sql function whose body uses a parameter several times is inlined only when the argument is cheap (a column, a constant, a variable).  Every
--     packet builder passes proto.frame / proto.varint a COMPUTED expression, so those calls were never inlined, and a non-inlined SQL function pays for
--     parsing and planning its body again in every statement execution (about 100 us per statement for proto.frame, 2.8 us per call for proto.varint).
--     As PL/pgSQL the plan is cached for the session: 0.8 us and 0.4 us.  The few call sites with cheap arguments lose their inlining (about 0.4 us per call).
--  2. A scalar SQL function with a FROM clause is never inlined (net.pkt, mc.prop_int ... are lookups) and costs 55-120 us per statement for the same reason.
--  3. IMMUTABLE on a function that calls a STABLE one (convert_to / convert_from, jsonb_build_*) is wrong, and it also blocks inlining.

------------------------------------------------------------------------------------------------ 1. the codec: cached plans instead of per-statement planning
create or replace function proto.varint(n int) returns bytea language plpgsql immutable parallel safe as $$
begin
  return case when n >= 0 and n < 128 then set_byte('\x00'::bytea, 0, n)
              when n >= 0 and n < 16384 then set_byte(set_byte('\x0000'::bytea, 0, (n & 127) | 128), 1, n >> 7)
              else proto.varint_slow(n) end;
end $$;

create or replace function proto.frame(packet_id int, body bytea) returns bytea language plpgsql immutable parallel safe as $$
begin
  return case when packet_id >= 0 and packet_id < 128 then proto.varint(octet_length(body) + 1) || set_byte('\x00'::bytea, 0, packet_id) || body
              else proto.varint(octet_length(proto.varint_slow(packet_id)) + octet_length(body)) || proto.varint_slow(packet_id) || body end;
end $$;

------------------------------------------------------------------------------------------------ 2. key lookups (every key is unique, so a scalar subselect cannot see two rows)
create or replace function mc.prop(k text) returns text language plpgsql stable parallel safe as $$
begin return (select value from mc.server_property where key = k); end $$;
create or replace function mc.prop_int(k text) returns int language plpgsql stable parallel safe as $$
begin return (select value::int from mc.server_property where key = k); end $$;
create or replace function mc.prop_bool(k text) returns boolean language plpgsql stable parallel safe as $$
begin return (select value::boolean from mc.server_property where key = k); end $$;
create or replace function net.setting(k text) returns text language plpgsql stable as $$
begin return (select value from net.setting where key = k); end $$;
create or replace function net.pkt(st text, dir text, nm text) returns int language plpgsql stable as $$
begin
  return coalesce((select protocol_id from ref.packet where state = st and direction = dir and name = nm),
                  proto.bad('unknown packet ' || st || '/' || dir || '/' || nm)::int);
end $$;
create or replace function net.pkt_name(st text, dir text, id int) returns text language plpgsql stable as $$
begin return (select name from ref.packet where state = st and direction = dir and protocol_id = id); end $$;
create or replace function mc.chat_type_id(n text) returns int language plpgsql stable parallel safe as $$
begin return (select id from mc.chat_type where name = n); end $$;
create or replace function mc.permission_level(p_uuid uuid) returns int language plpgsql stable parallel safe as $$
begin return coalesce((select level from mc.op where uuid = p_uuid), 0); end $$;
create or replace function mc.world_ready() returns boolean language plpgsql stable as $$
begin return exists (select 1 from mc.biome) and exists (select 1 from mc.dimension_type); end $$;

------------------------------------------------------------------------------------------------ 3. volatility markings that were wrong
-- convert_to / convert_from depend on the encoding conversion tables, so Postgres marks them STABLE; a function that calls them cannot be IMMUTABLE.
-- (A UTF-8 database gives the same bytes every time, which is why nothing broke, but the marking also blocked inlining.)
alter function proto.string(text) stable;
alter function mc.disconnect_json(text, text[], text[]) stable;
alter function mc.pie_add(uuid, text, integer, boolean, integer, integer, boolean) stable;   -- calls proto.string (stable now)
alter function proto.string_read(bytea, integer) stable;   -- calls convert_from (stable); also has OUT parameters, so it is never inlined as a scalar
