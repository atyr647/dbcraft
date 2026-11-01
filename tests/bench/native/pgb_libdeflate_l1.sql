\set id random(1, 49)
select octet_length(dbcraft_zlib.deflate_zlib(payload, 1, 'libdeflate')) from bench.real_pk where id = :id;
