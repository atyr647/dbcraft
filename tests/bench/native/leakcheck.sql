-- Leak check for the native extension: resident memory of one backend after repeated identical passes of ~6,300 compressions (all backends, levels 2-5 and 6,
-- zlib / raw / fragment modes, checksums).  The first pass allocates the per-backend compressor caches (about 300 KB per zlib stream, more per libdeflate level);
-- later passes must not grow.   PGHOST=/tmp PGPORT=54433 PGUSER=postgres PGDATABASE=dbcraft_zlib psql -X -q -f tests/bench/native/leakcheck.sql
select pg_backend_pid() as pid \gset
\setenv PID :pid
\echo -- before any call
\! grep -E 'VmRSS' /proc/$PID/status
create or replace function pg_temp.pass() returns bigint language plpgsql as $$
declare r record; i int; x bigint := 0;
begin
  for i in 1 .. 4 loop
    for r in select payload p from bench.real_pk loop
      x := x + octet_length(dbcraft_zlib.deflate_zlib(r.p, 1 + i, 'zlib')) + octet_length(dbcraft_zlib.deflate_zlib(r.p, 1 + i, 'libdeflate'))
             + octet_length(dbcraft_zlib.deflate_raw(r.p, 6, 'zlib')) + octet_length(dbcraft_zlib.deflate_fragment(r.p, 3, false))
             + (dbcraft_zlib.adler32(r.p) & 1) + (dbcraft_zlib.crc32(r.p) & 1);
    end loop;
    for r in select slice p from bench.real_slices loop
      x := x + octet_length(dbcraft_zlib.deflate_zlib(r.p, 6, 'libdeflate')) + octet_length(dbcraft_zlib.deflate_fragment(r.p, 1, true));
    end loop;
  end loop;
  return x;
end $$;
select pg_temp.pass() as pass1_checksum;
\echo -- after pass 1
\! grep -E 'VmRSS' /proc/$PID/status
select pg_temp.pass() as pass2_checksum;
\echo -- after pass 2
\! grep -E 'VmRSS' /proc/$PID/status
select pg_temp.pass() as pass3_checksum;
select pg_temp.pass() as pass4_checksum;
\echo -- after pass 4
\! grep -E 'VmRSS' /proc/$PID/status
