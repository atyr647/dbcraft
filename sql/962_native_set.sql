-- Optional native accelerator for the first fill of a shape (native/dbcraft_set, docs/PERF-WORLD2.md "Cold fills").
--
-- mc.shortset_order (sql/850) simulates fastutil's ShortOpenHashSet in PL/pgSQL, about 1.5 us a position; mc.sbu_build (sql/960) then builds the packet template of a shape with two
-- string aggregations over the result.  Together that is the whole cost of a fill whose shape the template cache has not seen: 2 to 6 ms per section.  If the extension
-- dbcraft_set is installed in this PostgreSQL server (make && make install in native/dbcraft_set), this file loads it and points both at it: the same simulation in C, a
-- template in tens of microseconds.  If it is not installed nothing changes: the SQL implementation stays in use (and is what tests/sql/962 compares the C one with).
--
--   mc.shortset_order(int[])         the keys in the iteration order of the set (what sql/850 defined); native or SQL, see mc.select_shortset
--   mc.shortset_order_sql(int[])     the pure SQL simulation, always available (a copy of the body of sql/850)
--   mc.native_set_available()        is the extension installed in this database
--   mc.select_shortset('native'|'sql')   re-point mc.shortset_order at either implementation (also used by the tests and the benchmark)
--   mc.shortset_impl()               which one is active
-- Before DROP EXTENSION dbcraft_set run  select mc.select_shortset('sql');  (SQL function bodies are not dependency-tracked).

create or replace function mc.shortset_order_sql(p_pos int[]) returns int[] language plpgsql immutable parallel safe as $$
declare
    n        int := 32;
    mask     int := 31;
    maxfill  int := 24;
    size     int := 0;
    tab      int[] := array_fill(0, array[32]);       -- slot s (0-based) holds position + 1, 0 = empty
    has_null boolean := false;
    k int; h bigint; p int; v int; dup boolean;
    nn int; nm int; nt int[]; i int;
    res      int[]; c int := 0;
begin
    foreach k in array p_pos loop
        if k = 0 then
            continue when has_null;
            has_null := true;
        else
            h := (k::bigint * 2654435769) & 4294967295;              -- HashCommon.mix: h = k * 0x9E3779B9 (32 bit), h ^ (h >>> 16)
            p := ((h # (h >> 16)) & mask)::int;
            dup := false;
            loop
                v := tab[p + 1];
                exit when v = 0;
                if v = k + 1 then dup := true; exit; end if;
                p := (p + 1) & mask;
            end loop;
            continue when dup;
            tab[p + 1] := k + 1;
        end if;
        size := size + 1;
        if size - 1 >= maxfill then                                       -- add(): if (size++ >= maxFill) rehash(arraySize(size + 1, f))
            nn := n * 2; nm := nn - 1; nt := array_fill(0, array[nn]);
            for i in reverse n .. 1 loop
                v := tab[i];
                continue when v = 0;
                h := ((v - 1)::bigint * 2654435769) & 4294967295;
                p := ((h # (h >> 16)) & nm)::int;
                while nt[p + 1] <> 0 loop p := (p + 1) & nm; end loop;
                nt[p + 1] := v;
            end loop;
            tab := nt; n := nn; mask := nm; maxfill := nn * 3 / 4;
        end if;
    end loop;
    res := array_fill(0, array[size]);
    if has_null then c := 1; res[1] := 0; end if;
    for i in reverse n .. 1 loop
        if tab[i] <> 0 then c := c + 1; res[c] := tab[i] - 1; end if;
    end loop;
    return res;
end $$;

create or replace function mc.native_set_available() returns boolean language sql stable as $$
  select to_regprocedure('dbcraft_set.shortset_order(integer[])') is not null $$;

create or replace function mc.shortset_impl() returns text language sql stable as $$
  select case when prosrc like '%dbcraft_set.%' then 'native' else 'sql' end from pg_proc where oid = 'mc.shortset_order(integer[])'::regprocedure $$;

create or replace function mc.select_shortset(p_impl text) returns text language plpgsql as $$
begin
    if p_impl = 'native' then
        if not mc.native_set_available() then
            raise exception 'the dbcraft_set extension is not installed in this database (CREATE EXTENSION dbcraft_set)';
        end if;
        execute 'create or replace function mc.shortset_order(p_pos int[]) returns int[] language sql immutable parallel safe as $f$ select dbcraft_set.shortset_order(p_pos) $f$';
    elsif p_impl = 'sql' then
        execute 'create or replace function mc.shortset_order(p_pos int[]) returns int[] language sql immutable parallel safe as $f$ select mc.shortset_order_sql(p_pos) $f$';
    else
        raise exception 'unknown implementation "%" (use native or sql)', p_impl;
    end if;
    return mc.shortset_impl();
end $$;

-- Load the extension when the server has it; stay on the SQL implementation otherwise (or when this role may not create it: it needs a superuser).
do $$
begin
    if not exists (select 1 from pg_extension where extname = 'dbcraft_set')
       and exists (select 1 from pg_available_extensions where name = 'dbcraft_set') then
        begin
            create extension dbcraft_set;
        exception when insufficient_privilege then
            raise notice 'dbcraft_set is installed on the server but this role cannot CREATE EXTENSION: the first fill of a shape stays in SQL';
        end;
    end if;
end $$;

select mc.select_shortset(case when mc.native_set_available() then 'native' else 'sql' end);
