-- Experiment 8: a poor man's persistent worker pool with dblink (contrib; no pg_background here).  Persistent connections h0..h3 stay open for the life of the leader session
-- (the gateway is one long CALL), so no fork per query.  The fan-out (join visible x packets, sort, string_agg per viewer) is split by viewer_conn mod M over M helpers,
-- dispatched with dblink_send_query and collected with dblink_get_result.  The leader passes the freshly built packets as parameters (they are uncommitted state in the real
-- tick) and gets the per-viewer blobs back as hex text, which is parsed into bytea.  Measured: one iteration of dispatch + collect, against doing the same locally.
\set ON_ERROR_STOP on
\pset format unaligned
\pset fieldsep ' | '
create extension if not exists dblink;
-- the work done by one helper: its share of the viewers
create or replace function par.fan_part(eids int[], datas bytea[], m int, r int) returns table(viewer_conn int, data bytea) language sql stable as $$
  select v.viewer_conn, string_agg(pk.data, '\x'::bytea order by pk.eid)
    from mc.visible v join unnest(eids, datas) as pk(eid, data) on pk.eid = v.target_eid
   where v.viewer_conn % m = r
   group by v.viewer_conn $$;

create or replace function par.dl_connect(n int) returns void language plpgsql as $$
declare i int;
begin
  for i in 0..n - 1 loop
    if not ('h' || i = any (coalesce(dblink_get_connections(), '{}'))) then
      perform dblink_connect('h' || i, 'dbname=' || current_database() || ' host=/tmp port=' || current_setting('port') || ' user=postgres');
    end if;
  end loop;
end $$;

-- one iteration with m helpers; returns the bytes collected
create or replace function par.dl_fanout(m int, local_only boolean default false) returns bigint language plpgsql as $$
declare eids int[]; datas bytea[]; i int; total bigint := 0; lit_e text; lit_d text; n bigint;
begin
  select array_agg(eid order by eid), array_agg(data order by eid) into eids, datas from par.pkt;      -- packets (as the tick would have just built them)
  if local_only then
    select coalesce(sum(octet_length(f.data)), 0) into total from par.fan_part(eids, datas, 1, 0) f;
    return total;
  end if;
  lit_e := quote_literal(eids::text); lit_d := quote_literal(datas::text);
  for i in 0..m - 1 loop
    perform dblink_send_query('h' || i, format('select * from par.fan_part(%s::int[], %s::bytea[], %s, %s)', lit_e, lit_d, m, i));
  end loop;
  for i in 0..m - 1 loop
    select coalesce(sum(octet_length(t.data)), 0) into n from dblink_get_result('h' || i) as t(viewer_conn int, data bytea);
    total := total + n;
    perform 1 from dblink_get_result('h' || i) as t(viewer_conn int, data bytea);                      -- drain the end-of-results marker
  end loop;
  return total;
end $$;

select par.dl_connect(4);
select 'connections: ' || array_to_string(dblink_get_connections(), ',');
create temp table r(name text, ms numeric[]);
do $$
declare i int; t0 timestamptz; m int; res numeric[]; chk bigint; ref bigint;
begin
  perform par.dl_fanout(4); perform par.dl_fanout(1, true);
  ref := par.dl_fanout(1, true);
  foreach m in array array[0, 1, 2, 3, 4] loop
    res := '{}';
    for i in 1..21 loop
      t0 := clock_timestamp();
      if m = 0 then chk := par.dl_fanout(1, true); else chk := par.dl_fanout(m); end if;
      res := res || (extract(epoch from clock_timestamp() - t0) * 1000)::numeric;
      if chk <> ref then raise exception 'result differs for m=%: % vs %', m, chk, ref; end if;
    end loop;
    insert into r values (case when m = 0 then 'local, serial (reference)' else m || ' dblink helper(s)' end, res);
  end loop;
end $$;
select name || ': median ' || round((percentile_cont(.5) within group (order by x))::numeric, 2) || ' ms, p10 ' || round((percentile_cont(.1) within group (order by x))::numeric, 2) || ' ms'
  from r, unnest(ms) x group by name order by name;
select 'all helper runs returned the same number of bytes as the local run: ' || par.dl_fanout(4) || ' = ' || par.dl_fanout(1, true);
