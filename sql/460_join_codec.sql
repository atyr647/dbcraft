-- Login-path speed, round 1: functions that every per-packet handler calls, re-implemented so Postgres does not PLAN them on every call.
--
-- Measured (docs/PERF-JOIN.md, tests/bench/join/): a `language sql` function that Postgres cannot inline (CTEs, OUT parameters, DML, void result) is
-- planned again each time a PL/pgSQL caller runs it:
--     proto.varint_read   158 us per call from PL/pgSQL  ->  3.4 us as PL/pgSQL (46x)
--     proto.string_read   208 us                         ->  ~6 us
--     net.send            603 us                         ->  15 us   (the same INSERT written in PL/pgSQL, plan cached for the session)
-- Behaviour is byte-for-byte and error-for-error identical to the originals (tests/sql/460_join_codec.sql compares them on random and malformed input).
-- Nothing here changes what is sent.

------------------------------------------------------------------------------------------------ proto.varint_read / string_read
-- Same contract as sql/020_proto.sql: (NULL, NULL) when the buffer ends inside the VarInt; raises (22P03) for a VarInt longer than 5 bytes, a fifth byte above 15,
-- and overlong forms (a multi-byte value whose last group is 0).
create or replace function proto.varint_read(b bytea, off int default 0, out val int, out nxt int)
language plpgsql immutable parallel safe as $$
declare len int := length(b); c int; u bigint := 0; i int := 0; sh int := 0;
begin
    loop
        if off is null or off + i >= len then val := null; nxt := null; return; end if;   -- (null offset: a caller that read past the end; without this the loop never ends)
        c := get_byte(b, off + i);
        if i = 4 and c >= 16 then perform proto.bad('VarInt too long or fifth byte out of range'); end if;
        u := u | ((c & 127)::bigint << sh);
        i := i + 1;
        if c < 128 then
            if i > 1 and c = 0 then perform proto.bad('overlong VarInt'); end if;
            exit;
        end if;
        sh := sh + 7;
    end loop;
    val := case when u >= 2147483648 then (u - 4294967296)::int else u::int end;
    nxt := off + i;
end $$;

-- Same contract as sql/020_proto.sql: no bounds check on the length (callers use net.need), a negative length raises, invalid UTF-8 raises.
create or replace function proto.string_read(b bytea, off int default 0, out val text, out nxt int)
language plpgsql immutable parallel safe as $$
declare n int; o int;
begin
    select r.val, r.nxt into n, o from proto.varint_read(b, off) r;
    if n is null then return; end if;
    val := convert_from(substring(b from o + 1 for n), 'UTF8');
    nxt := o + n;
end $$;

------------------------------------------------------------------------------------------------ net.send / net.close / net.need / net.on_connect
-- Queue one packet for a connection (plan cached; the SQL-language original was re-planned on every call).
create or replace function net.send(p_conn bigint, p_packet_id int, p_body bytea default '\x') returns void language plpgsql as $$
begin
    insert into net.outbox(conn_id, data)
    select p_conn, net.frame(c.compression, p_packet_id, p_body) from net.conn c where c.conn_id = p_conn;
end $$;
-- ... by packet name, in the connection's current state.
create or replace function net.send(p_conn bigint, p_name text, p_body bytea) returns void language plpgsql as $$
begin
    insert into net.outbox(conn_id, data)
    select p_conn, net.frame(c.compression, net.pkt(c.state_for_send, 'clientbound', p_name), p_body)
    from (select conn_id, compression, case state when 'login_ack' then 'login' else state end as state_for_send from net.conn where conn_id = p_conn) c;
end $$;

create or replace function net.close(p_conn bigint) returns void language plpgsql as $$
begin
    update net.conn set closing = true where conn_id = p_conn;
end $$;

-- Raise when the buffer is shorter than a field needs (truncated packet).
create or replace function net.need(body bytea, upto int) returns void language plpgsql as $$
begin
    if upto > length(body) then perform proto.bad('truncated packet'); end if;
end $$;

create or replace function net.on_connect(p_conn bigint, p_ip inet) returns void language plpgsql as $$
begin
    insert into net.conn (conn_id, compression, ip) values (p_conn, -1, p_ip) on conflict (conn_id) do nothing;
end $$;
