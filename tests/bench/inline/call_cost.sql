-- Cost of a call that the planner cannot inline (the argument is an expensive expression used several times in the body), per implementation.
-- psql -X -q -f tests/bench/inline/call_cost.sql  (any database that has the proto schema; creates and drops schema inl_exp)
\set ON_ERROR_STOP on
\timing off
drop schema if exists inl_exp cascade;
create schema inl_exp;
create table inl_exp.t as select g as i, decode(md5(g::text) || md5((g + 1)::text), 'hex') as b from generate_series(1, 20000) g;
analyze inl_exp.t;

-- the same function bodies as proto.frame / proto.varint (sql/315_game_fast.sql), as SQL and as PL/pgSQL
create function inl_exp.frame_sql(packet_id int, body bytea) returns bytea language sql immutable parallel safe as $$
  select proto.frame(packet_id, body) $$;     -- a wrapper only to give the planner a function that exists in both forms
create function inl_exp.frame_plpgsql(packet_id int, body bytea) returns bytea language plpgsql immutable parallel safe as $$
begin
  return case when packet_id >= 0 and packet_id < 128 then proto.varint(octet_length(body) + 1) || set_byte('\x00'::bytea, 0, packet_id) || body
              else proto.varint(octet_length(proto.varint_slow(packet_id)) + octet_length(body)) || proto.varint_slow(packet_id) || body end;
end $$;
create function inl_exp.varint_plpgsql(n int) returns bytea language plpgsql immutable parallel safe as $$
begin
  return case when n >= 0 and n < 128 then set_byte('\x00'::bytea, 0, n)
              when n >= 0 and n < 16384 then set_byte(set_byte('\x0000'::bytea, 0, ((n & 127) | 128)), 1, (n >> 7))
              else proto.varint_slow(n) end;
end $$;

create or replace function inl_exp.bench(label text, q text, reps int default 7) returns void language plpgsql as $$
declare t0 timestamptz; ms float8[] := '{}'; i int; dummy bigint;
begin
  for i in 1 .. reps loop
    t0 := clock_timestamp(); execute q into dummy; ms := ms || (extract(epoch from clock_timestamp() - t0) * 1000);
  end loop;
  raise notice '% : median % ms per 20000 calls (min % max %)', rpad(label, 52), round((select percentile_cont(.5) within group (order by x) from unnest(ms) x)::numeric, 2),
               round((select min(x) from unnest(ms) x)::numeric, 2), round((select max(x) from unnest(ms) x)::numeric, 2);
end $$;

-- an argument that is expensive (> 10 operator costs) and so cannot be copied into a body that uses it several times
\set EXP '(b || b || b || b || b || b || b || b || b || b || b || b)'
\set CHEAP 'b'
select inl_exp.bench('frame: inlined  (cheap arg, baseline)', 'select sum(octet_length(proto.frame(i % 100, b))) from inl_exp.t');
select inl_exp.bench('frame: proto.frame, EXPENSIVE arg (not inlined)', 'select sum(octet_length(proto.frame(i % 100, ' || :'EXP' || '))) from inl_exp.t');
select inl_exp.bench('frame: plpgsql version, EXPENSIVE arg', 'select sum(octet_length(inl_exp.frame_plpgsql(i % 100, ' || :'EXP' || '))) from inl_exp.t');
select inl_exp.bench('frame: only the argument expression (floor)', 'select sum(octet_length(' || :'EXP' || ')) from inl_exp.t');
select inl_exp.bench('varint: proto.varint, cheap arg (inlined)', 'select sum(octet_length(proto.varint(i % 20000))) from inl_exp.t');
select inl_exp.bench('varint: proto.varint, EXPENSIVE arg', 'select sum(octet_length(proto.varint(octet_length(' || :'EXP' || ') + (i % 3)))) from inl_exp.t');
select inl_exp.bench('varint: plpgsql version, EXPENSIVE arg', 'select sum(octet_length(inl_exp.varint_plpgsql(octet_length(' || :'EXP' || ') + (i % 3)))) from inl_exp.t');
select inl_exp.bench('varint: floor (argument only)', 'select sum(octet_length(' || :'EXP' || ') + (i % 3)) from inl_exp.t');
drop schema inl_exp cascade;
