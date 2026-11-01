-- sql/480_inlining.sql changed the implementation (not the result) of hot functions: prove the results are identical to the original definitions.
-- The reference below is the original SQL body of proto.varint / proto.frame (sql/315) evaluated as plain expressions.
create or replace function t.ref_varint(n int) returns bytea language sql immutable as $$
  select case when n >= 0 and n < 128 then set_byte('\x00'::bytea, 0, n)
              when n >= 0 and n < 16384 then set_byte(set_byte('\x0000'::bytea, 0, (n & 127) | 128), 1, n >> 7)
              else proto.varint_slow(n) end $$;
create or replace function t.ref_frame(packet_id int, body bytea) returns bytea language sql immutable as $$
  select case when packet_id >= 0 and packet_id < 128 then t.ref_varint(octet_length(body) + 1) || set_byte('\x00'::bytea, 0, packet_id) || body
              else t.ref_varint(octet_length(proto.varint_slow(packet_id)) + octet_length(body)) || proto.varint_slow(packet_id) || body end $$;

select t.eq('proto.varint is PL/pgSQL (its call sites pass computed arguments)', (select lanname from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = 'proto.varint(int)'::regprocedure), 'plpgsql');
select t.eq('proto.frame is PL/pgSQL', (select lanname from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = 'proto.frame(int,bytea)'::regprocedure), 'plpgsql');
select t.eq('proto.varint equals the original at every boundary and 100k random values', count(*)::int, 0)
  from (select n from (select unnest(array[0, 1, 127, 128, 255, 16383, 16384, 2097151, 2097152, 268435455, 268435456, 2147483647, -1, -128, -2147483648]) n
                       union all select (random() * 4294967295 - 2147483648)::int from generate_series(1, 100000)
                       union all select (random() * 20000)::int from generate_series(1, 100000)) q
         where proto.varint(n) is distinct from t.ref_varint(n)) bad;
select t.eq('proto.frame equals the original for ids 0..300 and body sizes around the VarInt boundaries', count(*)::int, 0)
  from (select id, len from generate_series(0, 300) id, unnest(array[0, 1, 125, 126, 127, 128, 16381, 16382, 16383, 16384, 40000]) len
         where proto.frame(id, decode(repeat('ab', len), 'hex')) is distinct from t.ref_frame(id, decode(repeat('ab', len), 'hex'))) bad;
select t.eq('proto.frame equals the original for large ids and negative ids', count(*)::int, 0)
  from (select id from unnest(array[-1, 127, 128, 16383, 16384, 2097151, 2147483647]) id
         where proto.frame(id, '\x0102'::bytea) is distinct from t.ref_frame(id, '\x0102'::bytea)) bad;
select t.eq('proto.frame still folds to a constant for constant arguments (immutable)', proto.frame(2, '\xaabb'), '\x0302aabb'::bytea);

-- lookups: same answers as the direct subselects, NULL for a missing key, error for an unknown packet exactly as before
select t.eq('mc.prop equals the table', (select count(*)::int from mc.server_property where mc.prop(key) is distinct from value), 0);
select t.eq('mc.prop of a missing key is NULL', mc.prop('no-such-key'), null::text);
select t.eq('mc.prop_int', mc.prop_int('view-distance'), (select value::int from mc.server_property where key = 'view-distance'));
select t.eq('mc.prop_bool', mc.prop_bool('white-list'), (select value::boolean from mc.server_property where key = 'white-list'));
select t.eq('net.setting', net.setting('brand'), (select value from net.setting where key = 'brand'));
select t.eq('net.pkt equals ref.packet for every packet', (select count(*)::int from ref.packet where net.pkt(state, direction, name) is distinct from protocol_id), 0);
select t.eq('net.pkt_name inverts it for every packet', (select count(*)::int from ref.packet where net.pkt_name(state, direction, protocol_id) is distinct from name), 0);
select t.raises('net.pkt of an unknown packet still raises', $$select net.pkt('play', 'clientbound', 'minecraft:no_such_packet')$$);
select t.eq('mc.permission_level of an unknown uuid is 0', mc.permission_level('00000000-0000-0000-0000-000000000001'), 0);
select t.eq('mc.world_ready equals its definition', mc.world_ready(), exists (select 1 from mc.biome) and exists (select 1 from mc.dimension_type));
select t.eq('mc.chat_type_id equals the table', (select count(*)::int from mc.chat_type where mc.chat_type_id(name) is distinct from id), 0);

-- the markings that blocked inlining
select t.eq('proto.string is STABLE (convert_to is STABLE)', (select provolatile::text from pg_proc where oid = 'proto.string(text)'::regprocedure), 's');
select t.eq('proto.string result unchanged', encode(proto.string('héllo ✓'), 'hex'), '0a68c3a96c6c6f20e29c93');
select t.eq('mc.pie_add is STABLE', (select provolatile::text from pg_proc where proname = 'pie_add' and pronamespace = 'mc'::regnamespace), 's');
