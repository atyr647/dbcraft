select format('%-17s rows %7s heap %9s idx %8s toast %8s total %9s  /chunk %6s', c.relname, c.reltuples::bigint, pg_relation_size(c.oid), pg_indexes_size(c.oid), coalesce(pg_relation_size(c.reltoastrelid),0), pg_total_relation_size(c.oid),
   round(pg_total_relation_size(c.oid)::numeric / greatest((select count(*) from mc.chunk),1)))
 from pg_class c where c.relnamespace='mc'::regnamespace and c.relname in ('chunk','chunk_section','chunk_light','chunk_cache','block_entity') order by 1;
select format('WORLD TOTAL %s bytes = %s MiB, %s per chunk (%s chunks)', sum(pg_total_relation_size(c.oid)), round(sum(pg_total_relation_size(c.oid))/1048576.0,2), round(sum(pg_total_relation_size(c.oid))::numeric/(select count(*) from mc.chunk)), (select count(*) from mc.chunk))
 from pg_class c where c.relnamespace='mc'::regnamespace and c.relname in ('chunk','chunk_section','chunk_light','chunk_cache','block_entity');
