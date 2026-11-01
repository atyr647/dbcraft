\set id random(1, 49)
select octet_length(mc.deflate_zlib_sql(payload)) from bench.real_pk where id = :id;
