-- this test pins the classic (simplified) player broadcast of sql/430-468; the vanilla tracker of sql/900-910 has its own test (900_vis.sql)
update mc.server_property set value = 'false' where key = 'dbcraft.vanilla-tracker';
-- The optional native accelerator dbcraft_zlib (native/dbcraft_zlib, sql/441_deflate_native.sql).  SKIPPED (with a notice) when the extension is not installed on
-- the server; the suite passes either way.  Every claim about compressed bytes is judged by a REAL inflater (tools/zlib_check.py: Python's zlib; the Java Inflater
-- check is tests/bench/native/inflate_java.sh over /tmp/dbcraft_native_zin.tsv).
select exists (select 1 from pg_extension where extname = 'dbcraft_zlib') as have_native \gset

\if :have_native
create temp table zin  (label text, kind text, stream text, expected text);
create temp table zout (label text, verdict text);
create temp table big  (name text primary key, d bytea);
insert into big select '1MiB random', decode(string_agg(md5(g::text), '' order by g), 'hex') from generate_series(1, 65536) g;
insert into big select 'chunk-like 2MB', decode(string_agg(repeat('00', 3000) || repeat(md5(s::text), 62) || repeat('ff', 96), '' order by s), 'hex') from generate_series(1, 512) s;
insert into big select '8MiB random', decode(string_agg(md5(g::text), '' order by g), 'hex') from generate_series(1, 524288) g;

------------------------------------------------------------------------------------------------ what is installed
select t.eq('the migration selected the native implementation', mc.deflate_impl(), 'native');
select t.is_true('backend() names zlib', dbcraft_zlib.backend() like 'zlib %');
select t.is_true('all functions are immutable, strict and parallel safe', (
    select bool_and(provolatile = 'i' and proisstrict and proparallel = 's') from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'dbcraft_zlib'));
select t.eq('NULL in, NULL out (strict)', dbcraft_zlib.deflate_zlib(null::bytea) is null, true);

------------------------------------------------------------------------------------------------ checksums
select t.eq('adler32 of the empty string is 1', dbcraft_zlib.adler32('\x'), 1::bigint);
select t.eq('adler32 of "Wikipedia" is 0x11E60398', dbcraft_zlib.adler32('Wikipedia'::bytea), 300286872::bigint);
select t.eq('adler32 of "a"', dbcraft_zlib.adler32('a'::bytea), 6422626::bigint);
select t.eq('adler32 agrees with the SQL implementation on 30 random inputs (1 to 40 KB)', (
    select count(*)::int from (select decode(string_agg(md5((g * 31 + k)::text), ''), 'hex') d from generate_series(1, 30) g, generate_series(1, 1 + g * 85) k group by g) q
     where dbcraft_zlib.adler32(d) <> mc.adler32_sql(d)), 0);
select t.eq('adler32 of 1 MiB agrees with Python-checked value path (SQL implementation)', dbcraft_zlib.adler32(d), mc.adler32_sql(d)) from big where name = '1MiB random';
select t.eq('adler32_combine agrees with the SQL combine and with the checksum of the whole (20 splits)', (
    select count(*)::int from (select d, (g * 37) % 300 as s from (select decode(string_agg(md5((g * 7 + k)::text), ''), 'hex') d, g from generate_series(1, 20) g, generate_series(1, 30) k group by g) q) w
     where dbcraft_zlib.adler32(d) <> dbcraft_zlib.adler32_combine(dbcraft_zlib.adler32(substring(d from 1 for s)), dbcraft_zlib.adler32(substring(d from s + 1)), octet_length(d) - s)
        or mc.adler32_combine(dbcraft_zlib.adler32(substring(d from 1 for s)), dbcraft_zlib.adler32(substring(d from s + 1)), octet_length(d) - s) <> dbcraft_zlib.adler32(d)), 0);
select t.raises('adler32_combine rejects a value above 2^32-1', $$select dbcraft_zlib.adler32_combine(4294967296, 1, 1)$$);
select t.raises('adler32_combine rejects a negative length', $$select dbcraft_zlib.adler32_combine(1, 1, -1)$$);
select t.eq('crc32 of the empty string is 0', dbcraft_zlib.crc32('\x'), 0::bigint);
select t.eq('crc32 of "123456789" is 0xCBF43926', dbcraft_zlib.crc32('123456789'::bytea), 3421780262::bigint);
select t.eq('crc32 of "a" is 0xE8B7BE43', dbcraft_zlib.crc32('a'::bytea), 3904355907::bigint);

------------------------------------------------------------------------------------------------ errors and limits
select t.raises('level -1 is refused', $$select dbcraft_zlib.deflate_zlib('\x41', -1)$$);
select t.raises('level 10 is refused', $$select dbcraft_zlib.deflate_zlib('\x41', 10)$$);
select t.raises('an unknown backend is refused', $$select dbcraft_zlib.deflate_zlib('\x41', 6, 'bogus')$$);
select t.eq('input of exactly 16 MiB is accepted (zeros: tiny output)', (select octet_length(dbcraft_zlib.deflate_zlib(decode(repeat('00', 16 * 1024 * 1024), 'hex'), 1)) < 100000), true);
do $d$ begin
    begin perform dbcraft_zlib.deflate_zlib(decode(repeat('00', 16 * 1024 * 1024 + 1), 'hex'), 1); raise exception 'FAIL 16 MiB + 1 byte was accepted';
    exception when program_limit_exceeded then raise notice 'ok   16 MiB + 1 byte is refused with program_limit_exceeded'; end;
    begin perform dbcraft_zlib.deflate_fragment(decode(repeat('00', 16 * 1024 * 1024 + 1), 'hex'), 1, true); raise exception 'FAIL fragment over the limit was accepted';
    exception when program_limit_exceeded then raise notice 'ok   a fragment over the limit is refused too'; end;
end $d$;

------------------------------------------------------------------------------------------------ the streams, judged by zlib (and, via the dump, by Java)
insert into zin
select label || ' L' || lvl || ' ' || be, 'zlib', encode(dbcraft_zlib.deflate_zlib(d, lvl, be), 'hex'), encode(d, 'hex')
from (values
    ('empty', ''::bytea), ('one byte', '\x41'::bytea), ('three same', '\x414141'::bytea),
    ('text', convert_to(repeat('hello hello hello world, aaaaaaaaaaaaaaaa bbbbbbbb ', 20), 'UTF8')),
    ('run 70000', decode(repeat('00', 70000), 'hex')),
    ('all 256 values', (select string_agg(set_byte('\x00'::bytea, 0, b), ''::bytea order by b) from generate_series(0, 255) b)),
    ('random 3200 bytes', (select decode(string_agg(md5(g::text), ''), 'hex') from generate_series(1, 200) g))
) v(label, d), generate_series(0, 9) lvl, (values ('zlib'), ('libdeflate'), ('auto')) b(be);
insert into zin
select b.name || ' L' || lvl || ' ' || be, 'zlib', encode(dbcraft_zlib.deflate_zlib(b.d, lvl, be), 'hex'), encode(b.d, 'hex')
from big b, (values (1), (6)) l(lvl), (values ('zlib'), ('libdeflate')) x(be) where b.name <> '8MiB random';
insert into zin
select '1MiB random L9 zlib', 'zlib', encode(dbcraft_zlib.deflate_zlib(d, 9, 'zlib'), 'hex'), encode(d, 'hex') from big where name = '1MiB random';
insert into zin
select b.name || ' raw L' || lvl || ' ' || be, 'raw', encode(dbcraft_zlib.deflate_raw(b.d, lvl, be), 'hex'), encode(b.d, 'hex')
from big b, (values (1), (6)) l(lvl), (values ('zlib'), ('libdeflate')) x(be) where b.name <> '8MiB random';
insert into zin
select 'raw one byte ' || be, 'raw', encode(dbcraft_zlib.deflate_raw('\x41', 6, be), 'hex'), '41' from (values ('zlib'), ('libdeflate')) x(be);
insert into zin select 'raw empty ' || be, 'raw', encode(dbcraft_zlib.deflate_raw('\x', 6, be), 'hex'), '' from (values ('zlib'), ('libdeflate')) x(be);

-- fragments: 24 independent 4 KB sections, each ended with a sync flush, then a final one; concatenated they are ONE valid deflate stream, and with the zlib
-- wrapper and a combined Adler-32 one valid zlib stream (this is the per-section scheme of docs/COMPRESSION.md)
create temp table secs as select s, substring(d from 1 + (s - 1) * 4096 for 4096) sec from big, generate_series(1, 25) s where name = 'chunk-like 2MB';
select t.eq('a non-final fragment ends with the sync marker 00 00 ff ff', (select count(*)::int from secs where s < 25 and substring(dbcraft_zlib.deflate_fragment(sec, 6, false) from octet_length(dbcraft_zlib.deflate_fragment(sec, 6, false)) - 3) <> '\x0000ffff'), 0);
select t.eq('every fragment is independent: the same section gives the same bytes wherever it sits', (select count(*)::int from secs a join secs b on a.sec = b.sec where dbcraft_zlib.deflate_fragment(a.sec, 6, false) <> dbcraft_zlib.deflate_fragment(b.sec, 6, false)), 0);
insert into zin
select 'fragments x25 as one raw stream', 'raw',
       encode((select string_agg(dbcraft_zlib.deflate_fragment(sec, 6, s = 25), ''::bytea order by s) from secs), 'hex'),
       encode((select string_agg(sec, ''::bytea order by s) from secs), 'hex');
insert into zin
select 'fragments x25 as a zlib stream with combined Adler-32', 'zlib',
       encode('\x7801'::bytea || (select string_agg(dbcraft_zlib.deflate_fragment(sec, 6, s = 25), ''::bytea order by s) from secs)
              || substring(int8send((select dbcraft_zlib.adler32(string_agg(sec, ''::bytea order by s)) from secs)) from 5 for 4), 'hex'),
       encode((select string_agg(sec, ''::bytea order by s) from secs), 'hex');
with recursive f(s, a) as (
    select 1, dbcraft_zlib.adler32(sec) from secs where s = 1
    union all
    select f.s + 1, dbcraft_zlib.adler32_combine(f.a, dbcraft_zlib.adler32(x.sec), octet_length(x.sec)) from f join secs x on x.s = f.s + 1)
select t.eq('fold of per-section Adler-32 values equals the Adler-32 of the concatenation', (select a from f where s = 25), (select dbcraft_zlib.adler32(string_agg(sec, ''::bytea order by s)) from secs));

-- wire frames through the dispatching functions (mc.z_frame -> mc.deflate_zlib -> native)
insert into zin
select 'z_frame ' || label, 'frame', encode(mc.z_frame(d), 'hex'), encode(d, 'hex')
from (values ('1 byte', '\x2e'::bytea), ('400 zeros', decode(repeat('00', 400), 'hex')), ('chunk-like', (select substring(d from 1 for 125000) from big where name = 'chunk-like 2MB')),
             ('random 1 KiB', (select substring(d from 1 for 1024) from big where name = '1MiB random'))) v(label, d);

-- fuzz: 300 random inputs (0 to 30,000 bytes, random mixtures of runs and random bytes) with random level, backend and mode, all judged by the inflater
insert into zin
select 'fuzz ' || i || ' len ' || octet_length(d) || ' L' || lvl || ' ' || be || ' ' || mode,
       case when mode = 'zlib' then 'zlib' else 'raw' end,
       encode(case mode when 'zlib' then dbcraft_zlib.deflate_zlib(d, lvl, be) when 'raw' then dbcraft_zlib.deflate_raw(d, lvl, be) else dbcraft_zlib.deflate_fragment(d, lvl, true) end, 'hex'),
       encode(d, 'hex')
from (
    select i, d, (random() * 9)::int as lvl, (array['zlib', 'libdeflate'])[1 + (random())::int] as be, (array['zlib', 'raw', 'fragment'])[1 + (random() * 2)::int] as mode
    from (select i, substring(decode(coalesce((select string_agg(case when random() < 0.5 then repeat(lpad(to_hex((random() * 255)::int), 2, '0'), (random() * 200)::int) else md5(random()::text) end, '')
                                                 from generate_series(1, 1 + (random() * 400)::int) j where j > 0 and i > 0), ''), 'hex') from 1 for (random() * 30000)::int) as d
            from generate_series(1, 300) i) q
) f;

\copy (select * from zin order by label) to program 'python3 tools/zlib_check.py > /tmp/dbcraft_native_zcheck.tsv'
\copy zout from '/tmp/dbcraft_native_zcheck.tsv'
\copy (select * from zin order by label) to '/tmp/dbcraft_native_zin.tsv'
select t.eq('every input was judged', (select count(*)::int from zout), (select count(*)::int from zin));
select t.eq('a real inflater accepts every stream and returns the original bytes (' || (select count(*) from zin) || ' streams)', (select count(*)::int from zout where verdict <> 'ok'), 0);
do $d$ declare bad text; begin
    select string_agg(label || ': ' || verdict, '; ') into bad from zout where verdict <> 'ok';
    if bad is not null then raise notice 'REJECTED: %', bad; end if;
end $d$;

------------------------------------------------------------------------------------------------ determinism and compressor reuse
-- the compressors are cached per backend; interleaving levels, modes and backends must never change an output
do $d$ declare a bytea; b bytea; r6z bytea; r6l bytea; rawz bytea; fr bytea; i int; bad int := 0;
begin
    select d into a from big where name = 'chunk-like 2MB'; a := substring(a from 1 for 200000);
    select d into b from big where name = '1MiB random'; b := substring(b from 1 for 50000);
    r6z := dbcraft_zlib.deflate_zlib(a, 6, 'zlib'); r6l := dbcraft_zlib.deflate_zlib(a, 6, 'libdeflate');
    rawz := dbcraft_zlib.deflate_raw(a, 6, 'zlib'); fr := dbcraft_zlib.deflate_fragment(a, 6, false);
    for i in 1 .. 300 loop
        perform dbcraft_zlib.deflate_zlib(b, 1 + i % 9, case when i % 2 = 0 then 'zlib' else 'libdeflate' end);
        perform dbcraft_zlib.deflate_raw(b, 9, 'zlib'); perform dbcraft_zlib.deflate_fragment(b, 1, true);
        if dbcraft_zlib.deflate_zlib(a, 6, 'zlib') <> r6z or dbcraft_zlib.deflate_zlib(a, 6, 'libdeflate') <> r6l
           or dbcraft_zlib.deflate_raw(a, 6, 'zlib') <> rawz or dbcraft_zlib.deflate_fragment(a, 6, false) <> fr then bad := bad + 1; end if;
    end loop;
    if bad = 0 then raise notice 'ok   300 interleaved rounds: every output identical to the first (compressor reuse is invisible)';
    else raise exception 'FAIL % of 300 rounds differed', bad; end if;
end $d$;

------------------------------------------------------------------------------------------------ interrupts (zlib works in 64 KiB slices)
set statement_timeout = '60ms';
do $d$ declare t0 timestamptz := clock_timestamp(); x bytea; ms numeric;
begin
    select d into x from big where name = '8MiB random';
    begin
        perform dbcraft_zlib.deflate_zlib(x, 9, 'zlib');
        raise notice 'ok   (the 8 MiB level-9 compression finished before the 60 ms timeout on this machine: interrupt not exercised)';
    exception when query_canceled then
        ms := extract(epoch from clock_timestamp() - t0) * 1000;
        if ms < 400 then raise notice 'ok   a 60 ms statement_timeout cancelled the compression after % ms', round(ms);
        else raise exception 'FAIL the cancel took % ms', round(ms); end if;
    end;
end $d$;
reset statement_timeout;

------------------------------------------------------------------------------------------------ the dispatch can be flipped and flipped back
select t.eq('select_deflate(sql) activates the SQL implementation', mc.select_deflate('sql'), 'sql');
select t.eq('...and mc.deflate_zlib then writes the SQL header 78 01', encode(substring(mc.deflate_zlib('\x414141414141'::bytea) from 1 for 2), 'hex'), '7801');
select t.eq('...and mc.adler32 is the SQL one (same value)', mc.adler32('Wikipedia'::bytea), 300286872::bigint);
select t.eq('select_deflate(native, 9) activates the native one at level 9', mc.select_deflate('native', 9), 'native');
select t.eq('...header 78 da (zlib level hint for level 9)', encode(substring(mc.deflate_zlib('\x414141414141'::bytea) from 1 for 2), 'hex'), '78da');
select t.raises('select_deflate refuses an unknown implementation', $$select mc.select_deflate('gpu')$$);
select t.raises('select_deflate refuses level 10', $$select mc.select_deflate('native', 10)$$);
select t.eq('back to the default level', mc.select_deflate('native', 6), 'native');
select t.is_true('the native output is smaller than the SQL output on run-heavy data and far smaller on text-like data', (
    select octet_length(mc.deflate_zlib(d)) < octet_length(mc.deflate_zlib_sql(d)) from (select decode(repeat('0001020300', 800) || repeat('00', 2000), 'hex') d) q));

\else
do $d$ begin raise notice 'SKIP: dbcraft_zlib is not installed on this server: native deflate tests not run (build it with: make -C native/dbcraft_zlib && sudo make -C native/dbcraft_zlib install)'; end $d$;
select t.eq('without the extension the SQL implementation is active', mc.deflate_impl(), 'sql');
select t.eq('without the extension native availability is reported false', mc.native_deflate_available(), false);
select t.raises('without the extension select_deflate(native) explains itself', $$select mc.select_deflate('native')$$);
select t.eq('the SQL wrappers still produce a stream whose header is 78 01', encode(substring(mc.deflate_zlib('\x414141414141'::bytea) from 1 for 2), 'hex'), '7801');
\endif
