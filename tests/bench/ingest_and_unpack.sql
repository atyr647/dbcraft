\timing on
\set QUIET on
set jit=off;
drop table if exists inbox; create unlogged table inbox(conn_id int, seq int, packet_id int, body bytea);
\echo == I: COPY 10k packets into UNLOGGED inbox (one tick @ 10k players), 5 runs
\copy inbox from '/tmp/inbox.copy'
truncate inbox; \copy inbox from '/tmp/inbox.copy'
truncate inbox; \copy inbox from '/tmp/inbox.copy'
truncate inbox; \copy inbox from '/tmp/inbox.copy'
\echo == K: readable view: unpack 4096 entries of a 5-bit wire-format section into rows (pure SQL), 200 sections
create temp table w as select s, decode(repeat(md5(s::text),(4096/12+1)*8/16+1),'hex') d from generate_series(1,200) s;
select count(*) from w, lateral (select ((get_byte(d,(i/12)*8+7-(((i%12)*5)/8))::bigint) ) from generate_series(0,4095) i) q;
