-- pure compute and allocation: build 5,000 packets and concatenate per connection; no table is touched
select count(*) from (select g % 500 as conn, string_agg(decode(md5(g::text), 'hex') || decode(md5((g * 7)::text), 'hex'), ''::bytea order by g) from generate_series(1, 5000) g group by 1) s;
