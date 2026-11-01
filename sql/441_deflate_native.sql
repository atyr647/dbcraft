-- Optional native accelerator for compression (native/dbcraft_zlib, docs/NATIVE-DEFLATE.md).
--
-- sql/440_deflate.sql compresses in SQL (distance-1 runs + fixed Huffman: 2.2x on real terrain, ~22 ms per chunk packet).  If the extension dbcraft_zlib is installed
-- in this PostgreSQL server, this file loads it and points the two functions on the chunk-compression path at it (real zlib/libdeflate: ~5x, ~1-3 ms).  If it is not
-- installed this file changes nothing visible: the SQL implementation stays in use.
--
--   mc.deflate_zlib(data)      a complete zlib stream           (what mc.z_frame / net.deflate_frame call)
--   mc.adler32(data)           the zlib checksum                 (also used when splicing flat chunks)
--   mc.deflate_zlib_sql / mc.adler32_sql      the pure-SQL implementations (copies of the bodies in sql/440), always available
--   mc.select_deflate('native'|'sql', level)  re-point the two functions at either implementation (also used by the tests and benchmarks)
--   mc.deflate_impl()          which one is active
--
-- The template splice for flat chunks (sql/245_world_gen.sql) calls mc.deflate_fixed directly and is unchanged: it runs once per template.
-- Before DROP EXTENSION dbcraft_zlib run  select mc.select_deflate('sql');  (SQL function bodies are not dependency-tracked).

create or replace function mc.adler32_sql(p_data bytea) returns bigint language plpgsql stable parallel safe as $$
declare d bytea := p_data || ''::bytea; n int := octet_length(d); a bigint := 1; b bigint := 0; i int;
begin
    for i in 0 .. n - 1 loop a := a + get_byte(d, i); b := b + a; end loop;
    return ((b % 65521) << 16) | (a % 65521);
end $$;

create or replace function mc.deflate_zlib_sql(p_data bytea) returns bytea language sql stable parallel safe as $$
  select '\x7801'::bytea || mc.deflate_fixed(p_data, true) || substring(int8send(mc.adler32_sql(p_data)) from 5 for 4) $$;

create or replace function mc.native_deflate_available() returns boolean language sql stable as $$
  select to_regprocedure('dbcraft_zlib.deflate_zlib(bytea,integer,text)') is not null $$;

create or replace function mc.deflate_impl() returns text language sql stable as $$
  select case when prosrc like '%dbcraft_zlib.%' then 'native' else 'sql' end from pg_proc where oid = 'mc.deflate_zlib(bytea)'::regprocedure $$;

create or replace function mc.select_deflate(p_impl text, p_level int default 6) returns text language plpgsql as $$
begin
    if p_impl = 'native' then
        if not mc.native_deflate_available() then
            raise exception 'the dbcraft_zlib extension is not installed in this database (CREATE EXTENSION dbcraft_zlib)';
        end if;
        if p_level not between 0 and 9 then raise exception 'compression level must be between 0 and 9'; end if;
        execute format('create or replace function mc.deflate_zlib(p_data bytea) returns bytea language sql stable parallel safe as $f$ select dbcraft_zlib.deflate_zlib(p_data, %s) $f$', p_level);
        execute 'create or replace function mc.adler32(p_data bytea) returns bigint language sql stable parallel safe as $f$ select dbcraft_zlib.adler32(p_data) $f$';
    elsif p_impl = 'sql' then
        execute 'create or replace function mc.deflate_zlib(p_data bytea) returns bytea language sql stable parallel safe as $f$ select mc.deflate_zlib_sql(p_data) $f$';
        execute 'create or replace function mc.adler32(p_data bytea) returns bigint language sql stable parallel safe as $f$ select mc.adler32_sql(p_data) $f$';
    else
        raise exception 'unknown implementation "%" (use native or sql)', p_impl;
    end if;
    return mc.deflate_impl();
end $$;

-- Load the extension when the server has it; stay on the SQL implementation otherwise (or when this role may not create it: it needs a superuser).
do $$
begin
    if not exists (select 1 from pg_extension where extname = 'dbcraft_zlib')
       and exists (select 1 from pg_available_extensions where name = 'dbcraft_zlib') then
        begin
            create extension dbcraft_zlib;
        exception when insufficient_privilege then
            raise notice 'dbcraft_zlib is installed on the server but this role cannot CREATE EXTENSION: compression stays in SQL';
        end;
    end if;
end $$;

select mc.select_deflate(case when mc.native_deflate_available() then 'native' else 'sql' end, 6);
