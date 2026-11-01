\set id random(1, 49)
\set sl random(0, 11)
select octet_length(dbcraft_zlib.deflate_fragment(substring(payload from 1 + :sl * 4096 for 4096), 6, false)) from bench.real_pk where id = :id;
