-- Containers, crafting and recipes, part 3: the click engine.
--
-- A line-by-line port of net.minecraft.world.inventory.AbstractContainerMenu (clicked / doClick / moveItemStackTo), Slot (safeInsert, tryRemove, safeTake), InventoryMenu,
-- CraftingMenu, ChestMenu, AbstractFurnaceMenu (quickMoveStack), ResultSlot (onTake), Inventory (add, placeItemBackInInventory) and ServerPlayer's synchronizer, read from the
-- 26.3 bytecode with javap.  It works on a value, mc.mst (sql/860): the open menu's slots loaded from the tables, changed in memory, written back as a diff (sql/863).
-- Every helper takes the state and returns the state; its "return value" is in st.r (a stack) / st.ok.
--
-- What is reproduced on purpose (each of these changes the packets the client receives):
--   * the crafting grid's slotsChanged: a Slot.set / removeItem on a grid cell recomputes the result and SENDS container_set_slot(0, new result) with the next state id,
--     once per change (so taking a result sends one packet per consumed ingredient); an in-place count change (moveItemStackTo merging into a grid slot) sends nothing
--   * what vanilla's broadcastChanges sends after the click: container_set_slot for every slot whose content differs from what the client claimed, set_cursor_item
--     (no state id) for the carried item; a stale state id makes the whole menu be sent again (container_set_content)
--   * Inventory.add's slot order (selected hotbar slot, off hand, then 0..35), placeItemBackInInventory's set_player_inventory packets
-- What is not: bundles, item components that change with use, experience orbs from smelting, the order of a drag over several grid cells (vanilla iterates a HashSet by
-- identity hash; here ascending slot order).

------------------------------------------------------------------------------------------------ packets
create or replace function mc.pkt_cs(cid int, state int, slot int, s mc.stk) returns bytea language sql stable parallel safe as $$
    select mc.cb('container_set_slot', proto.varint(cid) || proto.varint(state) || proto.i16(slot) || mc.s_wire(s)) $$;
create or replace function mc.pkt_cursor(s mc.stk) returns bytea language sql stable parallel safe as $$ select mc.cb('set_cursor_item', mc.s_wire(s)) $$;
create or replace function mc.pkt_spi(slot int, s mc.stk) returns bytea language sql stable parallel safe as $$ select mc.cb('set_player_inventory', proto.varint(slot) || mc.s_wire(s)) $$;
create or replace function mc.pkt_container_close(cid int) returns bytea language sql stable parallel safe as $$ select mc.cb('container_close', proto.varint(cid)) $$;
create or replace function mc.pkt_container_data(cid int, idx int, val int) returns bytea language sql stable parallel safe as $$
    select mc.cb('container_set_data', proto.varint(cid) || proto.i16(idx) || proto.i16(val)) $$;
create or replace function mc.pkt_cc(cid int, state int, items mc.stk[], carried mc.stk) returns bytea language sql stable parallel safe as $$
    select mc.cb('container_set_content', proto.varint(cid) || proto.varint(state) || proto.varint(coalesce(array_length(items, 1), 0))
                 || coalesce((select string_agg(mc.s_wire(t.s), '\x'::bytea order by t.ord) from mc.stk_rows(items) t), '\x'::bytea) || mc.s_wire(carried)) $$;

------------------------------------------------------------------------------------------------ slot access
create or replace function mc.mi_get(st mc.mst, i int) returns mc.stk language sql immutable parallel safe as $$
    select coalesce(case st.s_store[i + 1] when 'inv' then st.inv[st.s_cs[i + 1] + 1] when 'blk' then st.blk[st.s_cs[i + 1] + 1]
                                          when 'grid' then st.grid[st.s_cs[i + 1] + 1] when 'res' then st.result end, mc.s_empty()) $$;

-- write without any event (Container.setItem on a plain container; or the in-place count change vanilla does on the live stack object)
create or replace function mc.mi_put(st mc.mst, i int, s mc.stk) returns mc.mst language plpgsql immutable parallel safe as $$
declare v mc.stk := case when mc.s_is_empty(s) then mc.s_empty() else s end; cs int := st.s_cs[i + 1];
begin
  case st.s_store[i + 1]
    when 'inv' then st.inv[cs + 1] := v;
    when 'blk' then st.blk[cs + 1] := v;
    when 'grid' then st.grid[cs + 1] := v;
    when 'res' then st.result := v;
    else null;
  end case;
  return st;
end $$;

-- the crafting grid of the open menu, row-major
create or replace function mc.mi_grid_items(st mc.mst) returns mc.stk[] language sql immutable parallel safe as $$
    select case st.kind when 'inventory' then array[st.inv[2], st.inv[3], st.inv[4], st.inv[5]] when 'crafting' then st.grid else '{}'::mc.stk[] end $$;

-- ServerPlayer / CraftingMenu.slotChangedCraftingGrid: recompute the result, force the remote copy, send container_set_slot(0, result) with the next state id
create or replace function mc.mi_fire(st mc.mst) returns mc.mst language plpgsql stable as $$
declare g mc.stk[]; items text[]; comps text[]; ritems text[]; rid text; res mc.stk;
begin
  if st.kind not in ('inventory', 'crafting') then return st; end if;
  g := mc.mi_grid_items(st);
  select array_agg(case when mc.s_is_empty(t.s) then null else (t.s).item end order by t.ord),
         array_agg((t.s).item order by t.ord) filter (where not mc.s_is_empty(t.s)), array_agg((t.s).comp order by t.ord) filter (where not mc.s_is_empty(t.s))
    into items, ritems, comps from mc.stk_rows(g) t;
  rid := mc.craft_match(st.grid_w, st.grid_w, items);
  res := case when rid is null then mc.s_empty() else mc.craft_result(rid, ritems, comps) end;
  st.result := res; st.rem0 := res;
  st.state_id := (st.state_id + 1) & 32767;
  st.pkts := st.pkts || mc.pkt_cs(st.cid, st.state_id, 0, res);
  return st;
end $$;

------------------------------------------------------------------------------------------------ slot rules (the Slot subclasses)
create or replace function mc.mi_may_place(st mc.mst, i int, s mc.stk) returns boolean language sql stable as $$
    select case st.s_rule[i + 1]
             when 'none' then false
             when 'fuel' then s.item = 'minecraft:bucket' or exists (select 1 from ref.item_def d where d.item = s.item and d.burn_ticks is not null)
             when 'head' then exists (select 1 from ref.item_def d where d.item = s.item and d.equip_slot = 'head')
             when 'chest' then exists (select 1 from ref.item_def d where d.item = s.item and d.equip_slot = 'chest')
             when 'legs' then exists (select 1 from ref.item_def d where d.item = s.item and d.equip_slot = 'legs')
             when 'feet' then exists (select 1 from ref.item_def d where d.item = s.item and d.equip_slot = 'feet')
             else true end $$;
-- Slot.getMaxStackSize(stack): min(the slot's own limit (1 for armor, the container's 99 otherwise), the stack's); the furnace fuel slot holds one bucket
create or replace function mc.mi_slot_max(st mc.mst, i int, s mc.stk) returns int language sql stable as $$
    select case when st.s_rule[i + 1] = 'fuel' and s.item = 'minecraft:bucket' then 1 else least(st.s_max[i + 1], mc.s_max(s.item)) end $$;

create or replace function mc.mi_set(st mc.mst, i int, s mc.stk) returns mc.mst language plpgsql stable as $$   -- Slot.set / setByPlayer
begin
  st := mc.mi_put(st, i, s);
  if st.s_role[i + 1] = 'grid' then st := mc.mi_fire(st); end if;
  return st;
end $$;

-- Slot.remove(amount) = Container.removeItem(slot, amount): ContainerHelper.removeItem splits; the result container gives the whole stack; a grid cell fires
create or replace function mc.mi_remove(st mc.mst, i int, amt int) returns mc.mst language plpgsql stable as $$
declare cur mc.stk := mc.mi_get(st, i); take int;
begin
  if st.s_role[i + 1] = 'craft_result' then st.r := cur; return mc.mi_put(st, i, mc.s_empty()); end if;
  if mc.s_is_empty(cur) or amt <= 0 then st.r := mc.s_empty(); return st; end if;
  take := least(amt, cur.n);
  st.r := mc.s_mk(cur.item, take, cur.comp);
  st := mc.mi_put(st, i, mc.s_mk(cur.item, cur.n - take, cur.comp));
  if st.s_role[i + 1] = 'grid' then st := mc.mi_fire(st); end if;
  return st;
end $$;

-- Slot.tryRemove(count, decrement, player): st.ok = the Optional is present, st.r = the stack
create or replace function mc.mi_try_remove(st mc.mst, i int, cnt int, decr int) returns mc.mst language plpgsql stable as $$
declare cur mc.stk := mc.mi_get(st, i); rr mc.stk;
begin
  st.ok := false; st.r := mc.s_empty();
  if not (mc.mi_may_place(st, i, cur)) and decr < cur.n then return st; end if;          -- allowModification = mayPickup && mayPlace(getItem())
  st := mc.mi_remove(st, i, least(cnt, decr));
  rr := st.r;
  if mc.s_is_empty(rr) then st.r := mc.s_empty(); return st; end if;
  if mc.s_is_empty(mc.mi_get(st, i)) then st := mc.mi_set(st, i, mc.s_empty()); end if;
  st.r := rr; st.ok := true;
  return st;
end $$;

-- Slot.onTake(player, taken): the crafting result consumes the grid; the furnace result awards experience (not modelled)
create or replace function mc.mi_on_take(st mc.mst, i int, taken mc.stk) returns mc.mst language plpgsql stable as $$
begin
  if st.s_role[i + 1] = 'craft_result' then return mc.mi_craft_take(st, taken); end if;
  if st.s_role[i + 1] = 'furnace_result' then return mc.furnace_take(st, taken); end if;
  return st;
end $$;

-- Slot.safeInsert(stack, count): st.r = what is left of the stack
create or replace function mc.mi_safe_insert(st mc.mst, i int, s mc.stk, cnt int) returns mc.mst language plpgsql stable as $$
declare cur mc.stk; ins int;
begin
  if mc.s_is_empty(s) or not mc.mi_may_place(st, i, s) then st.r := s; return st; end if;
  cur := mc.mi_get(st, i);
  ins := least(least(cnt, s.n), mc.mi_slot_max(st, i, s) - coalesce(cur.n, 0));
  if ins <= 0 then st.r := s; return st; end if;
  if mc.s_is_empty(cur) then
    st := mc.mi_set(st, i, mc.s_mk(s.item, ins, s.comp)); s := mc.s_mk(s.item, s.n - ins, s.comp);
  elsif mc.s_same(cur, s) then
    s := mc.s_mk(s.item, s.n - ins, s.comp); st := mc.mi_set(st, i, mc.s_mk(cur.item, cur.n + ins, cur.comp));
  end if;
  st.r := s;
  return st;
end $$;

-- Slot.safeTake(count, decrement, player): st.r = the stack taken (empty when none)
create or replace function mc.mi_safe_take(st mc.mst, i int, cnt int, decr int) returns mc.mst language plpgsql stable as $$
declare rr mc.stk;
begin
  st := mc.mi_try_remove(st, i, cnt, decr);
  if st.ok then rr := st.r; st := mc.mi_on_take(st, i, rr); st.r := rr; else st.r := mc.s_empty(); end if;
  return st;
end $$;

------------------------------------------------------------------------------------------------ the player's inventory (Inventory.add and friends)
-- inventory-menu slot numbers: 36..44 are Inventory 0..8 (the hotbar), 9..35 the same, 45 the off hand (Inventory 40)
create or replace function mc.inv_index(menu_slot int) returns int language sql immutable parallel safe as $$
    select case when menu_slot >= 36 and menu_slot <= 44 then menu_slot - 36 when menu_slot = 45 then 40 else menu_slot end $$;

create or replace function mc.mi_has_space(cur mc.stk, s mc.stk) returns boolean language sql stable parallel safe as $$     -- Inventory.hasRemainingSpaceForItem
    select not mc.s_is_empty(cur) and mc.s_same(cur, s) and mc.s_max(cur.item) > 1 and cur.n < mc.s_max(cur.item) $$;
-- Inventory.getSlotWithRemainingSpace: the selected slot, the off hand, then 0..35 (menu numbering); -1 = none
create or replace function mc.mi_slot_with_space(st mc.mst, s mc.stk) returns int language plpgsql stable as $$
declare k int;
begin
  if mc.mi_has_space(st.inv[36 + st.held + 1], s) then return 36 + st.held; end if;
  if mc.mi_has_space(st.inv[46], s) then return 45; end if;
  for k in 36 .. 44 loop if mc.mi_has_space(st.inv[k + 1], s) then return k; end if; end loop;
  for k in 9 .. 35 loop if mc.mi_has_space(st.inv[k + 1], s) then return k; end if; end loop;
  return -1;
end $$;
create or replace function mc.mi_free_slot(st mc.mst) returns int language plpgsql stable as $$      -- Inventory.getFreeSlot: the first empty of Inventory 0..35
declare k int;
begin
  for k in 36 .. 44 loop if mc.s_is_empty(st.inv[k + 1]) then return k; end if; end loop;
  for k in 9 .. 35 loop if mc.s_is_empty(st.inv[k + 1]) then return k; end if; end loop;
  return -1;
end $$;

-- Inventory.add(stack): st.r = what is left, st.ok = something was added (vanilla: stack count decreased; a creative player's unplaceable stack vanishes)
create or replace function mc.mi_inv_add(st mc.mst, s mc.stk) returns mc.mst language plpgsql stable as $$
declare c_start int; c0 int; slot int; cur mc.stk; free int; mv int;
begin
  st.ok := false; st.r := s;
  if mc.s_is_empty(s) then return st; end if;
  c_start := s.n;
  loop
    c0 := s.n;
    slot := mc.mi_slot_with_space(st, s);
    if slot = -1 then slot := mc.mi_free_slot(st); end if;
    exit when slot = -1;
    cur := st.inv[slot + 1];
    free := mc.s_max(s.item) - coalesce(cur.n, 0);
    mv := least(s.n, free);
    exit when mv <= 0;
    st.inv[slot + 1] := mc.s_mk(s.item, coalesce(cur.n, 0) + mv, s.comp);
    s := mc.s_mk(s.item, s.n - mv, s.comp);
    exit when mc.s_is_empty(s) or s.n >= c0;
  end loop;
  if not mc.s_is_empty(s) and s.n = c_start and st.gm = 1 then st.r := mc.s_empty(); st.ok := true; return st; end if;
  st.r := s; st.ok := mc.s_is_empty(s) or s.n < c_start;
  return st;
end $$;

-- Player.drop(stack, ...): the stack is handed to mc.menu_drop after the click
create or replace function mc.mi_drop(st mc.mst, s mc.stk) returns mc.mst language plpgsql immutable parallel safe as $$
begin
  if not mc.s_is_empty(s) then st.drops := coalesce(st.drops, '{}'::mc.stk[]) || s; end if;
  return st;
end $$;

-- Inventory.placeItemBackInInventory(stack, sendPacket = true): a set_player_inventory packet for every slot that received something; no room: the rest is dropped
create or replace function mc.mi_place_back(st mc.mst, s mc.stk) returns mc.mst language plpgsql stable as $$
declare slot int; cur mc.stk; put int;
begin
  while not mc.s_is_empty(s) loop
    slot := mc.mi_slot_with_space(st, s);
    if slot = -1 then slot := mc.mi_free_slot(st); end if;
    if slot = -1 then st := mc.mi_drop(st, s); exit; end if;
    cur := st.inv[slot + 1];
    put := least(s.n, mc.s_max(s.item) - coalesce(cur.n, 0));
    st.inv[slot + 1] := mc.s_mk(s.item, coalesce(cur.n, 0) + put, s.comp);
    s := mc.s_mk(s.item, s.n - put, s.comp);
    st.pkts := st.pkts || mc.pkt_spi(mc.inv_index(slot), st.inv[slot + 1]);
  end loop;
  return st;
end $$;

------------------------------------------------------------------------------------------------ moveItemStackTo and quickMoveStack
-- AbstractContainerMenu.moveItemStackTo(stack, start, end, reverse): st.r = the stack as it is afterwards (the caller writes it back), st.ok = anything moved
create or replace function mc.mi_move_to(st mc.mst, s mc.stk, a int, b int, rev boolean) returns mc.mst language plpgsql stable as $$
declare moved boolean := false; i int; cur mc.stk; total int; mx int; put int;
begin
  i := case when rev then b - 1 else a end;
  if not mc.s_is_empty(s) and mc.s_max(s.item) > 1 then
    while not mc.s_is_empty(s) and (case when rev then i >= a else i < b end) loop
      cur := mc.mi_get(st, i);
      if not mc.s_is_empty(cur) and mc.s_same(s, cur) then
        total := cur.n + s.n; mx := mc.mi_slot_max(st, i, cur);
        if total <= mx then
          s := mc.s_empty(); st := mc.mi_put(st, i, mc.s_mk(cur.item, total, cur.comp)); moved := true;
        elsif cur.n < mx then
          s := mc.s_mk(s.item, s.n - (mx - cur.n), s.comp); st := mc.mi_put(st, i, mc.s_mk(cur.item, mx, cur.comp)); moved := true;
        end if;
      end if;
      i := i + case when rev then -1 else 1 end;
    end loop;
  end if;
  if not mc.s_is_empty(s) then
    i := case when rev then b - 1 else a end;
    while (case when rev then i >= a else i < b end) loop
      cur := mc.mi_get(st, i);
      if mc.s_is_empty(cur) and mc.mi_may_place(st, i, s) then
        put := least(s.n, mc.mi_slot_max(st, i, s));
        st := mc.mi_set(st, i, mc.s_mk(s.item, put, s.comp));
        s := mc.s_mk(s.item, s.n - put, s.comp); moved := true;
        exit;
      end if;
      i := i + case when rev then -1 else 1 end;
    end loop;
  end if;
  st.r := s; st.ok := moved;
  return st;
end $$;

-- the part every quickMoveStack ends with: write the stack back, the slot empties or is marked changed; nothing moved = EMPTY; the slot's onTake
-- (st.aux = 1 when the caller has to drop what is left, the crafting result)
create or replace function mc.mi_quick_tail(st mc.mst, i int, stk mc.stk, orig mc.stk, with_take boolean) returns mc.mst language plpgsql stable as $$
begin
  st := mc.mi_put(st, i, stk);                                                          -- (the stack IS the slot's: moveItemStackTo changed it in place)
  if mc.s_is_empty(stk) then st := mc.mi_set(st, i, mc.s_empty()); end if;
  if with_take then
    if coalesce(stk.n, 0) = orig.n then st.r := mc.s_empty(); return st; end if;
    st := mc.mi_on_take(st, i, stk);
  end if;
  st.r := orig;
  return st;
end $$;

-- AbstractContainerMenu.quickMoveStack(player, index) of the open menu: st.r = the copy of the slot's stack before the move (empty: nothing was moved)
create or replace function mc.mi_quick_move(st mc.mst, i int) returns mc.mst language plpgsql stable as $$
declare orig mc.stk; stk mc.stk; eq text; tgt int; n int := array_length(st.s_store, 1); rows int; ok boolean;
begin
  stk := mc.mi_get(st, i); st.r := mc.s_empty();
  if mc.s_is_empty(stk) then return st; end if;
  orig := stk;
  if st.kind = 'inventory' then
    select d.equip_slot into eq from ref.item_def d where d.item = stk.item;
    if i = 0 then
      st := mc.mi_move_to(st, stk, 9, 45, true); if not st.ok then st.r := mc.s_empty(); return st; end if;
    elsif i between 1 and 8 then
      st := mc.mi_move_to(st, stk, 9, 45, false); if not st.ok then st.r := mc.s_empty(); return st; end if;
    elsif eq in ('head', 'chest', 'legs', 'feet') and mc.s_is_empty(mc.mi_get(st, case eq when 'head' then 5 when 'chest' then 6 when 'legs' then 7 else 8 end)) then
      tgt := case eq when 'head' then 5 when 'chest' then 6 when 'legs' then 7 else 8 end;
      st := mc.mi_move_to(st, stk, tgt, tgt + 1, false); if not st.ok then st.r := mc.s_empty(); return st; end if;
    elsif eq = 'offhand' and mc.s_is_empty(mc.mi_get(st, 45)) then
      st := mc.mi_move_to(st, stk, 45, 46, false); if not st.ok then st.r := mc.s_empty(); return st; end if;
    elsif i between 9 and 35 then
      st := mc.mi_move_to(st, stk, 36, 45, false); if not st.ok then st.r := mc.s_empty(); return st; end if;
    elsif i between 36 and 44 then
      st := mc.mi_move_to(st, stk, 9, 36, false); if not st.ok then st.r := mc.s_empty(); return st; end if;
    else
      st := mc.mi_move_to(st, stk, 9, 45, false); if not st.ok then st.r := mc.s_empty(); return st; end if;
    end if;
    stk := st.r;
    st := mc.mi_quick_tail(st, i, stk, orig, true);
    if i = 0 and not mc.s_is_empty(stk) then st := mc.mi_drop(st, stk); end if;      -- ResultSlot: what did not fit is dropped (Player.drop(stack, false))
    return st;
  elsif st.kind = 'crafting' then
    if i = 0 then
      st := mc.mi_move_to(st, stk, 10, 46, true); if not st.ok then st.r := mc.s_empty(); return st; end if;
    elsif i >= 10 and i < 46 then
      st := mc.mi_move_to(st, stk, 1, 10, false);
      if not st.ok then
        stk := st.r;
        if i < 37 then st := mc.mi_move_to(st, stk, 37, 46, false); else st := mc.mi_move_to(st, stk, 10, 37, false); end if;
        if not st.ok then st.r := mc.s_empty(); return st; end if;
      end if;
    else
      st := mc.mi_move_to(st, stk, 10, 46, false); if not st.ok then st.r := mc.s_empty(); return st; end if;
    end if;
    stk := st.r;
    st := mc.mi_quick_tail(st, i, stk, orig, true);
    if i = 0 and not mc.s_is_empty(stk) then st := mc.mi_drop(st, stk); end if;
    return st;
  elsif st.kind like 'generic_9x%' then
    rows := substr(st.kind, 11)::int;
    if i < rows * 9 then st := mc.mi_move_to(st, stk, rows * 9, n, true); else st := mc.mi_move_to(st, stk, 0, rows * 9, false); end if;
    if not st.ok then st.r := mc.s_empty(); return st; end if;
    stk := st.r;
    return mc.mi_quick_tail(st, i, stk, orig, false);                                    -- ChestMenu: no count comparison, no onTake
  elsif st.kind in ('furnace', 'blast_furnace', 'smoker') then
    if i = 2 then
      st := mc.mi_move_to(st, stk, 3, 39, true); if not st.ok then st.r := mc.s_empty(); return st; end if;
    elsif i = 1 or i = 0 then
      st := mc.mi_move_to(st, stk, 3, 39, false); if not st.ok then st.r := mc.s_empty(); return st; end if;
    elsif mc.furnace_can_smelt(st.kind, stk.item) then
      st := mc.mi_move_to(st, stk, 0, 1, false); if not st.ok then st.r := mc.s_empty(); return st; end if;
    elsif exists (select 1 from ref.item_def d where d.item = stk.item and d.burn_ticks is not null) then
      st := mc.mi_move_to(st, stk, 1, 2, false); if not st.ok then st.r := mc.s_empty(); return st; end if;
    elsif i >= 3 and i < 30 then
      st := mc.mi_move_to(st, stk, 30, 39, false); if not st.ok then st.r := mc.s_empty(); return st; end if;
    elsif i >= 30 and i < 39 then
      st := mc.mi_move_to(st, stk, 3, 30, false); if not st.ok then st.r := mc.s_empty(); return st; end if;
    else
      st.ok := true; st.r := stk;                                                        -- (no branch: the stack is unchanged, the tail compares counts)
    end if;
    stk := st.r;
    return mc.mi_quick_tail(st, i, stk, orig, true);
  end if;
  return st;
end $$;

-- ResultSlot.onTake: consume one of every ingredient (a remainder item takes its cell or goes to the inventory), one grid change per step
create or replace function mc.mi_craft_take(st mc.mst, taken mc.stk) returns mc.mst language plpgsql stable as $$
declare w int := st.grid_w; g mc.stk[]; minx int := 99; maxx int := -1; miny int := 99; maxy int := -1; x int; y int; tw int; th int; names text[] := '{}'; rid text;
        rem text[] := '{}'; cell int; cur mc.stk; remainder mc.stk; k int;
begin
  g := mc.mi_grid_items(st);
  for y in 0 .. w - 1 loop for x in 0 .. w - 1 loop
    if not mc.s_is_empty(g[y * w + x + 1]) then minx := least(minx, x); maxx := greatest(maxx, x); miny := least(miny, y); maxy := greatest(maxy, y); end if;
    names := names || (case when mc.s_is_empty(g[y * w + x + 1]) then null else (g[y * w + x + 1]).item end);
  end loop; end loop;
  if maxx < 0 then return st; end if;
  tw := maxx - minx + 1; th := maxy - miny + 1;
  rid := mc.craft_match(w, w, names);
  -- the remainders, taken from the grid as it is NOW (before any consumption); no recipe: nothing is handed back
  for y in miny .. maxy loop for x in minx .. maxx loop
    rem := rem || (case when rid is null or names[y * w + x + 1] is null then null else (select d.remainder from ref.item_def d where d.item = names[y * w + x + 1]) end);
  end loop; end loop;
  k := 0;
  for y in 0 .. th - 1 loop
    for x in 0 .. tw - 1 loop
      k := k + 1;
      cell := (x + minx) + (y + miny) * w;                                              -- grid cell; the menu slot is cell + 1
      cur := mc.mi_get(st, cell + 1);
      remainder := mc.s_mk(rem[k], 1, null);
      if not mc.s_is_empty(cur) then
        st := mc.mi_remove(st, cell + 1, 1);                                            -- CraftingContainer.removeItem(cell, 1): a grid change
        cur := mc.mi_get(st, cell + 1);
      end if;
      if not mc.s_is_empty(remainder) then
        if mc.s_is_empty(cur) then st := mc.mi_set(st, cell + 1, remainder);
        elsif mc.s_same(cur, remainder) then st := mc.mi_set(st, cell + 1, mc.s_mk(remainder.item, remainder.n + cur.n, remainder.comp));
        else
          st := mc.mi_inv_add(st, remainder);
          if not st.ok then st := mc.mi_drop(st, remainder); end if;                    -- (vanilla drops only when nothing at all was added)
        end if;
      end if;
    end loop;
  end loop;
  return st;
end $$;

-- may the furnace of this menu kind smelt the item (RecipePropertySet.test: some recipe of the kind's type has an ingredient that accepts it)
create or replace function mc.furnace_can_smelt(p_kind text, p_item text) returns boolean language sql stable as $$
    select exists (select 1 from ref.recipe r join ref.ingredient i on i.id = r.ingredient
                    where r.type = case p_kind when 'blast_furnace' then 'blasting' when 'smoker' then 'smoking' else 'smelting' end and p_item = any (i.items)) $$;
-- taking a furnace result: experience would be awarded here (orbs are not modelled), see sql/866
create or replace function mc.furnace_take(st mc.mst, taken mc.stk) returns mc.mst language plpgsql immutable as $$ begin st.aux := 1; return st; end $$;

------------------------------------------------------------------------------------------------ doClick
create or replace function mc.mi_quickcraft_count(n_slots int, qtype int, s mc.stk) returns int language sql immutable parallel safe as $$
    select case qtype when 0 then floor(s.n::real / n_slots::real)::int when 1 then 1 when 2 then mc.s_max(s.item) else s.n end $$;
-- AbstractContainerMenu.canItemQuickReplace(slot, stack, includeStackSize)
create or replace function mc.mi_can_replace(st mc.mst, i int, s mc.stk, flag boolean) returns boolean language sql stable as $$
    select case when mc.s_is_empty(mc.mi_get(st, i)) then true
                else mc.s_same(mc.mi_get(st, i), s) and (mc.mi_get(st, i)).n + (case when flag then 0 else s.n end) <= mc.s_max(s.item) end $$;

-- AbstractContainerMenu.doClick(slotIndex, button, input, player); input: the ordinal of ContainerInput (0 PICKUP, 1 QUICK_MOVE, 2 SWAP, 3 CLONE, 4 THROW, 5 QUICK_CRAFT, 6 PICKUP_ALL)
create or replace function mc.mi_click(st mc.mst, slot int, button int, input int) returns mc.mst language plpgsql stable as $$
declare prev int; cur mc.stk; car mc.stk; rem mc.stk; n_slots int := array_length(st.s_store, 1); qi int; c int; cnt int; existing int; mxs int; place int; copy_ mc.stk;
        hot mc.stk; sl mc.stk; mx int; k int; pass int; start_ int; step int; r mc.stk; origcar int; q_slots int[];
begin
  -- ------------------------------------------------------------------ QUICK_CRAFT (a drag)
  if input = 5 then
    prev := st.qc_status; st.qc_status := button & 3;
    if not ((prev = 1 and st.qc_status = 2) or prev = st.qc_status) then
      st.qc_status := 0; st.qc_slots := '{}';
    elsif mc.s_is_empty(st.carried) then
      st.qc_status := 0; st.qc_slots := '{}';
    elsif st.qc_status = 0 then
      st.qc_type := (button >> 2) & 3;
      if st.qc_type = 0 or st.qc_type = 1 or (st.qc_type = 2 and st.gm = 1) then st.qc_status := 1; st.qc_slots := '{}'; else st.qc_status := 0; st.qc_slots := '{}'; end if;
    elsif st.qc_status = 1 then
      car := st.carried;
      if slot >= 0 and slot < n_slots and mc.mi_can_replace(st, slot, car, true) and mc.mi_may_place(st, slot, car)
         and (st.qc_type = 2 or car.n > coalesce(array_length(st.qc_slots, 1), 0)) and not (slot = any (st.qc_slots)) then
        st.qc_slots := st.qc_slots || slot;
      end if;
    elsif st.qc_status = 2 then
      q_slots := st.qc_slots;
      if coalesce(array_length(q_slots, 1), 0) > 0 then
        if array_length(q_slots, 1) = 1 then
          qi := q_slots[1]; st.qc_status := 0; st.qc_slots := '{}';
          return mc.mi_click(st, qi, st.qc_type, 0);                                    -- one slot: an ordinary click (button = the drag type)
        end if;
        copy_ := st.carried;
        if mc.s_is_empty(copy_) then st.qc_status := 0; st.qc_slots := '{}'; return st; end if;
        cnt := copy_.n;
        select array_agg(x order by x) into q_slots from unnest(q_slots) x;            -- vanilla: HashSet order; here ascending
        foreach qi in array q_slots loop
          car := st.carried;
          if mc.mi_can_replace(st, qi, car, true) and mc.mi_may_place(st, qi, car)
             and (st.qc_type = 2 or car.n >= array_length(q_slots, 1)) then
            existing := (mc.mi_get(st, qi)).n; existing := coalesce(existing, 0);
            mxs := least(mc.s_max(copy_.item), mc.mi_slot_max(st, qi, copy_));
            place := least(mc.mi_quickcraft_count(array_length(q_slots, 1), st.qc_type, copy_) + existing, mxs);
            cnt := cnt - (place - existing);
            st := mc.mi_set(st, qi, mc.s_mk(copy_.item, place, copy_.comp));
          end if;
        end loop;
        st.carried := mc.s_mk(copy_.item, cnt, copy_.comp);
      end if;
      st.qc_status := 0; st.qc_slots := '{}';
    else
      st.qc_status := 0; st.qc_slots := '{}';
    end if;
    return st;
  end if;
  -- any other click ends a drag in progress and does nothing else
  if st.qc_status <> 0 then st.qc_status := 0; st.qc_slots := '{}'; return st; end if;

  -- ------------------------------------------------------------------ PICKUP / QUICK_MOVE with the left or right button
  if (input = 0 or input = 1) and (button = 0 or button = 1) then
    if slot = -999 then
      if not mc.s_is_empty(st.carried) then
        if button = 0 then st := mc.mi_drop(st, st.carried); st.carried := mc.s_empty();
        else st := mc.mi_drop(st, mc.s_mk((st.carried).item, 1, (st.carried).comp)); st.carried := mc.s_mk((st.carried).item, (st.carried).n - 1, (st.carried).comp); end if;
      end if;
      return st;
    end if;
    if input = 1 then
      if slot < 0 then return st; end if;
      -- (Slot.mayPickup is true for every slot here)
      st := mc.mi_quick_move(st, slot);
      r := st.r;
      while not mc.s_is_empty(r) and mc.s_same_item(mc.mi_get(st, slot), r) loop
        st := mc.mi_quick_move(st, slot); r := st.r;
      end loop;
      return st;
    end if;
    if slot < 0 then return st; end if;
    cur := mc.mi_get(st, slot); car := st.carried;
    if mc.s_is_empty(cur) then
      if not mc.s_is_empty(car) then
        st := mc.mi_safe_insert(st, slot, car, case when button = 0 then car.n else 1 end);
        st.carried := st.r;
      end if;
    else
      if mc.s_is_empty(car) then
        c := case when button = 0 then cur.n else (cur.n + 1) / 2 end;
        st := mc.mi_try_remove(st, slot, c, 2147483647);
        if st.ok then rem := st.r; st.carried := rem; st := mc.mi_on_take(st, slot, rem); end if;
      elsif mc.mi_may_place(st, slot, car) then
        if mc.s_same(cur, car) then
          st := mc.mi_safe_insert(st, slot, car, case when button = 0 then car.n else 1 end);
          st.carried := st.r;
        elsif car.n <= mc.mi_slot_max(st, slot, car) then
          st.carried := cur;
          st := mc.mi_set(st, slot, car);
        end if;
      elsif mc.s_same(cur, car) then
        st := mc.mi_try_remove(st, slot, cur.n, mc.s_max(car.item) - car.n);
        if st.ok then
          rem := st.r;
          st.carried := mc.s_mk(car.item, car.n + rem.n, car.comp);
          st := mc.mi_on_take(st, slot, rem);
        end if;
      end if;
    end if;
    return st;
  end if;

  -- ------------------------------------------------------------------ SWAP (number keys 0-8, F = 40)
  if input = 2 and ((button >= 0 and button < 9) or button = 40) then
    k := case when button = 40 then 45 else 36 + button end;                           -- the inventory-menu slot of Inventory.getItem(button)
    if slot < 0 then return st; end if;
    hot := st.inv[k + 1]; sl := mc.mi_get(st, slot);
    if mc.s_is_empty(hot) and mc.s_is_empty(sl) then return st; end if;
    if mc.s_is_empty(hot) then
      -- take the slot's stack into the hotbar slot
      st.inv[k + 1] := sl;
      st := mc.mi_set(st, slot, mc.s_empty());
      st := mc.mi_on_take(st, slot, sl);
    elsif mc.s_is_empty(sl) then
      if mc.mi_may_place(st, slot, hot) then
        mx := mc.mi_slot_max(st, slot, hot);
        if hot.n > mx then
          st := mc.mi_set(st, slot, mc.s_mk(hot.item, mx, hot.comp));
          st.inv[k + 1] := mc.s_mk(hot.item, hot.n - mx, hot.comp);
        else
          st.inv[k + 1] := mc.s_empty();
          st := mc.mi_set(st, slot, hot);
        end if;
      end if;
    else
      if mc.mi_may_place(st, slot, hot) then
        mx := mc.mi_slot_max(st, slot, hot);
        if hot.n > mx then
          st := mc.mi_set(st, slot, mc.s_mk(hot.item, mx, hot.comp));
          st.inv[k + 1] := mc.s_mk(hot.item, hot.n - mx, hot.comp);                      -- (the hotbar stack was split in place before the rest happens)
          st := mc.mi_on_take(st, slot, sl);
          st := mc.mi_inv_add(st, sl);
          if not st.ok then st := mc.mi_drop(st, sl); end if;                            -- (the swapped-out stack that fits nowhere falls to the ground)
        else
          st.inv[k + 1] := sl;
          st := mc.mi_set(st, slot, hot);
          st := mc.mi_on_take(st, slot, sl);
        end if;
      end if;
    end if;
    return st;
  end if;

  -- ------------------------------------------------------------------ CLONE (creative: middle click)
  if input = 3 and st.gm = 1 and mc.s_is_empty(st.carried) and slot >= 0 then
    sl := mc.mi_get(st, slot);
    if not mc.s_is_empty(sl) then st.carried := mc.s_mk(sl.item, mc.s_max(sl.item), sl.comp); end if;
    return st;
  end if;

  -- ------------------------------------------------------------------ THROW (Q, ctrl+Q)
  if input = 4 and mc.s_is_empty(st.carried) and slot >= 0 then
    sl := mc.mi_get(st, slot);
    cnt := case when button = 0 then 1 else sl.n end;
    st := mc.mi_safe_take(st, slot, cnt, 2147483647);
    r := st.r;
    st := mc.mi_drop(st, r);
    if button = 1 then
      while not mc.s_is_empty(r) and mc.s_same_item(mc.mi_get(st, slot), r) loop
        st := mc.mi_safe_take(st, slot, cnt, 2147483647);
        r := st.r;
        st := mc.mi_drop(st, r);
      end loop;
    end if;
    return st;
  end if;

  -- ------------------------------------------------------------------ PICKUP_ALL (double click: collect)
  if input = 6 and slot >= 0 then
    car := st.carried;
    sl := mc.mi_get(st, slot);
    if not mc.s_is_empty(car) and mc.s_is_empty(sl) then                                -- (vanilla: the clicked slot has no item or cannot be picked from)
      start_ := case when button = 0 then 0 else n_slots - 1 end; step := case when button = 0 then 1 else -1 end;
      for pass in 0 .. 1 loop
        k := start_;
        while k >= 0 and k < n_slots and car.n < mc.s_max(car.item) loop
          sl := mc.mi_get(st, k);
          if not mc.s_is_empty(sl) and mc.mi_can_replace(st, k, car, true) and st.s_store[k + 1] <> 'res'      -- canTakeItemForPickAll: not the crafting result
             and not (pass = 0 and sl.n = mc.s_max(sl.item)) then
            st := mc.mi_safe_take(st, k, sl.n, mc.s_max(car.item) - car.n);
            r := st.r;
            car := mc.s_mk(car.item, car.n + coalesce(r.n, 0), car.comp);
          end if;
          k := k + step;
        end loop;
      end loop;
      st.carried := car;
    end if;
    return st;
  end if;
  return st;
end $$;
