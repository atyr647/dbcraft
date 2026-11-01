-- Empirical inlining probe.  Run with tools/audit_inlining.py (or: psql -X -q -At -F $'\t' -f tools/audit_inlining.sql).
-- For every LANGUAGE sql function in proto, mc, net and ref it plans a representative call over a real table (so nothing is constant-folded)
-- and looks for the function's own name in EXPLAIN (VERBOSE, COSTS OFF): if the name is still there, the planner did NOT inline it.
-- Output (tab separated): oid, schema.name, argument count, status, detail
--   status: inlined | not_inlined | untestable | error
-- Everything lives in pg_temp, so the database is not modified.
create temp table _aa (i4 int, i8 bigint, i2 smallint, by bytea, tx text, bo boolean, f8 float8, f4 real, uu uuid,
                       ai int[], ai8 bigint[], atx text[], aby bytea[], jb jsonb, nu numeric, tz timestamptz, ob oid);
insert into _aa values
  (3, 70000000000, 5, '\x0102030405060708090a0b0c0d0e0f10', 'minecraft:stone', true, 1.5, 2.5, 'b50ad385-829d-3141-a216-7e7d7539ba7f',
   array[1,2,3], array[1::bigint,2], array['a','b'], array['\x01'::bytea, '\x02'::bytea], '{"a":1}', 12.5, now(), 1),
  (4, 80000000000, 6, '\xffeeddccbbaa99887766554433221100', 'minecraft:dirt', false, -1.5, -2.5, 'b50ad385-829d-3141-a216-7e7d7539ba80',
   array[4,5,6], array[3::bigint,4], array['c','d'], array['\x03'::bytea, '\x04'::bytea], '{"b":2}', -3.5, now(), 2);

create function pg_temp.audit_inline() returns table(fn_oid oid, fn text, nargs int, status text, detail text, expensive text) language plpgsql as $$
declare r record; q text; args text; xargs text; plan_txt text; line text; col text; bad text; nm text; qname text; xq text; xplan text; k int;
begin
  for r in
    select p.oid, n.nspname, p.proname, p.pronargs, p.proretset, p.provariadic, p.proargtypes::oid[] as argtypes
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace join pg_language l on l.oid = p.prolang
     where n.nspname in ('proto', 'mc', 'net', 'ref') and l.lanname = 'sql' and p.prokind = 'f'
     order by n.nspname, p.proname, p.oid
  loop
    fn_oid := r.oid; fn := r.nspname || '.' || r.proname; nargs := r.pronargs; detail := null; expensive := null;
    qname := quote_ident(r.nspname) || '.' || quote_ident(r.proname);
    if r.provariadic <> 0 then status := 'untestable'; detail := 'variadic'; return next; continue; end if;
    args := ''; xargs := ''; bad := null;
    for i in 1 .. r.pronargs loop
      col := case format_type(r.argtypes[i - 1], null)
               when 'integer' then 'i4' when 'bigint' then 'i8' when 'smallint' then 'i2' when 'bytea' then 'by' when 'text' then 'tx'
               when 'boolean' then 'bo' when 'double precision' then 'f8' when 'real' then 'f4' when 'uuid' then 'uu'
               when 'integer[]' then 'ai' when 'bigint[]' then 'ai8' when 'text[]' then 'atx' when 'bytea[]' then 'aby'
               when 'jsonb' then 'jb' when 'numeric' then 'nu' when 'timestamp with time zone' then 'tz' when 'oid' then 'ob'
               else null end;
      if col is null then bad := format_type(r.argtypes[i - 1], null); exit; end if;
      args := args || case when i > 1 then ', ' else '' end || 'a.' || col;
      -- the same argument as an EXPENSIVE expression (more than 10 operator costs): a parameter used several times in the body is not substituted by it
      xargs := xargs || case when i > 1 then ', ' else '' end ||
        case when col in ('i4', 'i8', 'i2', 'f8', 'f4', 'nu') then '(' || repeat('a.' || col || ' + ', 14) || 'a.' || col || ')'
             when col in ('by', 'tx', 'ai', 'ai8', 'atx', 'aby', 'jb') then '(' || repeat('a.' || col || ' || ', 14) || 'a.' || col || ')'
             when col = 'bo' then '(' || repeat('a.bo and ', 14) || 'a.bo)'
             else 'a.' || col end;
    end loop;
    if bad is not null then status := 'untestable'; detail := 'argument type ' || bad; return next; continue; end if;
    if r.proretset then q := format('select f.* from _aa a, lateral %s(%s) f', qname, args);
    else q := format('select %s(%s) from _aa a', qname, args); end if;
    plan_txt := '';
    begin
      for line in execute 'explain (verbose, costs off) ' || q loop plan_txt := plan_txt || line || E'\n'; end loop;
    exception when others then
      status := 'error'; detail := sqlerrm; return next; continue;
    end;
    -- the plan names the function (verbose output: "proto.varint(a.i4)", or "Function Scan on varint") when it was not inlined
    if position(r.nspname || '.' || r.proname || '(' in plan_txt) > 0 or position('Function Scan on ' || r.proname in plan_txt) > 0
       or position('Function Scan on ' || r.nspname || '.' || r.proname in plan_txt) > 0 then
      status := 'not_inlined';
    else
      status := 'inlined';
      if r.pronargs > 0 and xargs <> args then
        if r.proretset then xq := format('select f.* from _aa a, lateral %s(%s) f', qname, xargs);
        else xq := format('select %s(%s) from _aa a', qname, xargs); end if;
        xplan := '';
        begin
          for line in execute 'explain (verbose, costs off) ' || xq loop xplan := xplan || line || E'\n'; end loop;
          expensive := case when position(r.nspname || '.' || r.proname || '(' in xplan) > 0 or position('Function Scan on ' || r.proname in xplan) > 0 then 'no' else 'yes' end;
        exception when others then expensive := 'error'; detail := sqlerrm; end;
      else expensive := 'n/a'; end if;
    end if;
    return next;
  end loop;
end $$;

select fn_oid, fn, nargs, status, coalesce(detail, ''), coalesce(expensive, '') from pg_temp.audit_inline();
