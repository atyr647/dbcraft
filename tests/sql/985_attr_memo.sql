-- mc.attr_memo (sql/981): the attribute entries of the add_entity bundle of a player with nothing worn or held, kept per (game mode, sprinting, attribute mask), must be exactly what
-- mc.pairing_attrs computes for that player; and mc.pairing_bundle uses it only when the six visible slots are empty (a player with an item goes through mc.pairing_attrs).
truncate mc.attr_memo;
create temp table am_nil (uuid uuid);
insert into am_nil values (md5('am-nobody')::uuid);
select t.eq('a player without inventory rows: memo == mc.pairing_attrs for every game mode, sprint flag and attribute mask',
            (select count(*) filter (where mc.attr_memo(gm, sp, seen) is distinct from mc.pairing_attrs((select uuid from am_nil), 0, gm, sp, seen))::int
               from generate_series(0, 3) gm, (values (false), (true)) s(sp),
                    unnest(array[0::bigint, mc.attr_std_seen(), (1::bigint << 26), (1::bigint << 8) | (1::bigint << 13), (1::bigint << 39) - 1, 123456789::bigint, mc.attr_std_seen() | (1::bigint << 9)]) seen), 0);
select t.eq('...the memo holds one row per combination', (select count(*)::int from mc.attr_memo), 4 * 2 * 7);
select t.eq('...and from the table the second time the answer is the same',
            (select count(*) filter (where mc.attr_memo(gm, sp, seen) is distinct from mc.pairing_attrs((select uuid from am_nil), 0, gm, sp, seen))::int
               from generate_series(0, 3) gm, (values (false), (true)) s(sp),
                    unnest(array[0::bigint, mc.attr_std_seen(), (1::bigint << 26), (1::bigint << 8) | (1::bigint << 13), (1::bigint << 39) - 1, 123456789::bigint, mc.attr_std_seen() | (1::bigint << 9)]) seen), 0);
-- a bundle of a player without items equals the bundle built from mc.pairing_attrs; a player with a helmet does not use the memo
do $$
declare p mc.player; b1 bytea; b2 bytea; a bytea[]; cnt0 bigint;
begin
  truncate net.conn, mc.visible, mc.vtrk; delete from mc.player;
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, gamemode, attr_seen, sprinting) values
    (md5('b1')::uuid, 'b1', 1, 1, 8, 70, 8, 1, mc.attr_std_seen(), false), (md5('b2')::uuid, 'b2', 2, 2, 9, 70, 9, 0, mc.attr_std_seen() | (1::bigint << 9), true);
  update mc.player set fresh_join = false where conn_id in (1, 2);
  for p in select * from mc.player order by conn_id loop
    b1 := mc.pairing_bundle(p);
    a := mc.pairing_attrs(p.uuid, p.held_slot, coalesce(p.attr_gm, p.gamemode), p.sprinting, p.attr_seen);
    if not exists (select 1 from regexp_matches(encode(b1, 'hex'), encode(mc.pkt_update_attributes(p.entity_id, a), 'hex'))) then raise exception 'FAIL the bundle of player % does not contain the update_attributes packet of mc.pairing_attrs', p.conn_id; end if;
  end loop;
  raise notice 'ok   the bundles of two players without items contain exactly the update_attributes packet of mc.pairing_attrs';
  -- a helmet: the generic path (the memo is not consulted: its table does not grow)
  insert into mc.inventory_slot (player, slot, item, count) values (md5('b1')::uuid, 5, 'minecraft:iron_helmet', 1) on conflict (player, slot) do update set item = excluded.item;
  select count(*) into cnt0 from mc.attr_memo;
  select * into p from mc.player where conn_id = 1;
  b2 := mc.pairing_bundle(p);
  a := mc.pairing_attrs(p.uuid, p.held_slot, coalesce(p.attr_gm, p.gamemode), p.sprinting, p.attr_seen);
  if cardinality(a) < 3 or encode(b2, 'hex') not like '%' || encode(mc.pkt_update_attributes(p.entity_id, a), 'hex') || '%' then raise exception 'FAIL a player with a helmet: the bundle does not carry its attributes'; end if;
  if (select count(*) from mc.attr_memo) <> cnt0 then raise exception 'FAIL a player with an item went through the memo'; end if;
  raise notice 'ok   a player with a helmet gets its own attributes (the armor modifiers), not the memo';
end $$;
