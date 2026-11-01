-- Reconnect storms and byte-identity digests for the login storm harness (load after storm.sql).

-- reconnect: p_k of the online connections (ids p_old_from ...) come back under new connection ids p_new_from ... with the SAME names.
-- p_mode 'dup' = the old connections are still open (duplicate login kicks them); 'gone' = they were disconnected first.
create or replace function jbench.reconnect_tick(p_old_from int, p_k int, p_new_from int, p_prefix text, p_mode text)
returns table (ms_tick float8, frames bigint, mb numeric)
language plpgsql as $$
declare t0 timestamptz; b bigint; n bigint;
begin
    if p_mode = 'gone' then perform net.on_disconnect(g) from generate_series(p_old_from, p_old_from + p_k - 1) g; end if;
    perform net.on_connect(p_new_from + i) from generate_series(0, p_k - 1) i;
    insert into net.inbox (conn_id, payload)
    select p_new_from + i, x.payload
    from generate_series(0, p_k - 1) i,
         lateral (values
            (1, proto.varint(net.pkt('handshake', 'serverbound', 'minecraft:intention')) || proto.varint(777) || proto.string('localhost') || proto.i16(25565) || proto.varint(2)),
            (2, proto.varint(net.pkt('login', 'serverbound', 'minecraft:hello')) || proto.string(jbench.name(p_old_from + i, p_prefix)) || proto.uuid(net.offline_uuid(jbench.name(p_old_from + i, p_prefix)))),
            (3, proto.varint(net.pkt('login', 'serverbound', 'minecraft:login_acknowledged'))),
            (4, proto.varint(net.pkt('configuration', 'serverbound', 'minecraft:select_known_packs')) || proto.varint(0)),
            (5, proto.varint(net.pkt('configuration', 'serverbound', 'minecraft:finish_configuration')))) x(step, payload)
    order by i, x.step;
    t0 := clock_timestamp();
    perform mc.server_tick();
    ms_tick := extract(epoch from clock_timestamp() - t0) * 1000;
    select count(*), coalesce(sum(length(d.data)), 0) into n, b from net.drain_outbox() d;
    frames := n; mb := round(b / 1048576.0, 2);
    return next;
end $$;

-- every connection's drained bytes, hashed: (conn, md5, bytes), for byte-identity comparisons between two databases or two code paths.
-- The random parts of a join (the session id in login_finished, the keep-alive ids) are masked by the caller comparing the digest of the SAME run.
create or replace function jbench.digest() returns table (conn_id bigint, md5 text, bytes int) language sql as $$
    select d.conn_id,
           md5(decode(replace(encode(d.data, 'hex'), replace(coalesce(c.session_id::text, '00000000-0000-0000-0000-000000000000'), '-', ''), repeat('0', 32)), 'hex')),
           length(d.data)
    from net.drain_outbox() d left join net.conn c on c.conn_id = d.conn_id order by d.conn_id $$;

-- one tick of a storm, returning the masked digest of what every connection received in it (the outbox is consumed, as the gateway would)
create or replace function jbench.tick_digest(p_from int, p_n int, p_prefix text default 'J') returns table (conn_id bigint, md5 text, bytes int) language plpgsql as $$
begin
    if p_n > 0 then perform jbench.feed(p_from, p_n, p_prefix); end if;
    perform mc.server_tick();
    return query select * from jbench.digest();
end $$;
