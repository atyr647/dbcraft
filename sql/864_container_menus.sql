-- Containers, crafting and recipes, part 5: the menus of blocks (open, still valid, close), the serverbound packets, and the one tick step.
--
--   use_item_on on a chest, trapped chest, barrel, ender chest, furnace, blast furnace, smoker or crafting table opens it (ServerPlayerGameMode.useItemOn: a sneaking player
--   holding an item uses the item instead; a spectator may open any menu); open_screen + container_set_content (state id 1) + for furnaces the four container_set_data values.
--   A menu closes when its block is gone or the player is further than blockInteractionRange + 4.0 away (Container.stillValidBlockEntity / AbstractContainerMenu.stillValid).
--   When the block is broken the contents drop (mc.container_on_block_event, sql/865).
--
-- Layouts (bytecode): container_click = VarInt containerId, VarInt stateId, short slot, byte button, VarInt input, map<short, HashedStack> changed (VarInt size, <= 128),
-- HashedStack carried; HashedStack = bool present [VarInt item id, VarInt count, map<VarInt componentType, int hash>, set<VarInt componentType>];
-- container_close = VarInt id; player_input = one byte of flags (1 forward, 2 backward, 4 left, 8 right, 16 jump, 32 shift, 64 sprint).

create or replace function mc.in_reach_buf(px float8, py float8, pz float8, bx int, by int, bz int, gm int, buf float8) returns boolean language sql immutable parallel safe as $$
    select (power(greatest(bx - px, 0, px - (bx + 1)), 2) + power(greatest(by - (py + 1.62), 0, (py + 1.62) - (by + 1)), 2) + power(greatest(bz - pz, 0, pz - (bz + 1)), 2))
           < power((case when gm = 1 then 5.0 else 4.5 end) + buf, 2) $$;

------------------------------------------------------------------------------------------------ which block opens which menu
create or replace function mc.container_info(p_state text, out kind text, out title text, out blk text, out double_ boolean) language plpgsql immutable as $$
declare t text;
begin
  blk := split_part(p_state, '[', 1); double_ := false;
  case blk
    when 'minecraft:chest', 'minecraft:trapped_chest' then
      t := substring(p_state from 'type=(\w+)'); double_ := t in ('left', 'right');
      kind := case when double_ then 'generic_9x6' else 'generic_9x3' end; title := case when double_ then 'container.chestDouble' else 'container.chest' end;
    when 'minecraft:barrel' then kind := 'generic_9x3'; title := 'container.barrel';
    when 'minecraft:ender_chest' then kind := 'generic_9x3'; title := 'container.enderchest';
    when 'minecraft:furnace' then kind := 'furnace'; title := 'container.furnace';
    when 'minecraft:blast_furnace' then kind := 'blast_furnace'; title := 'container.blast_furnace';
    when 'minecraft:smoker' then kind := 'smoker'; title := 'container.smoker';
    when 'minecraft:crafting_table' then kind := 'crafting'; title := 'container.crafting';
    else kind := null; title := null;
  end case;
end $$;

-- ChestBlock.getConnectedDirection: a LEFT half is joined to the block clockwise of its facing, a RIGHT half to the one counter-clockwise
create or replace function mc.chest_partner(p_state text, x int, y int, z int, out px int, out py int, out pz int) language plpgsql immutable as $$
declare t text := substring(p_state from 'type=(\w+)'); f text := substring(p_state from 'facing=(\w+)'); d text;
begin
  if t not in ('left', 'right') then return; end if;
  d := case when t = 'left' then (case f when 'north' then 'east' when 'east' then 'south' when 'south' then 'west' else 'north' end)
                           else (case f when 'north' then 'west' when 'west' then 'south' when 'south' then 'east' else 'north' end) end;
  px := x + case d when 'east' then 1 when 'west' then -1 else 0 end; py := y; pz := z + case d when 'south' then 1 when 'north' then -1 else 0 end;
end $$;

------------------------------------------------------------------------------------------------ opening
-- ServerPlayer.openMenu: close the current menu (container_close), next container id (counter % 100 + 1), open_screen, the menu's contents (state id 1)
create or replace function mc.menu_open(p_uuid uuid, p_dim text, bx int, bby int, bz int, p_run_hook boolean default true) returns boolean language plpgsql as $$
declare p mc.player; ms mc.menu_state; ci record; cp record; st mc.mst; a mc.mst; cid int; x2 int; y2 int; z2 int; state text; tid int; dat int[]; f mc.furnace; n int; t int;
begin
  select * into p from mc.player where uuid = p_uuid;
  state := mc.get_block(p_dim, bx, bby, bz);
  select * into ci from mc.container_info(state);
  if ci.kind is null then return false; end if;
  if ci.double_ then
    select * into cp from mc.chest_partner(state, bx, bby, bz);
    if split_part(mc.get_block(p_dim, cp.px, cp.py, cp.pz), '[', 1) is distinct from ci.blk then return false; end if;
    x2 := cp.px; y2 := cp.py; z2 := cp.pz;
    -- DoubleBlockCombiner: the RIGHT half is the first container (slots 0-26), the LEFT half the second
    if substring(state from 'type=(\w+)') = 'left' then x2 := bx; y2 := bby; z2 := bz; bx := cp.px; bby := cp.py; bz := cp.pz; end if;
  end if;
  select * into ms from mc.menu_state where player = p_uuid;
  if coalesce(ms.open, false) then perform mc.menu_do_close(p_uuid, true); end if;
  cid := coalesce(ms.counter, 0) % 100 + 1;
  insert into mc.menu_state (player, open, kind, container_id, counter, state_id, dimension, x, y, z, x2, y2, z2, opened_at)
  values (p_uuid, true, ci.kind, cid, cid, 0, case when ci.blk = 'minecraft:ender_chest' then null else p_dim end, bx, bby, bz, x2, y2, z2, (select game_time from mc.game_state))
  on conflict (player) do update set open = true, kind = excluded.kind, container_id = cid, counter = cid, state_id = 0, dimension = excluded.dimension,
        x = excluded.x, y = excluded.y, z = excluded.z, x2 = excluded.x2, y2 = excluded.y2, z2 = excluded.z2, data = null, blk_sent = null, opened_at = excluded.opened_at, stale = false;
  st := mc.mi_load(p_uuid); a := st;
  update mc.menu_state set inv_sent = a.inv where player = p_uuid;
  st := mc.mi_removed_carried(st);
  st.state_id := 1;
  tid := (select protocol_id from ref.registry where registry = 'minecraft:menu' and name = (select menu_type from mc.menu_kind where kind = ci.kind));
  st.pkts := st.pkts || mc.cb('open_screen', proto.varint(cid) || proto.varint(tid) || proto.nbt_root(mc.tc_translate(ci.title)))
                     || mc.pkt_cc(cid, 1, mc.mi_all_slots(st), mc.s_empty());
  if ci.kind in ('furnace', 'blast_furnace', 'smoker') then
    select * into f from mc.furnace where dimension = p_dim and x = bx and y = bby and z = bz;
    dat := array[coalesce(f.lit_time, 0), coalesce(f.lit_duration, 0), coalesce(f.cook_progress, 0), coalesce(f.cook_total, 0)];
    for n in 0 .. 3 loop st.pkts := st.pkts || mc.pkt_container_data(cid, n, dat[n + 1]); end loop;
    update mc.menu_state set data = dat where player = p_uuid;
  end if;
  update mc.menu_state set state_id = 1 where player = p_uuid;
  perform mc.mi_store(p_uuid, a, st);                                                   -- (a carried item went back into the inventory above)
  if p.conn_id is not null then insert into mc.play_out (conn_id, data) values (p.conn_id, st.pkts); end if;
  if p_run_hook then perform mc.menu_opened_state_hook(p_dim, bx, bby, bz, ci.blk); perform mc.menu_opened_event_hook(p_uuid, p_dim, ci.blk); end if;
  return true;
end $$;
create or replace function mc.mi_removed_carried(st mc.mst) returns mc.mst language plpgsql stable as $$
declare c mc.stk;
begin
  if not mc.s_is_empty(st.carried) then c := st.carried; st.carried := mc.s_empty(); st := mc.mi_place_back(st, c); end if;
  return st;
end $$;
-- ChestBlockEntity / EnderChestBlockEntity (ContainerOpenersCounter): the lid follows the number of players looking: a block event (1, count) to everybody within 64 blocks;
-- a double chest signals both halves, the first one first.  A barrel shows an open state instead (BarrelBlockEntity).
create or replace function mc.chest_signal(p_dim text, px int, py int, pz int, p_blk text) returns void language plpgsql as $$
declare cnt int; pkt bytea; bid int;
begin
  select count(*) into cnt from mc.menu_state s
   where s.open and (s.dimension is not distinct from p_dim or s.dimension is null) and ((s.x = px and s.y = py and s.z = pz) or (s.x2 = px and s.y2 = py and s.z2 = pz));
  select protocol_id into bid from ref.registry where registry = 'minecraft:block' and name = p_blk;
  pkt := mc.cb('block_event', proto.position(px, py, pz) || set_byte('\x00'::bytea, 0, 1) || set_byte('\x00'::bytea, 0, cnt) || proto.varint(bid));
  insert into mc.play_out (conn_id, data)
  select p.conn_id, pkt from mc.player p where p.conn_id is not null and (p.x - (px + 0.5)) ^ 2 + (p.y - (py + 0.5)) ^ 2 + (p.z - (pz + 0.5)) ^ 2 < 4096 order by p.entity_id;
end $$;

create or replace function mc.menu_opened_state_hook(p_dim text, px int, py int, pz int, blk text) returns void language plpgsql as $$
begin
  if blk = 'minecraft:barrel' and mc.get_block(p_dim, px, py, pz) like '%open=false%' then
    perform mc.set_block(p_dim, px, py, pz, replace(mc.get_block(p_dim, px, py, pz), 'open=false', 'open=true'));    -- BarrelBlockEntity.startOpen
  end if;
end $$;
create or replace function mc.menu_opened_event_hook(p_uuid uuid, p_dim text, blk text) returns void language plpgsql as $$
declare ms mc.menu_state;
begin
  if blk in ('minecraft:chest', 'minecraft:trapped_chest', 'minecraft:ender_chest') then
    select * into ms from mc.menu_state where player = p_uuid;
    perform mc.chest_signal(p_dim, ms.x, ms.y, ms.z, blk);
    if ms.x2 is not null then perform mc.chest_signal(p_dim, ms.x2, ms.y2, ms.z2, blk); end if;
  end if;
end $$;
create or replace function mc.menu_closed_hook(ms mc.menu_state) returns void language plpgsql as $$
declare blk text;
begin
  if not ms.open then return; end if;
  blk := split_part(mc.get_block(coalesce(ms.dimension, 'minecraft:overworld'), ms.x, ms.y, ms.z), '[', 1);
  if blk = 'minecraft:barrel' then
    if not exists (select 1 from mc.menu_state o where o.open and o.player <> ms.player and o.dimension = ms.dimension and o.x = ms.x and o.y = ms.y and o.z = ms.z)
       and mc.get_block(ms.dimension, ms.x, ms.y, ms.z) like '%open=true%' then
      perform mc.set_block(ms.dimension, ms.x, ms.y, ms.z, replace(mc.get_block(ms.dimension, ms.x, ms.y, ms.z), 'open=true', 'open=false'));
    end if;
  elsif blk in ('minecraft:chest', 'minecraft:trapped_chest', 'minecraft:ender_chest') then
    perform mc.chest_signal(coalesce(ms.dimension, 'minecraft:overworld'), ms.x, ms.y, ms.z, blk);
    if ms.x2 is not null then perform mc.chest_signal(ms.dimension, ms.x2, ms.y2, ms.z2, blk); end if;
  end if;
end $$;

------------------------------------------------------------------------------------------------ still valid
create or replace function mc.menu_still_valid(ms mc.menu_state, p mc.player, p_check_block boolean default true) returns boolean language plpgsql stable as $$
declare ci record; state text;
begin
  if not ms.open then return true; end if;
  if ms.stale then return false; end if;
  if not p_check_block then                                                            -- the distance only (every tick); the block was checked by the trigger of sql/865 and is looked at again every 20 ticks
    return mc.in_reach_buf(p.x, p.y, p.z, ms.x, ms.y, ms.z, p.gamemode, 4.0) and (ms.x2 is null or mc.in_reach_buf(p.x, p.y, p.z, ms.x2, ms.y2, ms.z2, p.gamemode, 4.0));
  end if;
  if ms.dimension is null then                                                            -- ender chest: some ender chest within reach (the block it was opened at)
    return split_part(mc.get_block('minecraft:overworld', ms.x, ms.y, ms.z), '[', 1) = 'minecraft:ender_chest' and mc.in_reach_buf(p.x, p.y, p.z, ms.x, ms.y, ms.z, p.gamemode, 4.0);
  end if;
  state := mc.get_block(ms.dimension, ms.x, ms.y, ms.z);
  select * into ci from mc.container_info(state);
  if ci.kind is null or not (ci.kind = ms.kind or (ci.kind like 'generic_9x%' and ms.kind like 'generic_9x%')) then return false; end if;
  if ms.x2 is not null and split_part(mc.get_block(ms.dimension, ms.x2, ms.y2, ms.z2), '[', 1) is distinct from ci.blk then return false; end if;
  return mc.in_reach_buf(p.x, p.y, p.z, ms.x, ms.y, ms.z, p.gamemode, 4.0) and (ms.x2 is null or mc.in_reach_buf(p.x, p.y, p.z, ms.x2, ms.y2, ms.z2, p.gamemode, 4.0));
end $$;

------------------------------------------------------------------------------------------------ serverbound decoding
-- HashedStack at offset o: (item name or null, count, added components, removed components, next offset); raises on malformed input (the caller ignores the packet)
create or replace function mc.hashed_read(b bytea, o int, out item text, out n int, out added int, out removed int, out nxt int) language plpgsql immutable as $$
declare v int; k int; iid int;
begin
  if get_byte(b, o) = 0 then item := null; n := 0; added := 0; removed := 0; nxt := o + 1; return; end if;
  o := o + 1;
  select r.val, r.nxt into iid, o from proto.varint_read(b, o) r;
  select r.val, r.nxt into n, o from proto.varint_read(b, o) r;
  select r.val, r.nxt into added, o from proto.varint_read(b, o) r;
  if added > 256 or added < 0 then raise exception 'too many components'; end if;
  for k in 1 .. added loop select r.val, r.nxt into v, o from proto.varint_read(b, o) r; o := o + 4; end loop;
  select r.val, r.nxt into removed, o from proto.varint_read(b, o) r;
  if removed > 256 or removed < 0 then raise exception 'too many components'; end if;
  for k in 1 .. removed loop select r.val, r.nxt into v, o from proto.varint_read(b, o) r; end loop;
  select name into item from ref.registry where registry = 'minecraft:item' and protocol_id = iid;
  if item is null then raise exception 'unknown item id %', iid; end if;
  nxt := o;
end $$;

-- ServerboundContainerClickPacket for a player; returns nothing, queues the packets
create or replace function mc.menu_handle_click(p_uuid uuid, body bytea) returns void language plpgsql as $$
declare p mc.player; o int; cid int; stid int; slot int; button int; inp int; nchg int; k int; claims mc.claim[] := '{}'; h record; key int; st mc.mst; a mc.mst; before mc.stk[]; n int;
        ms mc.menu_state; stale boolean;
begin
  select * into p from mc.player where uuid = p_uuid;
  select * into ms from mc.menu_state where player = p_uuid;
  select r.val, r.nxt into cid, o from proto.varint_read(body, 0) r;
  select r.val, r.nxt into stid, o from proto.varint_read(body, o) r;
  slot := proto.i16_read(body, o); button := proto.i8_read(body, o + 2); o := o + 3;
  select r.val, r.nxt into inp, o from proto.varint_read(body, o) r;
  if inp < 0 or inp > 6 then inp := 0; end if;                                          -- ByIdMap ZERO: an unknown input is PICKUP
  select r.val, r.nxt into nchg, o from proto.varint_read(body, o) r;
  if nchg < 0 or nchg > 128 then return; end if;
  for k in 1 .. nchg loop
    key := proto.i16_read(body, o); o := o + 2;
    select * into h from mc.hashed_read(body, o); o := h.nxt;
    claims := claims || row(key, h.item, h.n, h.added, h.removed)::mc.claim;
  end loop;
  select * into h from mc.hashed_read(body, o);
  claims := claims || row(-1, h.item, h.n, h.added, h.removed)::mc.claim;
  -- the checks of handleContainerClick
  if cid is distinct from (case when coalesce(ms.open, false) then ms.container_id else 0 end) then return; end if;
  if p.gamemode = 3 or p.dead then perform mc.menu_resend(p_uuid); return; end if;
  if coalesce(ms.open, false) and not mc.menu_still_valid(ms, p) then return; end if;
  st := mc.mi_load(p_uuid); a := st;
  n := array_length(st.s_store, 1);
  if not (slot = -1 or slot = -999 or (slot >= 0 and slot < n)) then return; end if;
  stale := stid is distinct from st.state_id;
  before := mc.mi_all_slots(st);
  if ms.blk_sent is not null then                                                       -- the client's copy of the block's slots: what changed behind its back (a furnace) is sent with this click's diff
    for k in 0 .. n - 1 loop
      if st.s_store[k + 1] = 'blk' and ms.blk_sent[st.s_cs[k + 1] + 1] is not null then before[k + 1] := ms.blk_sent[st.s_cs[k + 1] + 1]; end if;
    end loop;
  end if;
  st := mc.mi_click(st, slot, button, inp);
  st := mc.mi_broadcast(st, before, claims, stale);
  perform mc.mi_store(p_uuid, a, st);
  if p.conn_id is not null and length(st.pkts) > 0 then insert into mc.play_out (conn_id, data) values (p.conn_id, st.pkts); end if;
  perform mc.menu_drop(p_uuid, st.drops);
  if st.aux = 1 and coalesce(ms.open, false) and ms.dimension is not null then perform mc.furnace_award(p_uuid, ms.dimension, ms.x, ms.y, ms.z); end if;
end $$;

-- AbstractContainerMenu.sendAllDataToRemote: the whole open menu again (a spectator or a dead player clicked)
create or replace function mc.menu_resend(p_uuid uuid) returns void language plpgsql as $$
declare st mc.mst; conn int;
begin
  select conn_id into conn from mc.player where uuid = p_uuid;
  st := mc.mi_load(p_uuid);
  st.state_id := (st.state_id + 1) & 32767;
  perform mc.mi_store(p_uuid, st, st);
  if conn is not null then insert into mc.play_out (conn_id, data) values (conn, mc.pkt_cc(st.cid, st.state_id, mc.mi_all_slots(st), st.carried)); end if;
end $$;

-- use_item_on on a container block.  True when the packet was consumed (the menu opened, the block change acknowledged); false: apply_block_actions gets it.
create or replace function mc.menu_try_open(p mc.player, body bytea) returns boolean language plpgsql as $$
declare o int; pos record; face int; f int; sq int; held int; dim text := 'minecraft:overworld'; state text; ci record; hold boolean;
begin
  if length(body) < 19 or p.dead then return false; end if;
  select r.nxt into o from proto.varint_read(body, 0) r;
  select * into pos from proto.position_read(body, o);
  select r.val, r.nxt into face, f from proto.varint_read(body, o + 8) r;
  if face is null or f + 14 >= length(body) + 1 then return false; end if;
  sq := (select r.val from proto.varint_read(body, f + 14) r);
  state := mc.get_block(dim, pos.x, pos.y, pos.z);
  if state is null then return false; end if;
  select * into ci from mc.container_info(state);
  if ci.kind is null then return false; end if;
  if not mc.in_block_reach(p.x, p.y, p.z, pos.x, pos.y, pos.z, p.gamemode) then return false; end if;
  if p.gamemode <> 3 then
    select exists (select 1 from mc.inventory_slot i where i.player = p.uuid and i.slot in (36 + p.held_slot, 45)) into hold;
    if p.sneaking and hold then                                                          -- ServerPlayerGameMode: secondary use with an item in a hand suppresses the block
      -- the item is used on the block instead; sql/410 places a block item (and sends its own updates), anything else leaves the packet's two updates to be sent here
      -- (handleUseItemOn sends the clicked block and the block beside the face whatever the result was: seen on the real server with a stick)
      if not exists (select 1 from mc.inventory_slot i join ref.block b on b.name = i.item
                      where i.player = p.uuid and i.slot = case (select r.val from proto.varint_read(body, 0) r) when 0 then 36 + p.held_slot else 45 end) then
        perform mc.queue_block_update(p.conn_id, pos.x, pos.y, pos.z, state);
        perform mc.queue_block_update(p.conn_id, pos.x + case face when 4 then -1 when 5 then 1 else 0 end, pos.y + case face when 0 then -1 when 1 then 1 else 0 end,
                                      pos.z + case face when 2 then -1 when 3 then 1 else 0 end,
                                      mc.get_block(dim, pos.x + case face when 4 then -1 when 5 then 1 else 0 end, pos.y + case face when 0 then -1 when 1 then 1 else 0 end,
                                                   pos.z + case face when 2 then -1 when 3 then 1 else 0 end));
      end if;                                                                           -- (the acknowledgement comes from sql/410, which still sees the packet)
      return false;
    end if;
  end if;
  if not mc.menu_open(p.uuid, dim, pos.x, pos.y, pos.z, false) then return false; end if;
  -- the block's menu provider ran (a barrel's state is open now)
  perform mc.menu_opened_state_hook(dim, pos.x, pos.y, pos.z, ci.blk);
  -- ServerGamePacketListenerImpl.handleUseItemOn: the clicked block (as it is now) and the block beside the clicked face are sent again (the client undoes its prediction), then the ack
  perform mc.queue_block_update(p.conn_id, pos.x, pos.y, pos.z, mc.get_block(dim, pos.x, pos.y, pos.z));
  perform mc.queue_block_update(p.conn_id, pos.x + case face when 4 then -1 when 5 then 1 else 0 end, pos.y + case face when 0 then -1 when 1 then 1 else 0 end,
                                pos.z + case face when 2 then -1 when 3 then 1 else 0 end,
                                mc.get_block(dim, pos.x + case face when 4 then -1 when 5 then 1 else 0 end, pos.y + case face when 0 then -1 when 1 then 1 else 0 end,
                                             pos.z + case face when 2 then -1 when 3 then 1 else 0 end));
  perform mc.menu_opened_event_hook(p.uuid, dim, ci.blk);                               -- the lid: a block event, run after the packets of the tick
  if sq is not null then insert into mc.pending_ack (conn_id, sequence) values (p.conn_id, sq); end if;
  return true;
end $$;

------------------------------------------------------------------------------------------------ the tick step (the one hook line in mc.tick_core)
create or replace function mc.container_step(p_cur bigint) returns void language plpgsql as $$
declare i_click int := mc.sid('container_click'); i_close int := mc.sid('container_close'); i_input int := mc.sid('player_input'); i_use int := mc.sid('use_item_on');
        r record; msr mc.menu_state; pl mc.player; sig_blk text; vison boolean := mc.vis_on();
begin
  for r in select m.seq, m.packet_id, m.body, p as pl from mc.play_in_work m join mc.player p on p.conn_id = m.conn_id
            where m.packet_id in (i_click, i_close, i_input, i_use) order by m.seq loop
    begin
      if r.packet_id = i_input then
        if length(r.body) >= 1 then update mc.player set sneaking = (get_byte(r.body, 0) & 32) <> 0 where uuid = (r.pl).uuid and sneaking is distinct from ((get_byte(r.body, 0) & 32) <> 0); end if;
      elsif r.packet_id = i_click then perform mc.menu_handle_click((r.pl).uuid, r.body);
      elsif r.packet_id = i_close then perform mc.menu_do_close((r.pl).uuid, false);
      elsif r.packet_id = i_use then
        if mc.menu_try_open(mc.player_by_uuid((r.pl).uuid), r.body) then delete from mc.play_in_work where seq = r.seq; end if;
      end if;
    exception when others then
      raise notice 'mc.container_step: packet % from connection ignored: %', r.packet_id, sqlerrm;
    end;
  end loop;
  delete from mc.play_in_work where packet_id in (i_click, i_close) or (packet_id = i_input and not vison);       -- (with the vanilla tracker, sql/904 reads the shift key from the same packets and removes them)
  -- menus whose block is gone or whose player walked away close (ServerPlayer.tick: containerMenu.stillValid)
  for msr in select * from mc.menu_state where open loop
    select * into pl from mc.player where uuid = msr.player;
    if pl.conn_id is null or not mc.menu_still_valid(msr, pl, (p_cur + abs(hashtext(msr.player::text))) % 20 = 0) then perform mc.menu_do_close(msr.player, true); end if;
  end loop;
  -- ContainerOpenersCounter.recheckOpeners: while a chest is open its lid is signalled again every 5 ticks (the scheduled tick of the block)
  for msr in select distinct on (x, y, z) * from mc.menu_state where open and kind like 'generic_9x%' and p_cur > opened_at and (p_cur - opened_at) % 5 = 0 order by x, y, z, opened_at loop
    sig_blk := split_part(mc.get_block(coalesce(msr.dimension, 'minecraft:overworld'), msr.x, msr.y, msr.z), '[', 1);
    if sig_blk not in ('minecraft:chest', 'minecraft:trapped_chest', 'minecraft:ender_chest') then continue; end if;      -- (a barrel has no lid: its open state is a block property)
    perform mc.chest_signal(coalesce(msr.dimension, 'minecraft:overworld'), msr.x, msr.y, msr.z, sig_blk);
    if msr.x2 is not null then perform mc.chest_signal(msr.dimension, msr.x2, msr.y2, msr.z2, sig_blk); end if;
  end loop;
  perform mc.menu_sync();                                                               -- (the player's tick: broadcastChanges) before the block entities tick
  perform mc.furnace_step(p_cur);
end $$;
create or replace function mc.player_by_uuid(p_uuid uuid) returns mc.player language sql stable as $$ select p from mc.player p where p.uuid = p_uuid $$;

-- a change of the crafting grid made behind the menu's back (a creative slot packet): the inventory menu recomputes its result and sends it (ServerPlayer / Slot.set)
create or replace function mc.menu_grid_changed(p_uuid uuid) returns void language plpgsql as $$
declare st mc.mst; a mc.mst; conn int;
begin
  select conn_id into conn from mc.player where uuid = p_uuid;
  st := mc.mi_load(p_uuid, true); a := st;
  st := mc.mi_fire(st);
  perform mc.mi_store(p_uuid, a, st, true);
  if conn is not null and length(st.pkts) > 0 then insert into mc.play_out (conn_id, data) values (conn, st.pkts); end if;
end $$;
