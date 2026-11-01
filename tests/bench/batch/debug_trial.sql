-- Debug one trial of tests/sql/388: per tick and per connection, the number of frames, whether the connection closes, and the packet names, for both implementations.
-- usage: psql -v trial=2 -f tests/sql/_harness.sql -f tests/sql/_batch_diff_helpers.sql -f tests/bench/batch/debug_trial.sql   (in a database prepared by tests/sql/run.sh)
create or replace function t.names_of_frames(b bytea) returns text language plpgsql as $$
declare o int := 0; v int; n int; id int; out text[] := '{}';
begin
    while o < length(b) loop
        select val, nxt into v, n from proto.varint_read(b, o);
        select val into id from proto.varint_read(b, n);
        out := out || replace(coalesce(net.pkt_name('play', 'clientbound', id), '?' || id), 'minecraft:', '');
        o := n + v;
    end loop;
    return array_to_string(out, ',');
end $$;
do $$
declare tr int := :trial; i int; tick_no int; r record; impl text; err int;
begin
    perform setseed(tr / 7919.0);
    perform t.gen_state(14, true);
    perform t.gen_script(4, true);
    perform t.snap();
    for i in 1..2 loop
        impl := case i when 1 then 'baseline' else 'batched' end;
        perform t.restore();
        for tick_no in 1..4 loop
            insert into net.inbox (conn_id, payload) select conn_id, payload from t.script s where s.tk = tick_no order by ord, conn_id;
            if i = 1 then perform mc.server_tick(); else perform mc.server_tick_batched(); end if;
            for r in select * from net.drain_outbox() order by conn_id loop
                raise notice '% tick % conn % close=% : %', impl, tick_no, r.conn_id, r.close, t.names_of_frames(r.data);
            end loop;
        end loop;
        select count(*) into err from mc.error_log;
        raise notice '% errors: %, online players at the end: %', impl, err, (select count(*) from mc.player where conn_id is not null);
    end loop;
end $$;
