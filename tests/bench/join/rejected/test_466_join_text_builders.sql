-- sql/465 + sql/466: the NBT / text component builders give the same bytes as the originals.  The reference is the ORIGINAL SOURCE (sql/110_nbt.sql and sql/300_game_nbt.sql
-- are run again, which reinstalls the original functions); the new ones are run before and again after, and every result is compared row by row.
\ir ../../sql/465_join_text.sql
\ir ../../sql/466_join_text_builders.sql

-- random inputs: text from ASCII, Latin-1, CJK, symbols and supplementary characters (including NULL and empty), and arrays of them with NULL elements.
-- Every length is a column of the outer row (a generate_series whose arguments do not depend on the row would be evaluated once and reused).
create table t.in466 as
select s.id, s.s,
       array(select (array['a', 'Zed', '0', ' ', '_', ':', 'é', 'ß', '日本', '✓', '😀', '𝄞', null, ''])[1 + floor(random() * 14)::int] from generate_series(1, s.n) k) as items,
       array(select case when random() < 0.15 then null else (floor(random() * 4294967296) - 2147483648)::int end from generate_series(1, s.n) k) as ints,
       array(select case when random() < 0.15 then null else decode(lpad(to_hex((random() * 65535)::int), 4, '0'), 'hex') end from generate_series(1, s.n) k) as parts,
       (case when s.id % 17 = 0 then null else ('00000000-0000-0000-0000-' || lpad(to_hex(s.id), 12, '0'))::uuid end) as u,
       s.n
from (select g as id, floor(random() * 7)::int as n,
             case when g % 23 = 0 then null
                  else (select coalesce(string_agg((array['a', 'Z', '0', ' ', '_', ':', 'é', 'ß', 'Ä', '日', '本', '✓', '€', '😀', '𝄞'])[1 + floor(random() * 15)::int], ''), '') from generate_series(1, floor(random() * 14)::int + (g * 0)) k) end as s
      from generate_series(1, 6000) g) s;
-- special cases
insert into t.in466 values (100001, null, null, null, null, null, 0), (100002, '', '{}', '{}', '{}', '00000000-0000-0000-0000-000000000001', 0),
                           (100003, 'Zoë日😀', array['x', null, 'y'], array[1, null, 3], array['\x01'::bytea, null, '\x02'], '00000000-0000-0000-0000-000000000002', 3);
select t.is_true('the random inputs vary in length and content', (select count(distinct length(s)) >= 10 and count(distinct coalesce(array_length(items, 1), -1)) >= 7 and count(*) filter (where s ~ '[\U00010000-\U0010FFFF]') > 100 from t.in466));

create or replace function t.run466() returns table (id int, r text) language sql as $$
    select i.id, md5(concat_ws('|',
        encode(proto.nbt_text(i.s), 'hex'),
        encode(nbt.str(coalesce(i.s, '')), 'hex'),
        encode(nbt.text_literal(coalesce(i.s, '')), 'hex'),       -- (nbt.mutf8(NULL) raises, in the original and in the wrapper: not an input)
        encode(proto.cat(i.parts), 'hex'),
        encode(proto.nbt_int_array('ints', i.ints), 'hex'),
        encode(proto.nbt_list_str('with', i.items), 'hex'),
        encode(proto.nbt_list_comp('with', i.parts), 'hex'),
        encode(proto.nbt_str('text', i.s), 'hex'),
        encode(proto.nbt_comp('hover_event', proto.nbt_str('name', i.s), proto.nbt_str('id', 'minecraft:player')), 'hex'),
        encode(mc.tc_player(i.u, i.s), 'hex'),
        encode(mc.tc_translate('multiplayer.player.joined', array[mc.tc_player(i.u, i.s)], 'yellow'), 'hex'),
        encode(mc.tc_translate('k', null, null), 'hex'),
        encode(mc.tc_translate_strs('commands.time.set', i.items), 'hex'),
        encode(mc.tc_text(i.s, 'red'), 'hex'),
        encode(mc.pkt_system_chat(proto.nbt_root(mc.tc_translate('multiplayer.player.joined', array[mc.tc_player(i.u, i.s)], 'yellow'))), 'hex'),
        encode(mc.pkt_player_info_add(array[mc.pie_add(i.u, i.s, 0), mc.pie_add(i.u, 'Other', 1)]), 'hex')))
    from t.in466 i order by i.id $$;

create table t.new466 as select * from t.run466();
select t.eq('computed for every input (including the special cases)', (select count(*)::int from t.new466), 6003);

-- reinstall the originals from the source files
\ir ../../sql/110_nbt.sql
\ir ../../sql/300_game_nbt.sql
select t.is_true('the originals are installed (proto.nbt_text has a FROM clause again: it is not inlinable)', (select position('from (select proto.mutf8(s) m) q' in prosrc) > 0 from pg_proc where oid = 'proto.nbt_text(text)'::regprocedure));
create table t.old466 as select * from t.run466();

-- and the new ones again
\ir ../../sql/465_join_text.sql
\ir ../../sql/466_join_text_builders.sql
select t.is_true('the new builders are installed again', (select position('from (select proto.mutf8(s) m) q' in prosrc) = 0 from pg_proc where oid = 'proto.nbt_text(text)'::regprocedure));
create table t.again466 as select * from t.run466();

select t.eq('15 builders x 6,003 inputs: every result of the new code equals the original source''s', (select count(*)::int from t.new466 n join t.old466 o using (id) where n.r is distinct from o.r), 0);
select t.eq('...nothing is missing on either side', (select count(*)::int from t.new466 n full join t.old466 o using (id) where n.id is null or o.id is null), 0);
select t.eq('...and the new code is deterministic (the second run after reinstalling gives the same)', (select count(*)::int from t.new466 n join t.again466 a using (id) where n.r is distinct from a.r), 0);
select t.is_true('...and the results are not all the same (the check can tell inputs apart)', (select count(distinct r) > 5000 from t.new466));
