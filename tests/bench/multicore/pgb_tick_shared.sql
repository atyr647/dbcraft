-- the same transaction, but the hot table is ONE table shared by all clients (disjoint blocks of 10,000 rows); queues stay private
\set c :client_id
\set lo (:client_id * 10000) + 1
\set hi (:client_id + 1) * 10000
begin;
update w_s set x = x + 0.1, z = z + 0.1, tick = tick + 1 where id between :lo and :hi;
insert into q_:c select g % 500, g, decode(md5(g::text), 'hex') || decode(md5((g * 7)::text), 'hex') from generate_series(1, 5000) g;
select count(*) from (select conn, string_agg(data, ''::bytea order by seq) from q_:c group by conn) s;
truncate q_:c;
end;
