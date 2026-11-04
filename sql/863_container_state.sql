-- Containers, crafting and recipes, part 4: loading a menu from the tables, writing the changes back, what the click handlers send, opening and closing.
--
-- ServerGamePacketListenerImpl.handleContainerClick (bytecode):  container id must be the open menu's; a spectator or a dead player gets the whole menu again
-- (sendAllDataToRemote); an invalid menu or slot index is ignored; stale = packet.stateId != menu.stateId; clicked() runs on the server's own state whatever the client
-- claims; the client's changedSlots and carried item are taken as the remote copies; then broadcastChanges (the differences) or, when stale, broadcastFullState
-- (container_set_content with the next state id).  handleContainerClose: ServerPlayer.doCloseContainer() whatever the id says: the carried item and the
-- crafting grid go back into the inventory (set_player_inventory per slot), the inventory menu becomes the open menu again.

------------------------------------------------------------------------------------------------ load
create or replace function mc.mi_blank(n int) returns mc.stk[] language sql immutable parallel safe as $$
    select coalesce(array_agg(mc.s_empty()), '{}'::mc.stk[]) from generate_series(1, n) $$;

create or replace function mc.mi_load(p_uuid uuid, p_force_inv boolean default false) returns mc.mst language plpgsql stable as $$
declare st mc.mst; pl mc.player; ms mc.menu_state; op boolean; rows int; rec record;
begin
  select * into pl from mc.player where uuid = p_uuid;
  select * into ms from mc.menu_state where player = p_uuid;
  op := coalesce(ms.open, false) and not p_force_inv;
  st.kind := case when op then ms.kind else 'inventory' end;
  st.cid := case when op then ms.container_id else 0 end;
  st.state_id := case when op then ms.state_id else pl.inv_state end;
  st.gm := pl.gamemode; st.held := pl.held_slot;
  select k.grid_w into st.grid_w from mc.menu_kind k where k.kind = st.kind;
  select array_agg(d.store order by d.idx), array_agg(d.cs order by d.idx), array_agg(d.rule order by d.idx), array_agg(d.role order by d.idx), array_agg(d.max_stack order by d.idx)
    into st.s_store, st.s_cs, st.s_rule, st.s_role, st.s_max from mc.menu_slot_def d where d.kind = st.kind;
  select array_agg(row(i.item, coalesce(i.count, 0), i.components ->> 'raw_hex')::mc.stk order by g) into st.inv
    from generate_series(0, 45) g left join mc.inventory_slot i on i.player = p_uuid and i.slot = g;
  st.inv[1] := mc.s_empty();                                                           -- (slot 0, the result, is not part of the inventory)
  st.carried := mc.s_mk(ms.carried_item, ms.carried_n, ms.carried_comp);
  st.result := mc.s_mk(ms.result_item, ms.result_n, ms.result_comp);
  st.qc_type := coalesce(ms.qc_type, 0); st.qc_status := coalesce(ms.qc_status, 0); st.qc_slots := coalesce(ms.qc_slots, '{}');
  st.pkts := '\x'::bytea; st.drops := '{}'::mc.stk[];
  st.blk := '{}'::mc.stk[]; st.grid := '{}'::mc.stk[];
  if op and st.kind = 'crafting' then
    select array_agg(row(g.item, coalesce(g.count, 0), g.components ->> 'raw_hex')::mc.stk order by n) into st.grid
      from generate_series(0, 8) n left join mc.menu_slot g on g.player = p_uuid and g.slot = n;
  end if;
  if op and (st.kind like 'generic_9x%' or st.kind in ('furnace', 'blast_furnace', 'smoker')) then
    rows := case when st.kind like 'generic_9x%' then 9 * substr(st.kind, 11)::int else 3 end;
    if ms.dimension is null then                                                       -- the player's ender chest
      select array_agg(row(e.item, coalesce(e.count, 0), e.components ->> 'raw_hex')::mc.stk order by n) into st.blk
        from generate_series(0, rows - 1) n left join mc.ender_slot e on e.player = p_uuid and e.slot = n;
    else
      select array_agg(row(c.item, coalesce(c.count, 0), c.components ->> 'raw_hex')::mc.stk order by n) into st.blk
        from generate_series(0, rows - 1) n
        left join mc.container_slot c on c.dimension = ms.dimension and c.slot = case when ms.x2 is null then n else n % 27 end
             and ((ms.x2 is null and c.x = ms.x and c.y = ms.y and c.z = ms.z)
               or (ms.x2 is not null and ((n < 27 and c.x = ms.x and c.y = ms.y and c.z = ms.z) or (n >= 27 and c.x = ms.x2 and c.y = ms.y2 and c.z = ms.z2))));
    end if;
  end if;
  return st;
end $$;

------------------------------------------------------------------------------------------------ store
-- write back what differs between the state loaded and the state now
create or replace function mc.mi_store(p_uuid uuid, a mc.mst, b mc.mst, p_force_inv boolean default false) returns void language plpgsql as $$
declare ms mc.menu_state; op boolean;
begin
  select * into ms from mc.menu_state where player = p_uuid;
  op := coalesce(ms.open, false) and not p_force_inv;
  if op then perform set_config('mc.furnace_skip', 'on', true); end if;                -- (the furnace triggers, sql/866, stay out of a menu's own writes: furnace_touch below)
  -- the player's inventory
  with d as (select (o.ord - 1)::int as slot, n.s as s
               from mc.stk_rows(a.inv) o join mc.stk_rows(b.inv) n using (ord)
              where ord > 1 and ((o.s).item is distinct from (n.s).item or (o.s).n is distinct from (n.s).n or (o.s).comp is distinct from (n.s).comp)),
       del as (delete from mc.inventory_slot i using d where i.player = p_uuid and i.slot = d.slot and (d.s).item is null returning 1)
  insert into mc.inventory_slot (player, slot, item, count, components)
  select p_uuid, d.slot, (d.s).item, (d.s).n, case when (d.s).comp is null then null else jsonb_build_object('raw_hex', (d.s).comp) end from d where (d.s).item is not null
  on conflict (player, slot) do update set item = excluded.item, count = excluded.count, components = excluded.components;
  -- the crafting table's grid
  if op and a.kind = 'crafting' then
    with d as (select (o.ord - 1)::int as slot, n.s as s
                 from mc.stk_rows(a.grid) o join mc.stk_rows(b.grid) n using (ord)
                where (o.s).item is distinct from (n.s).item or (o.s).n is distinct from (n.s).n or (o.s).comp is distinct from (n.s).comp),
         del as (delete from mc.menu_slot g using d where g.player = p_uuid and g.slot = d.slot and (d.s).item is null returning 1)
    insert into mc.menu_slot (player, slot, item, count, components)
    select p_uuid, d.slot, (d.s).item, (d.s).n, case when (d.s).comp is null then null else jsonb_build_object('raw_hex', (d.s).comp) end from d where (d.s).item is not null
    on conflict (player, slot) do update set item = excluded.item, count = excluded.count, components = excluded.components;
  end if;
  -- the block's container (a chest, a furnace) or the ender chest
  if op and coalesce(array_length(a.blk, 1), 0) > 0 then
    if ms.dimension is null then
      with d as (select (o.ord - 1)::int as slot, n.s as s
                   from mc.stk_rows(a.blk) o join mc.stk_rows(b.blk) n using (ord)
                  where (o.s).item is distinct from (n.s).item or (o.s).n is distinct from (n.s).n or (o.s).comp is distinct from (n.s).comp),
           del as (delete from mc.ender_slot e using d where e.player = p_uuid and e.slot = d.slot and (d.s).item is null returning 1)
      insert into mc.ender_slot (player, slot, item, count, components)
      select p_uuid, d.slot, (d.s).item, (d.s).n, case when (d.s).comp is null then null else jsonb_build_object('raw_hex', (d.s).comp) end from d where (d.s).item is not null
      on conflict (player, slot) do update set item = excluded.item, count = excluded.count, components = excluded.components;
    else
      with d as (select (o.ord - 1)::int as n, n.s as s
                   from mc.stk_rows(a.blk) o join mc.stk_rows(b.blk) n using (ord)
                  where (o.s).item is distinct from (n.s).item or (o.s).n is distinct from (n.s).n or (o.s).comp is distinct from (n.s).comp),
           pos as (select d.*, case when ms.x2 is not null and d.n >= 27 then ms.x2 else ms.x end as px, case when ms.x2 is not null and d.n >= 27 then ms.y2 else ms.y end as py,
                          case when ms.x2 is not null and d.n >= 27 then ms.z2 else ms.z end as pz, case when ms.x2 is not null then d.n % 27 else d.n end as sl from d),
           del as (delete from mc.container_slot c using pos where c.dimension = ms.dimension and c.x = pos.px and c.y = pos.py and c.z = pos.pz and c.slot = pos.sl and (pos.s).item is null returning 1)
      insert into mc.container_slot (dimension, x, y, z, slot, item, count, components)
      select ms.dimension, pos.px, pos.py, pos.pz, pos.sl, (pos.s).item, (pos.s).n, case when (pos.s).comp is null then null else jsonb_build_object('raw_hex', (pos.s).comp) end
        from pos where (pos.s).item is not null
      on conflict (dimension, x, y, z, slot) do update set item = excluded.item, count = excluded.count, components = excluded.components;
    end if;
  end if;
  -- state: state id, carried, result, drag
  if op then update mc.menu_state set state_id = b.state_id where player = p_uuid;
  else update mc.player set inv_state = b.state_id where uuid = p_uuid and inv_state is distinct from b.state_id; end if;
  insert into mc.menu_state (player, carried_item, carried_n, carried_comp, qc_type, qc_status, qc_slots, result_item, result_n, result_comp, blk_sent)
  values (p_uuid, (b.carried).item, coalesce((b.carried).n, 0), (b.carried).comp, b.qc_type, b.qc_status, b.qc_slots, (b.result).item, coalesce((b.result).n, 0), (b.result).comp,
          case when op and coalesce(array_length(b.blk, 1), 0) > 0 then b.blk end)
  on conflict (player) do update set carried_item = excluded.carried_item, carried_n = excluded.carried_n, carried_comp = excluded.carried_comp,
        qc_type = excluded.qc_type, qc_status = excluded.qc_status, qc_slots = excluded.qc_slots,
        result_item = excluded.result_item, result_n = excluded.result_n, result_comp = excluded.result_comp,
        blk_sent = case when op and coalesce(array_length(b.blk, 1), 0) > 0 then b.blk else mc.menu_state.blk_sent end;
  if op and a.kind in ('furnace', 'blast_furnace', 'smoker') and ms.dimension is not null then
    -- AbstractFurnaceBlockEntity.setItem(0, ..): another item (or none) in the input slot restarts the cooking
    perform mc.furnace_touch(ms.dimension, ms.x, ms.y, ms.z, a.kind,
        not ((mc.s_is_empty(a.blk[1]) and mc.s_is_empty(b.blk[1])) or (not mc.s_is_empty(a.blk[1]) and not mc.s_is_empty(b.blk[1]) and mc.s_same(a.blk[1], b.blk[1]))));
  end if;
  if op then perform set_config('mc.furnace_skip', 'off', true); end if;
end $$;

-- the stacks of a state as the wire sends them: every slot of the menu in order
create or replace function mc.mi_all_slots(st mc.mst) returns mc.stk[] language plpgsql immutable parallel safe as $$
declare r mc.stk[] := '{}'; i int; n int := array_length(st.s_store, 1);
begin
  for i in 0 .. n - 1 loop r := r || mc.mi_get(st, i); end loop;
  return r;
end $$;

------------------------------------------------------------------------------------------------ broadcastChanges
-- Does the client's claim (a HashedStack: item, count, number of added and removed components) match the server's stack?  HashedStack.ActualItem.matches compares
-- the count, the item and the patch; the component hashes are not computed here, only their number is compared (docs/CONTAINERS.md).
create or replace function mc.claim_matches(srv mc.stk, cl mc.claim) returns boolean language sql immutable parallel safe as $$
    select case when cl.item is null then mc.s_is_empty(srv)
                else not mc.s_is_empty(srv) and srv.item = cl.item and srv.n = cl.n
                     and cl.added = coalesce(get_byte(decode(srv.comp, 'hex'), 0), 0) and cl.removed = coalesce(get_byte(decode(srv.comp, 'hex'), 1), 0) end $$;

-- after the click: container_set_slot for every slot whose content differs from the client's copy (its claim where it made one, else what it had before), then the
-- carried item (set_cursor_item); a stale click: the whole menu again
create or replace function mc.mi_broadcast(st mc.mst, before mc.stk[], claims mc.claim[], stale boolean) returns mc.mst language plpgsql stable as $$
declare i int; n int := array_length(st.s_store, 1); srv mc.stk; ok boolean; cl mc.claim; found_ boolean;
begin
  if stale then
    st.state_id := (st.state_id + 1) & 32767;
    st.pkts := st.pkts || mc.pkt_cc(st.cid, st.state_id, mc.mi_all_slots(st), st.carried);
    return st;
  end if;
  for i in 0 .. n - 1 loop
    srv := mc.mi_get(st, i);
    found_ := false;
    foreach cl in array claims loop if cl.slot = i then found_ := true; exit; end if; end loop;
    if found_ then ok := mc.claim_matches(srv, cl);
    elsif i = 0 and st.s_role[1] = 'craft_result' then ok := mc.s_matches(coalesce(st.rem0, before[1]), srv);
    else ok := mc.s_matches(before[i + 1], srv); end if;
    if not ok then
      st.state_id := (st.state_id + 1) & 32767;
      st.pkts := st.pkts || mc.pkt_cs(st.cid, st.state_id, i, srv);
    end if;
  end loop;
  foreach cl in array claims loop
    if cl.slot = -1 then
      if not mc.claim_matches(st.carried, cl) then st.pkts := st.pkts || mc.pkt_cursor(st.carried); end if;
      exit;
    end if;
  end loop;
  return st;
end $$;

------------------------------------------------------------------------------------------------ dropping what falls out of a menu
-- Player.drop(stack, thrown): an item entity in front of the player when the entity simulation runs on this connection; otherwise the items are gone (like the death drops)
create or replace function mc.menu_drop(p_uuid uuid, items mc.stk[]) returns void language plpgsql as $$
declare p mc.player; s mc.stk; a float8; f float8 := 0.3;
begin
  if coalesce(array_length(items, 1), 0) = 0 or mc.entity_mode() <> 'inline' then return; end if;
  select * into p from mc.player where uuid = p_uuid;
  foreach s in array items loop
    a := radians(p.yaw);
    perform mc.entity_spawn('minecraft:item', p.x, p.y + 1.62 - 0.3, p.z, -sin(a) * cos(radians(p.pitch)) * f, -sin(radians(p.pitch)) * f + 0.1, cos(a) * cos(radians(p.pitch)) * f,
                            null, jsonb_build_object('item', s.item, 'count', s.n) || case when s.comp is null then '{}'::jsonb else jsonb_build_object('raw_hex', s.comp) end, 40);
  end loop;
end $$;

------------------------------------------------------------------------------------------------ AbstractContainerMenu.removed
-- the carried item and the crafting grid go back to the inventory; the result container is emptied
create or replace function mc.mi_removed(st mc.mst) returns mc.mst language plpgsql stable as $$
declare i int; c mc.stk;
begin
  if not mc.s_is_empty(st.carried) then c := st.carried; st.carried := mc.s_empty(); st := mc.mi_place_back(st, c); end if;
  st.qc_status := 0; st.qc_slots := '{}';
  if st.kind = 'inventory' then
    st.result := mc.s_empty();
    for i in 1 .. 4 loop c := st.inv[i + 1]; st.inv[i + 1] := mc.s_empty(); st := mc.mi_place_back(st, c); end loop;
  elsif st.kind = 'crafting' then
    for i in 1 .. 9 loop c := st.grid[i]; st.grid[i] := mc.s_empty(); st := mc.mi_place_back(st, c); end loop;
    st.result := mc.s_empty();
  end if;
  return st;
end $$;

-- ServerPlayer.doCloseContainer for a player: whatever menu is open is removed and the inventory menu is the open one again.  Packets go to the player's connection.
-- The inventory menu then BROADCASTS what changed in its slots without it being told (the items placed back, the emptied grid and result): container_set_slot for each
-- such slot in order with the inventory menu's next state ids, after the set_player_inventory packets (its remote copies are those of the closed menu, i.e. the state before).
create or replace function mc.menu_do_close(p_uuid uuid, p_send_close boolean default false) returns void language plpgsql as $$
declare st mc.mst; a mc.mst; ms mc.menu_state; conn int; i int; sid int; after_ mc.stk; rem mc.stk; pk bytea := '\x'::bytea;
begin
  select conn_id into conn from mc.player where uuid = p_uuid;
  select * into ms from mc.menu_state where player = p_uuid;
  st := mc.mi_load(p_uuid); a := st;
  if p_send_close and coalesce(ms.open, false) then st.pkts := mc.pkt_container_close(st.cid); end if;       -- ServerPlayer.closeContainer sends it first
  st := mc.mi_removed(st);
  -- the inventory menu's own state id: the open menu's is the same counter only when no other menu was open
  select inv_state into sid from mc.player where uuid = p_uuid;
  if not coalesce(ms.open, false) then sid := st.state_id; end if;
  for i in 0 .. 45 loop
    if i = 0 then
      continue when coalesce(ms.open, false);                                         -- (the inventory menu's result slot is not touched while another menu is open)
      after_ := st.result; rem := coalesce(a.rem0, a.result);
    else
      after_ := st.inv[i + 1];
      -- slots the closed menu showed: its copy of them (= the server's before the items go back); the others (grid, armor, off hand): the inventory menu's own, from when the menu opened
      rem := case when coalesce(ms.open, false) and (i between 1 and 8 or i = 45) and ms.inv_sent is not null then ms.inv_sent[i + 1] else a.inv[i + 1] end;
    end if;
    if not mc.s_matches(rem, after_) then
      sid := (sid + 1) & 32767;
      pk := pk || mc.pkt_cs(0, sid, i, after_);
    end if;
  end loop;
  -- ... and the carried item: the inventory menu's client copy still shows what was on the cursor
  if not coalesce(ms.open, false) and not mc.s_is_empty(a.carried) then pk := pk || mc.pkt_cursor(mc.s_empty()); end if;
  perform mc.mi_store(p_uuid, a, st);
  update mc.player set inv_state = sid where uuid = p_uuid and inv_state is distinct from sid;
  update mc.menu_state set open = false, kind = null, container_id = 0, dimension = null, x = null, y = null, z = null, x2 = null, y2 = null, z2 = null, data = null, blk_sent = null, inv_sent = null, stale = false, state_id = 0
   where player = p_uuid and open;
  -- the order of the tick: what removed() sent (close, set_player_inventory), then the block events (the chest lid), then the inventory menu's broadcast
  if conn is not null and length(st.pkts) > 0 then insert into mc.play_out (conn_id, data) values (conn, st.pkts); end if;
  perform mc.menu_drop(p_uuid, st.drops);
  perform mc.menu_closed_hook(ms);
  if conn is not null and length(pk) > 0 then insert into mc.play_out (conn_id, data) values (conn, pk); end if;
end $$;

-- A player who leaves takes nothing with them: the open menu is closed first (the items go back into the inventory)
create or replace function mc.menu_close_on_leave() returns trigger language plpgsql as $$
begin
  if exists (select 1 from mc.menu_state s where s.player = old.uuid and (s.open or s.carried_n > 0 or s.qc_status <> 0 or s.result_n > 0))
     or exists (select 1 from mc.inventory_slot i where i.player = old.uuid and i.slot between 1 and 4) then
    perform mc.menu_do_close(old.uuid, false);
  end if;
  if old.sneaking then update mc.player set sneaking = false where uuid = old.uuid; end if;
  return new;
end $$;
drop trigger if exists menu_close_on_leave on mc.player;
create trigger menu_close_on_leave after update on mc.player for each row when (old.conn_id is not null and new.conn_id is null) execute function mc.menu_close_on_leave();

-- A joining session starts with the inventory menu: a menu left open by a crash or a restart is closed without a word (the join burst carries the inventory)
create or replace function mc.menu_on_join() returns trigger language plpgsql as $$
declare st mc.mst; a mc.mst;
begin
  if exists (select 1 from mc.menu_state s where s.player = new.uuid and (s.open or s.carried_n > 0 or s.qc_status <> 0 or s.result_n > 0)) or exists (select 1 from mc.inventory_slot i where i.player = new.uuid and i.slot between 1 and 4) then
    st := mc.mi_load(new.uuid); a := st;
    st := mc.mi_removed(st);
    perform mc.mi_store(new.uuid, a, st);
    update mc.menu_state set open = false, kind = null, container_id = 0, dimension = null, x = null, y = null, z = null, x2 = null, y2 = null, z2 = null, data = null, blk_sent = null, inv_sent = null, stale = false, state_id = 0
     where player = new.uuid and open;
  end if;
  return null;
end $$;
drop trigger if exists menu_on_join on mc.player;
create trigger menu_on_join after update on mc.player for each row when (old.conn_id is null and new.conn_id is not null) execute function mc.menu_on_join();

------------------------------------------------------------------------------------------------ giving items (GiveCommand: Inventory.add, then broadcastChanges)
-- n items of one kind into a player's inventory the way vanilla places them (the selected hotbar slot, the off hand, then 0..35, merging before filling an empty slot);
-- the player is told with container_set_slot for every slot that changed, in slot order, with the next state ids (what the inventory menu's broadcastChanges sends).
-- Returns how many items did not fit (vanilla drops them as an item entity next to the player: here they are dropped through mc.menu_drop).
create or replace function mc.inv_give(p_uuid uuid, p_item text, p_n int, p_comp text default null) returns int language plpgsql as $$
declare st mc.mst; a mc.mst; conn int; i int; sid int; pk bytea := '\x'::bytea; left_ int;
begin
  st := mc.mi_load(p_uuid, true); a := st;
  st := mc.mi_inv_add(st, mc.s_mk(p_item, p_n, p_comp));
  left_ := coalesce((st.r).n, 0);
  select conn_id, inv_state into conn, sid from mc.player where uuid = p_uuid;
  for i in 1 .. 45 loop
    if not mc.s_matches(a.inv[i + 1], st.inv[i + 1]) then
      sid := (sid + 1) & 32767;
      pk := pk || mc.pkt_cs(0, sid, i, st.inv[i + 1]);
    end if;
  end loop;
  perform mc.mi_store(p_uuid, a, st, true);
  update mc.player set inv_state = sid where uuid = p_uuid and inv_state is distinct from sid;
  if conn is not null and length(pk) > 0 then insert into mc.play_out (conn_id, data) values (conn, pk); end if;
  if left_ > 0 then perform mc.menu_drop(p_uuid, array[mc.s_mk(p_item, left_, p_comp)]); end if;
  return left_;
end $$;

-- A player who died and respawns is a new ServerPlayer with a new inventory menu: whatever menu was open, whatever was carried and the result slot are gone (the inventory
-- rows themselves are the survival code's: dropped or kept).  Not compared with vanilla: what the old menu's grid and cursor become on death.
create or replace function mc.menu_on_respawn() returns trigger language plpgsql as $$
begin
  delete from mc.menu_state where player = new.uuid;
  delete from mc.menu_slot where player = new.uuid;
  return null;
end $$;
drop trigger if exists menu_on_respawn on mc.player;
create trigger menu_on_respawn after update on mc.player for each row when (old.dead and not new.dead) execute function mc.menu_on_respawn();
