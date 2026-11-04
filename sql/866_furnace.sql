-- Containers, crafting and recipes, part 7: furnaces, blast furnaces and smokers.
--
-- A transcription of AbstractFurnaceBlockEntity.serverTick / consumeFuel / canBurn / burn / getTotalCookTime / setItem (26.3 bytecode).  In 26.x the fuel's burn time and speed
-- come from the cooking_fuel component's providers: N / (fast_cooking block ? 2 : 1) ticks and speed 1 / 2: a blast furnace and a smoker burn fuel in half the time and cook
-- at twice the speed (the recipes' cookingtime is 200 for smelting and blasting, 100 for smoking is NOT halved: speed multiplies).  Per tick:
--   lit time counts down; with something to cook and a recipe whose result fits, a new fuel item is consumed when the furnace is not lit (the cooking progress is
--   rescaled to the new total), the progress grows by one and at the total the input shrinks and the result grows; a furnace that is not lit and cannot cook cools
--   its progress down by two a tick; the block's lit property follows (mc.set_block, so the clients see it).
-- Only furnaces with a row in mc.furnace tick (a menu touched them); a furnace with nothing left to do loses its row.
-- Open menus learn about changes one tick later (mc.menu_sync: vanilla's broadcastChanges runs in the player's tick, the block entity tick comes after it).

create or replace function mc.furnace_touch(p_dim text, px int, py int, pz int, p_kind text, p_reset boolean default false) returns void language plpgsql as $$
declare spd real;
begin
  insert into mc.furnace (dimension, x, y, z, kind) values (p_dim, px, py, pz, p_kind) on conflict on constraint furnace_pkey do update set kind = excluded.kind, steady = false;
  if p_reset then       -- AbstractFurnaceBlockEntity.setItem(0, ...) of another item: the total is recomputed, the progress restarts
    select f.speed into spd from mc.furnace f where f.dimension = p_dim and f.x = px and f.y = py and f.z = pz;
    update mc.furnace f set cook_progress = 0,
           cook_total = mc.furnace_total_time(p_kind, (select c.item from mc.container_slot c where c.dimension = p_dim and c.x = px and c.y = py and c.z = pz and c.slot = 0), spd)
     where f.dimension = p_dim and f.x = px and f.y = py and f.z = pz;
  end if;
end $$;

-- the recipe an input item has in this kind of furnace: (id, result item, count, cooking time, experience)
create or replace function mc.furnace_recipe(p_kind text, p_item text) returns table (id text, result_item text, result_count int, cookingtime int, experience real) language sql stable as $$
    select r.id, r.result_item, r.result_count, r.cookingtime, r.experience
      from ref.recipe r join ref.ingredient i on i.id = r.ingredient
     where r.type = case p_kind when 'blast_furnace' then 'blasting' when 'smoker' then 'smoking' else 'smelting' end and p_item = any (i.items)
     order by r.id limit 1 $$;

-- getTotalCookTime: cookingtime / speed, rounded up; 200 without a recipe
create or replace function mc.furnace_total_time(p_kind text, p_item text, p_speed real) returns int language sql stable as $$
    select coalesce((select case when p_speed > 0 then ceil(r.cookingtime::real / p_speed)::int else r.cookingtime end from mc.furnace_recipe(p_kind, p_item) r), 200) $$;

-- the ticking of every furnace that has a row
create or replace function mc.furnace_step(p_cur bigint) returns void language plpgsql as $$
declare f record; lit boolean; was_lit boolean; changed boolean; lit_t int; lit_d int; prog int; tot int; spd real; rec record; fuel_burn int; fast boolean;
        i0 text; n0 int; c0 text; i1 text; n1 int; c1 text; i2 text; n2 int; c2 text; frac real; res_item text; res_n int; ok boolean; rem text; used jsonb;
        new_state text; cur_state text; steady_next boolean;
begin
  if not exists (select 1 from mc.furnace) then return; end if;
  perform set_config('mc.furnace_skip', 'on', true);
  -- The common case, set-based: a lit furnace that keeps burning and cooking and whose slots nobody touched (steady, see the end of the loop) only counts.  Its row is
  -- updated here and left out of the loop below (the data-modifying CTE and the loop's query share one snapshot).
  for f in
    with quick as (
      update mc.furnace u set lit_time = u.lit_time - 1, cook_progress = u.cook_progress + 1
       where u.steady and u.lit_time > 1 and u.cook_progress + 1 < u.cook_total
      returning u.dimension, u.x, u.y, u.z)
    select fu.*,
           (select c.item from mc.container_slot c where c.dimension = fu.dimension and c.x = fu.x and c.y = fu.y and c.z = fu.z and c.slot = 0) as i0,
           (select c.count from mc.container_slot c where c.dimension = fu.dimension and c.x = fu.x and c.y = fu.y and c.z = fu.z and c.slot = 0) as n0,
           (select c.components ->> 'raw_hex' from mc.container_slot c where c.dimension = fu.dimension and c.x = fu.x and c.y = fu.y and c.z = fu.z and c.slot = 0) as c0,
           (select c.item from mc.container_slot c where c.dimension = fu.dimension and c.x = fu.x and c.y = fu.y and c.z = fu.z and c.slot = 1) as i1,
           (select c.count from mc.container_slot c where c.dimension = fu.dimension and c.x = fu.x and c.y = fu.y and c.z = fu.z and c.slot = 1) as n1,
           (select c.components ->> 'raw_hex' from mc.container_slot c where c.dimension = fu.dimension and c.x = fu.x and c.y = fu.y and c.z = fu.z and c.slot = 1) as c1,
           (select c.item from mc.container_slot c where c.dimension = fu.dimension and c.x = fu.x and c.y = fu.y and c.z = fu.z and c.slot = 2) as i2,
           (select c.count from mc.container_slot c where c.dimension = fu.dimension and c.x = fu.x and c.y = fu.y and c.z = fu.z and c.slot = 2) as n2,
           (select c.components ->> 'raw_hex' from mc.container_slot c where c.dimension = fu.dimension and c.x = fu.x and c.y = fu.y and c.z = fu.z and c.slot = 2) as c2
      from mc.furnace fu
     where not exists (select 1 from quick k where (k.dimension, k.x, k.y, k.z) = (fu.dimension, fu.x, fu.y, fu.z))
  loop
    i0 := f.i0; n0 := f.n0; c0 := f.c0; i1 := f.i1; n1 := f.n1; c1 := f.c1; i2 := f.i2; n2 := f.n2; c2 := f.c2;
    lit_t := f.lit_time; lit_d := f.lit_duration; prog := f.cook_progress; tot := f.cook_total; spd := f.speed; used := f.recipes_used;
    changed := false; steady_next := false; fast := f.kind in ('blast_furnace', 'smoker');
    was_lit := lit_t > 0;
    if lit_t > 0 then lit_t := lit_t - 1; lit := lit_t > 0; else lit := false; end if;
    if lit or (i1 is not null and i0 is not null) then
      if i0 is not null then
        select * into rec from mc.furnace_recipe(f.kind, i0);
        if rec.id is not null then
          res_item := rec.result_item; res_n := rec.result_count;
          -- canBurn: the result slot is empty or holds the same item (no components) with room
          ok := i2 is null or (i2 = res_item and c2 is null and n2 + res_n <= least(99, mc.s_max(i2)));
          if ok then
            if not lit then
              fuel_burn := coalesce((select d.burn_ticks from ref.item_def d where d.item = i1), 0) / case when fast then 2 else 1 end;
              lit_t := fuel_burn; lit_d := fuel_burn; spd := case when fast then 2 else 1 end;
              if tot > 0 and prog < tot then
                frac := prog::real / tot::real;
                tot := case when spd > 0 then ceil(rec.cookingtime::real / spd)::int else rec.cookingtime end;
                prog := ceil((frac * tot::real)::float8)::int;
              end if;
              if fuel_burn > 0 then
                -- consumeFuel: one item less; a bucket (lava) stays behind
                rem := (select d.remainder from ref.item_def d where d.item = i1);
                n1 := n1 - 1;
                if n1 <= 0 then i1 := rem; n1 := case when rem is null then 0 else 1 end; c1 := null; if rem is null then i1 := null; end if; end if;
                lit := true; changed := true;
              end if;
            end if;
            if lit then
              prog := prog + 1;
              if prog >= tot then
                prog := 0; tot := case when spd > 0 then ceil(rec.cookingtime::real / spd)::int else rec.cookingtime end;
                -- burn: the result grows, the input shrinks (a wet sponge turns a bucket in the fuel slot into a water bucket)
                if i2 is null then i2 := res_item; n2 := res_n; c2 := null; else n2 := n2 + res_n; end if;
                if i0 = 'minecraft:wet_sponge' and i1 = 'minecraft:bucket' then i1 := 'minecraft:water_bucket'; n1 := 1; c1 := null; end if;
                n0 := n0 - 1; if n0 <= 0 then i0 := null; n0 := 0; c0 := null; end if;
                used := jsonb_set(used, array[rec.id], to_jsonb(coalesce((used ->> rec.id)::int, 0) + 1), true);
                changed := true;
              else
                steady_next := lit_t > 1;       -- the next tick is the same again (the fast path above checks the progress against the total)
              end if;
            else prog := 0; end if;
          else prog := 0; end if;
        end if;
      else prog := 0; end if;
    elsif prog > 0 then
      prog := greatest(0, least(prog - 2, tot));
    end if;
    if was_lit <> lit then
      changed := true;
      cur_state := mc.get_block(f.dimension, f.x, f.y, f.z);
      if split_part(cur_state, '[', 1) = 'minecraft:' || f.kind then
        new_state := replace(cur_state, 'lit=' || (not lit)::text, 'lit=' || lit::text);
        if new_state <> cur_state then perform mc.set_block(f.dimension, f.x, f.y, f.z, new_state); end if;
      end if;
    end if;
    if changed or lit_t <> f.lit_time or prog <> f.cook_progress or tot <> f.cook_total or steady_next <> f.steady then
      -- slots: write what changed
      if (i0, n0, c0, i1, n1, c1, i2, n2, c2) is distinct from (f.i0, f.n0, f.c0, f.i1, f.n1, f.c1, f.i2, f.n2, f.c2) then
        perform mc.container_set(f.dimension, f.x, f.y, f.z, 0, i0, n0, c0);
        perform mc.container_set(f.dimension, f.x, f.y, f.z, 1, i1, n1, c1);
        perform mc.container_set(f.dimension, f.x, f.y, f.z, 2, i2, n2, c2);
      end if;
      update mc.furnace u set lit_time = lit_t, lit_duration = lit_d, cook_progress = prog, cook_total = tot, speed = spd, recipes_used = used, steady = steady_next
       where u.dimension = f.dimension and u.x = f.x and u.y = f.y and u.z = f.z;
    end if;
    -- nothing left to do: forget the furnace (it is touched again when a menu changes it)
    if lit_t <= 0 and prog <= 0 and not (i1 is not null and i0 is not null) then
      delete from mc.furnace u where u.dimension = f.dimension and u.x = f.x and u.y = f.y and u.z = f.z and u.recipes_used = '{}'::jsonb;
    end if;
  end loop;
  perform set_config('mc.furnace_skip', 'off', true);
end $$;

-- write one slot of a block container (null item = empty)
create or replace function mc.container_set(p_dim text, px int, py int, pz int, p_slot int, p_item text, p_n int, p_comp text) returns void language plpgsql as $$
begin
  if p_item is null or coalesce(p_n, 0) <= 0 then
    delete from mc.container_slot c where c.dimension = p_dim and c.x = px and c.y = py and c.z = pz and c.slot = p_slot;
  else
    insert into mc.container_slot (dimension, x, y, z, slot, item, count, components)
    values (p_dim, px, py, pz, p_slot, p_item, p_n, case when p_comp is null then null else jsonb_build_object('raw_hex', p_comp) end)
    on conflict on constraint container_slot_pkey do update set item = excluded.item, count = excluded.count, components = excluded.components
     where (mc.container_slot.item, mc.container_slot.count, mc.container_slot.components) is distinct from (excluded.item, excluded.count, excluded.components);
  end if;
end $$;

-- FurnaceResultSlot.onTake: the experience of the used recipes (floor(count * experience), the fraction as a chance) goes to the player (vanilla pops orbs; here the
-- points are given directly).  Called by the click handler when a result was taken.
create or replace function mc.furnace_award(p_uuid uuid, p_dim text, px int, py int, pz int) returns void language plpgsql as $$
declare u jsonb; k text; pts float8 := 0; tot int := 0; e real;
begin
  select recipes_used into u from mc.furnace f where f.dimension = p_dim and f.x = px and f.y = py and f.z = pz;
  if u is null or u = '{}'::jsonb then return; end if;
  for k in select jsonb_object_keys(u) loop
    select experience into e from ref.recipe where id = k;
    pts := (u ->> k)::int * coalesce(e, 0);
    tot := tot + floor(pts)::int + case when pts - floor(pts) <> 0 and random() < pts - floor(pts) then 1 else 0 end;
  end loop;
  update mc.furnace f set recipes_used = '{}' where f.dimension = p_dim and f.x = px and f.y = py and f.z = pz;
  if tot > 0 then perform mc.xp_give(p_uuid, tot); end if;
end $$;

-- AbstractContainerMenu.broadcastChanges for the menus whose block container changed behind the client's back (another player, a furnace): container_set_slot per changed
-- slot with the next state id, then the furnace's data values that differ
create or replace function mc.menu_sync() returns void language plpgsql as $$
declare ms mc.menu_state; p mc.player; cur mc.stk[]; i int; st int; pk bytea; f mc.furnace; dat int[]; n int;
begin
  for ms in select * from mc.menu_state where open and dimension is not null loop
    select * into p from mc.player where uuid = ms.player;
    continue when p.conn_id is null;
    n := coalesce(array_length(ms.blk_sent, 1), 0);
    continue when n = 0;
    if ms.kind like 'generic_9x%' or ms.kind in ('furnace', 'blast_furnace', 'smoker') then
      select array_agg(row(c.item, coalesce(c.count, 0), c.components ->> 'raw_hex')::mc.stk order by g) into cur
        from generate_series(0, n - 1) g
        left join mc.container_slot c on c.dimension = ms.dimension and c.slot = case when ms.x2 is null then g else g % 27 end
             and ((ms.x2 is null and c.x = ms.x and c.y = ms.y and c.z = ms.z)
               or (ms.x2 is not null and ((g < 27 and c.x = ms.x and c.y = ms.y and c.z = ms.z) or (g >= 27 and c.x = ms.x2 and c.y = ms.y2 and c.z = ms.z2))));
      st := ms.state_id; pk := '\x'::bytea;
      for i in 0 .. n - 1 loop
        if not mc.s_matches(ms.blk_sent[i + 1], cur[i + 1]) then
          st := (st + 1) & 32767;
          pk := pk || mc.pkt_cs(ms.container_id, st, i, case when mc.s_is_empty(cur[i + 1]) then mc.s_empty() else cur[i + 1] end);
        end if;
      end loop;
      dat := ms.data;
      if ms.kind in ('furnace', 'blast_furnace', 'smoker') then
        select * into f from mc.furnace where dimension = ms.dimension and x = ms.x and y = ms.y and z = ms.z;
        dat := array[coalesce(f.lit_time, 0), coalesce(f.lit_duration, 0), coalesce(f.cook_progress, 0), coalesce(f.cook_total, 0)];
        for i in 0 .. 3 loop
          if ms.data[i + 1] is distinct from dat[i + 1] then pk := pk || mc.pkt_container_data(ms.container_id, i, dat[i + 1]); end if;
        end loop;
      end if;
      if length(pk) > 0 then
        insert into mc.play_out (conn_id, data) values (p.conn_id, pk);
        update mc.menu_state set state_id = st, blk_sent = cur, data = dat where player = ms.player;
      end if;
    end if;
  end loop;
end $$;

------------------------------------------------------------------------------------------------ furnaces filled by anything else than a menu
-- A furnace block whose slots are written by SQL, a command or another track's code must tick as well: rows written into slot 0 or 1 of a furnace-kind block get a mc.furnace
-- row, and a new, different or removed input restarts the cooking exactly like AbstractFurnaceBlockEntity.setItem(0, ..) does.  The menu code and the furnace step write the
-- same rows themselves (and set mc.furnace_skip) so the triggers stay out of their way.
create or replace function mc.furnace_kind_at(p_dim text, x int, y int, z int) returns text language sql stable as $$
    select case split_part(mc.get_block(p_dim, x, y, z), '[', 1) when 'minecraft:furnace' then 'furnace' when 'minecraft:blast_furnace' then 'blast_furnace' when 'minecraft:smoker' then 'smoker' end $$;

create or replace function mc.container_slot_ins() returns trigger language plpgsql as $$
declare r record;
begin
  if current_setting('mc.furnace_skip', true) = 'on' then return null; end if;
  for r in select n.dimension, n.x, n.y, n.z, n.slot, n.item from nr n where n.slot in (0, 1) loop
    continue when mc.furnace_kind_at(r.dimension, r.x, r.y, r.z) is null;
    perform mc.furnace_touch(r.dimension, r.x, r.y, r.z, mc.furnace_kind_at(r.dimension, r.x, r.y, r.z), r.slot = 0);
  end loop;
  return null;
end $$;
create or replace function mc.container_slot_upd() returns trigger language plpgsql as $$
declare r record;
begin
  if current_setting('mc.furnace_skip', true) = 'on' then return null; end if;
  for r in select n.dimension, n.x, n.y, n.z, n.slot, (o.item is distinct from n.item or o.components is distinct from n.components) as changed
             from nr n join orr o on (o.dimension, o.x, o.y, o.z, o.slot) = (n.dimension, n.x, n.y, n.z, n.slot) where n.slot in (0, 1) loop
    continue when mc.furnace_kind_at(r.dimension, r.x, r.y, r.z) is null;
    perform mc.furnace_touch(r.dimension, r.x, r.y, r.z, mc.furnace_kind_at(r.dimension, r.x, r.y, r.z), r.slot = 0 and r.changed);
  end loop;
  return null;
end $$;
create or replace function mc.container_slot_del() returns trigger language plpgsql as $$
declare r record;
begin
  if current_setting('mc.furnace_skip', true) = 'on' then return null; end if;
  for r in select o.dimension, o.x, o.y, o.z from orr o where o.slot = 0 loop
    continue when mc.furnace_kind_at(r.dimension, r.x, r.y, r.z) is null;
    perform mc.furnace_touch(r.dimension, r.x, r.y, r.z, mc.furnace_kind_at(r.dimension, r.x, r.y, r.z), true);
  end loop;
  return null;
end $$;
drop trigger if exists container_slot_ins on mc.container_slot; drop trigger if exists container_slot_upd on mc.container_slot; drop trigger if exists container_slot_del on mc.container_slot;
create trigger container_slot_ins after insert on mc.container_slot referencing new table as nr for each statement execute function mc.container_slot_ins();
create trigger container_slot_upd after update on mc.container_slot referencing old table as orr new table as nr for each statement execute function mc.container_slot_upd();
create trigger container_slot_del after delete on mc.container_slot referencing old table as orr for each statement execute function mc.container_slot_del();
