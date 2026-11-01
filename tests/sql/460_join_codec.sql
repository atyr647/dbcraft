-- sql/460: the PL/pgSQL decoders and send functions must behave exactly like the SQL originals (sql/020, sql/100, sql/120): same results, same NULLs on incomplete
-- input, same errors on malformed input.  The originals are copied below as t.*_ref (exact bodies); random and hand-made malformed inputs go through both.
\ir ../../sql/460_join_codec.sql

create or replace function t.varint_read_ref(b bytea, off int default 0, out val int, out nxt int)
language sql immutable parallel safe as $$
  with x as (select
      (case when off     < length(b) then get_byte(b, off)     end)::bigint as b0,
      (case when off + 1 < length(b) then get_byte(b, off + 1) end)::bigint as b1,
      (case when off + 2 < length(b) then get_byte(b, off + 2) end)::bigint as b2,
      (case when off + 3 < length(b) then get_byte(b, off + 3) end)::bigint as b3,
      (case when off + 4 < length(b) then get_byte(b, off + 4) end)::bigint as b4),
  y as (select *, case
      when b0 is null then null  when b0 < 128 then 1
      when b1 is null then null  when b1 < 128 then 2
      when b2 is null then null  when b2 < 128 then 3
      when b3 is null then null  when b3 < 128 then 4
      when b4 is null then null  when b4 < 16  then 5
      else proto.bad('VarInt too long or fifth byte out of range')::int end as n from x),
  z as (select n, case
      when n > 1 and (case n when 2 then b1 when 3 then b2 when 4 then b3 else b4 end) = 0 then proto.bad('overlong VarInt')
      else case n when 1 then b0
                  when 2 then (b0 & 127) | (b1 << 7)
                  when 3 then (b0 & 127) | ((b1 & 127) << 7) | (b2 << 14)
                  when 4 then (b0 & 127) | ((b1 & 127) << 7) | ((b2 & 127) << 14) | (b3 << 21)
                  else        (b0 & 127) | ((b1 & 127) << 7) | ((b2 & 127) << 14) | ((b3 & 127) << 21) | (b4 << 28) end
      end as u from y)
  select case when n is null then null when u >= 2147483648 then (u - 4294967296)::int else u::int end,
         case when n is null then null else off + n end
  from z
$$;
create or replace function t.string_read_ref(b bytea, off int default 0, out val text, out nxt int)
language sql immutable parallel safe as $$
  select convert_from(substring(b from r.nxt + 1 for r.val), 'UTF8'), r.nxt + r.val from t.varint_read_ref(b, off) r $$;

-- what a decoder returns for one input: 'val,nxt' or 'ERR sqlstate message'
create or replace function t.vr(b bytea, o int, ref boolean) returns text language plpgsql as $$
begin
    if ref then return (select coalesce(r.val::text, 'null') || ',' || coalesce(r.nxt::text, 'null') from t.varint_read_ref(b, o) r);
    else        return (select coalesce(r.val::text, 'null') || ',' || coalesce(r.nxt::text, 'null') from proto.varint_read(b, o) r); end if;
exception when others then return 'ERR ' || sqlstate || ' ' || sqlerrm;
end $$;
create or replace function t.sr(b bytea, o int, ref boolean) returns text language plpgsql as $$
begin
    if ref then return (select coalesce(r.val, 'null') || ',' || coalesce(r.nxt::text, 'null') from t.string_read_ref(b, o) r);
    else        return (select coalesce(r.val, 'null') || ',' || coalesce(r.nxt::text, 'null') from proto.string_read(b, o) r); end if;
exception when others then return 'ERR ' || sqlstate || ' ' || sqlerrm;
end $$;

-- random buffers, 0 to 7 bytes, biased towards the interesting bytes (continuation bits, zero, the fifth-byte limit 15/16)
-- (the length is a column of the outer row: a generate_series whose arguments do not depend on the outer row would be evaluated once and reused for every row)
create table t.rnd_vi as
select s.id,
       (select coalesce(string_agg(set_byte('\x00'::bytea, 0, (array[0, 1, 15, 16, 127, 128, 129, 255, floor(random() * 256)::int, floor(random() * 256)::int])[1 + floor(random() * 10)::int]), ''::bytea), '\x'::bytea)
          from generate_series(1, s.n) k) as b,
       s.o
from (select g as id, floor(random() * 8)::int as n, floor(random() * 3)::int as o from generate_series(1, 40000) g) s;
select t.is_true('the generated buffers have all lengths 0 to 7', (select count(distinct length(b)) = 8 from t.rnd_vi));
select t.eq('varint_read: 40,000 random buffers (incl. truncated, overlong, too long) give the same value or the same error',
            (select count(*)::int from t.rnd_vi where t.vr(b, o, true) is distinct from t.vr(b, o, false)), 0);
select t.is_true('...and the random set really contains each outcome (value, NULL, error)',
            (select count(*) filter (where t.vr(b, o, true) like 'ERR%') > 100 and count(*) filter (where t.vr(b, o, true) = 'null,null') > 100
                    and count(*) filter (where t.vr(b, o, true) ~ '^-?[0-9]+,[0-9]+$') > 1000 from t.rnd_vi));
select t.eq('varint_read: every 1..5 byte encoding of boundary values, all offsets',
            (select count(*)::int from (select proto.varint(v) as b from unnest(array[0, 1, 127, 128, 255, 16383, 16384, 2097151, 2097152, 268435455, 268435456, 2147483647, -1, -2147483648]) v) q,
                    generate_series(0, 2) o where t.vr('\xaa'::bytea || '\xbb'::bytea || b, o, true) is distinct from t.vr('\xaa'::bytea || '\xbb'::bytea || b, o, false)), 0);
select t.raises('varint_read keeps raising on a negative offset like the original', $$select * from proto.varint_read('\x01'::bytea, -1)$$);
select t.eq('...with the same message', t.vr('\x01'::bytea, -1, true), t.vr('\x01'::bytea, -1, false));

-- strings: a VarInt length then bytes; lengths shorter, equal, longer than the data, negative, multi-byte UTF-8, invalid UTF-8
create table t.rnd_str as
select s.id,
       (array['\x'::bytea, '\x00', '\x01', '\x02', '\x05', '\x7f', '\x8001', '\xffffffff0f', '\x03', '\x0a'])[1 + s.h]
       || (select coalesce(string_agg(set_byte('\x00'::bytea, 0, (array[65, 97, 48, 195, 169, 226, 156, 147, 255, 192, 128, floor(random() * 256)::int])[1 + floor(random() * 12)::int]), ''::bytea), '\x'::bytea)
             from generate_series(1, s.n) k) as b,
       s.o
from (select g as id, floor(random() * 10)::int as h, floor(random() * 12)::int as n, floor(random() * 2)::int as o from generate_series(1, 20000) g) s;
select t.is_true('the generated strings have many different lengths', (select count(distinct length(b)) >= 10 from t.rnd_str));
select t.eq('string_read: 20,000 random buffers (short, long, negative length, invalid UTF-8) give the same value or the same error',
            (select count(*)::int from t.rnd_str where t.sr(b, o, true) is distinct from t.sr(b, o, false)), 0);
select t.is_true('...and the random set contains successes and errors of both kinds',
            (select count(*) filter (where t.sr(b, o, true) like 'ERR%') > 100 and count(*) filter (where t.sr(b, o, true) not like 'ERR%') > 1000 from t.rnd_str));
select t.eq('string_read of hello', (proto.string_read('\x0568656c6c6f'::bytea)).val, 'hello');
select t.eq('string_read next offset', (proto.string_read('\xff0568656c6c6f'::bytea, 1)).nxt, 7);

-- the signatures are unchanged: callers use `select val, nxt into ... from proto.varint_read(...)` and read the OUT columns by name
select t.eq('varint_read has the OUT columns val and nxt', (select proargnames from pg_proc where oid = 'proto.varint_read(bytea,integer)'::regprocedure), array['b', 'off', 'val', 'nxt']);
select t.eq('string_read has the OUT columns val and nxt', (select proargnames from pg_proc where oid = 'proto.string_read(bytea,integer)'::regprocedure), array['b', 'off', 'val', 'nxt']);
select t.eq('both stay immutable and parallel safe', (select count(*)::int from pg_proc where oid in ('proto.varint_read(bytea,integer)'::regprocedure, 'proto.string_read(bytea,integer)'::regprocedure) and provolatile = 'i' and proparallel = 's'), 2);

-- net.send / net.close / net.need / net.on_connect
\ir _net_helpers.sql
create or replace function t.err_state(stmt text) returns text language plpgsql as $$
begin execute stmt; return 'no error'; exception when others then return sqlstate; end $$;
select t.reset_net();
select net.on_connect(7, '10.0.0.7'::inet);
select t.eq('on_connect creates the connection with compression off and the ip', (select (compression, ip::text)::text from net.conn where conn_id = 7), '(-1,10.0.0.7/32)');
select net.on_connect(7, '10.9.9.9'::inet);
select t.eq('on_connect twice keeps the first row', (select ip::text from net.conn where conn_id = 7), '10.0.0.7/32');
select net.send(7, 2, '\xaabb');
select t.eq('send by id queues one framed packet', t.take_hex(7), '0302aabb');
update net.conn set compression = 256 where conn_id = 7;
select net.send(7, 2, '\xaabb');
select t.eq('send on a connection with a threshold uses the small-packet frame', t.take_hex(7), '040002aabb');
select net.send(999, 2, '\xaabb');
select t.eq('send to a connection that does not exist queues nothing', (select count(*)::int from net.outbox), 0);
update net.conn set state = 'status', compression = -1 where conn_id = 7;
select net.send(7, 'minecraft:pong_response', '\x0102030405060708');
select t.eq('send by name in the status state', t.take_hex(7), '0901' || '0102030405060708');
select net.close(7);
select t.eq('close marks the connection closing', (select closing from net.conn where conn_id = 7), true);
select t.eq('need raises the protocol error 22P03 on a short buffer', t.err_state($$select net.need('\x0102'::bytea, 3)$$), '22P03');
select t.eq('need is silent when the buffer is long enough', t.err_state($$select net.need('\x0102'::bytea, 2)$$), 'no error');
