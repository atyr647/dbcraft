-- Chat (tsvector + GIN) and inventory (one row per non-empty slot, like dbcraft's mc.inventory_slot).

create function mc.reset_chat() returns void language sql as $$ truncate mc.chat restart identity $$;

create function mc.chat_add(sender int, msg text, at bigint) returns bigint language sql as $$
  insert into mc.chat (sender, msg, at) values (sender, msg, at) returning id $$;

create function mc.chat_add_bulk(senders int[], msgs text[], ats bigint[]) returns bigint language sql as $$
  with ins as (insert into mc.chat (sender, msg, at)
               select t.s, t.m, t.a from unnest(senders, msgs, ats) with ordinality as t(s, m, a, o) order by t.o
               returning id)
  select max(id) from ins $$;

-- whole lower-case tokens, newest first
create function mc.chat_search(word text, lim int) returns table(id bigint) language sql stable as $$
  select c.id from mc.chat c where c.tsv @@ plainto_tsquery('simple', word) order by c.id desc limit lim $$;

create function mc.chat_recent(lim int) returns table(id bigint) language sql stable as $$
  select c.id from mc.chat c order by c.id desc limit lim $$;

create function mc.chat_count_by_sender() returns table(sender int, n bigint) language sql stable as $$
  select c.sender, count(*) from mc.chat c group by c.sender $$;

------------------------------------------------------------------------------------------------ inventory
create function mc.reset_inv() returns void language sql as $$ truncate mc.inv $$;

create function mc.max_stack(item int) returns int language sql immutable parallel safe as $$
  select case when item < 100 then 64 when item < 180 then 16 else 1 end $$;

create function mc.inv_seed(n int) returns void language sql as $$
  insert into mc.inv (player, slot, item, count)
  select p, s, i.item, 1 + mc.hash2(p, s, 11) % mc.max_stack(i.item)
    from generate_series(1, n) p, generate_series(5, 44) s, lateral (select 1 + mc.hash2(p, s, 10) % 199 as item) i
   where mc.hash2(p, s, 9) % 100 < 70 $$;

create function mc.inv_click(p_player int, p_op text, a int, b int) returns void language plpgsql as $$
declare
    ia int; ca int; ib int; cb int;
    ms int; mv int; rem int;
    lo int; hi int;
    slots int[]; items int[]; cnts int[];
    j int; s int;
begin
    if p_op = 'swap' or p_op = 'merge' then
        if a = b then return; end if;
        select max(item) filter (where slot = a), max(count) filter (where slot = a), max(item) filter (where slot = b), max(count) filter (where slot = b)
          into ia, ca, ib, cb from mc.inv where player = p_player and slot in (a, b);
        if p_op = 'merge' then
            if ia is null then return; end if;
            if ib = ia then
                ms := mc.max_stack(ia);
                mv := least(ca, ms - cb);
                if mv > 0 then
                    update mc.inv set count = cb + mv where player = p_player and slot = b;
                    if ca - mv = 0 then delete from mc.inv where player = p_player and slot = a;
                    else update mc.inv set count = ca - mv where player = p_player and slot = a; end if;
                end if;
                return;
            end if;
        end if;
        -- swap (also the merge of different items): exchange the two slots
        if ia is null and ib is null then return; end if;
        if ia is not null and ib is not null then
            update mc.inv set item = case when slot = a then ib else ia end, count = case when slot = a then cb else ca end
             where player = p_player and slot in (a, b);
        elsif ia is not null then
            update mc.inv set slot = b where player = p_player and slot = a;
        else
            update mc.inv set slot = a where player = p_player and slot = b;
        end if;
    elsif p_op = 'quick' then
        select item, count into ia, ca from mc.inv where player = p_player and slot = a;
        if ia is null then return; end if;
        if a between 9 and 35 then lo := 36; hi := 44;
        elsif a between 36 and 44 then lo := 9; hi := 35;
        else return; end if;
        ms := mc.max_stack(ia);
        rem := ca;
        select array_agg(slot::int order by slot), array_agg(item order by slot), array_agg(count order by slot) into slots, items, cnts
          from mc.inv where player = p_player and slot between lo and hi;
        -- pass 1: top up slots holding the same item
        for j in 1 .. coalesce(cardinality(slots), 0) loop
            exit when rem = 0;
            if items[j] = ia and cnts[j] < ms then
                mv := least(rem, ms - cnts[j]);
                update mc.inv set count = cnts[j] + mv where player = p_player and slot = slots[j];
                rem := rem - mv;
            end if;
        end loop;
        -- pass 2: the first empty target slot takes the rest (up to max_stack)
        if rem > 0 then
            for s in lo .. hi loop
                if slots is null or not (s = any (slots)) then
                    mv := least(rem, ms);
                    insert into mc.inv (player, slot, item, count) values (p_player, s, ia, mv);
                    rem := rem - mv;
                    exit;
                end if;
            end loop;
        end if;
        if rem <> ca then
            if rem = 0 then delete from mc.inv where player = p_player and slot = a;
            else update mc.inv set count = rem where player = p_player and slot = a; end if;
        end if;
    elsif p_op = 'drop' then
        select count into ca from mc.inv where player = p_player and slot = a;
        if ca is null then return; end if;
        mv := least(b, ca);
        if mv <= 0 then return; end if;
        if ca - mv = 0 then delete from mc.inv where player = p_player and slot = a;
        else update mc.inv set count = ca - mv where player = p_player and slot = a; end if;
    end if;
end $$;

-- the clicks run sequentially, in array order, inside this one call
create function mc.inv_clicks_bulk(players int[], ops text[], a int[], b int[]) returns void language plpgsql as $$
declare i int;
begin
    for i in 1 .. coalesce(cardinality(players), 0) loop
        perform mc.inv_click(players[i], ops[i], a[i], b[i]);
    end loop;
end $$;

create function mc.inv_load(p_player int) returns table(slot int, item int, count int) language sql stable as $$
  select i.slot::int, i.item, i.count from mc.inv i where i.player = p_player order by i.slot $$;

create function mc.inv_digest() returns bigint language sql stable as $$
  select coalesce(sum(player::bigint * 1000003 + slot::bigint * 8191 + item::bigint * 131 + count::bigint * 7 + player::bigint * slot * 3), 0)::bigint from mc.inv $$;
