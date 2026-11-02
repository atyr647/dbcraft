-- one tick-like transaction on private tables: 10k HOT updates (logged), 5k queue rows built, concatenated per connection, queue truncated
\set c :client_id
begin;
update w_:c set x = x + 0.1, z = z + 0.1, tick = tick + 1;
insert into q_:c select g % 500, g, decode(md5(g::text), 'hex') || decode(md5((g * 7)::text), 'hex') from generate_series(1, 5000) g;
select count(*) from (select conn, string_agg(data, ''::bytea order by seq) from q_:c group by conn) s;
truncate q_:c;
end;
