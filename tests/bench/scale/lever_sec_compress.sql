-- Lever: let section rows compress.  sql/200 sets toast_tuple_target = 8160 on mc.chunk_section, so a row is only compressed when it is larger than 8,160 bytes, and
-- almost no section row is (flat: ~4 KB, real terrain: ~2.9 KB on average): they are stored raw.  With the default target (2,032) every row above 2 KB is compressed
-- inline (storage MAIN keeps it in the row).  psql -X -d DB -f tests/bench/scale/lever_sec_compress.sql
\timing on
select pg_size_pretty(pg_total_relation_size('mc.chunk_section')) as before_total, count(*) as sections, round(avg(pg_column_size(s.*))) as avg_row_bytes from mc.chunk_section s;
alter table mc.chunk_section reset (toast_tuple_target);
update mc.chunk_section set block_count = block_count;      -- rewrites every row; rows above the target are compressed on the way in
vacuum full mc.chunk_section;
analyze mc.chunk_section;
select pg_size_pretty(pg_total_relation_size('mc.chunk_section')) as after_total, count(*) as sections, round(avg(pg_column_size(s.*))) as avg_row_bytes from mc.chunk_section s;
select coalesce(pg_column_compression(data), 'raw') as data_method, count(*) from mc.chunk_section group by 1 order by 2 desc;
select coalesce(pg_column_compression(palette), 'raw') as palette_method, count(*) from mc.chunk_section group by 1 order by 2 desc;
select reloptions from pg_class where oid = 'mc.chunk_section'::regclass;
