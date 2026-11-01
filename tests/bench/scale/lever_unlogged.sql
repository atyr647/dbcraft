-- Lever: UNLOGGED chunk cache.  WAL written when 5,056 real cached packets are inserted into a logged vs an unlogged copy, and what a crash does to it.
-- psql -X -d lever_dense -f tests/bench/scale/lever_unlogged.sql   (needs lever.cache_pglz from lever_toast.py)
\set ON_ERROR_STOP on
drop table if exists lever.u_logged, lever.u_unlogged;
create table lever.u_logged (dimension text not null, cx int not null, cz int not null, version bigint not null, packet bytea not null, primary key (dimension, cx, cz));
alter table lever.u_logged alter column packet set compression lz4;
create unlogged table lever.u_unlogged (like lever.u_logged including all);
checkpoint;
select pg_current_wal_lsn() as l0 \gset
insert into lever.u_logged select * from lever.cache_pglz;
select pg_current_wal_lsn() as l1 \gset
insert into lever.u_unlogged select * from lever.cache_pglz;
select pg_current_wal_lsn() as l2 \gset
select (select count(*) from lever.u_logged) as rows,
       pg_size_pretty(pg_wal_lsn_diff(:'l1', :'l0')::bigint) as wal_logged,
       pg_size_pretty(pg_wal_lsn_diff(:'l2', :'l1')::bigint) as wal_unlogged,
       round(pg_wal_lsn_diff(:'l1', :'l0') / 5056) as wal_bytes_per_chunk_logged,
       round(pg_wal_lsn_diff(:'l2', :'l1') / 5056) as wal_bytes_per_chunk_unlogged;
-- the rest of what a dense chunk costs in WAL on creation, for comparison: sections + light + chunk rows (the replication procedure measured ~64-68 KB per chunk in total)
checkpoint;
