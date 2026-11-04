-- Containers, crafting and recipes, part 2: item stack helpers and recipe matching (set-based over the rows of ref.recipe).
--
-- Matching follows net.minecraft.world.item.crafting (read with javap):
--   CraftingInput.ofPositioned trims the grid to the bounding box of its non-empty cells; ShapedRecipePattern.matches compares the trimmed size with the pattern
--   and every cell, trying the mirrored pattern too unless it is symmetrical; ShapelessRecipe.matches needs as many ingredients as items and an assignment of
--   items to ingredients (bipartite matching: done here with Hall's condition over the subsets of the items).  Among several matching recipes the first by id wins
--   (vanilla: the registration order of the datapack, the same for the vanilla recipes whose results differ; no two vanilla recipes match the same grid).

------------------------------------------------------------------------------------------------ item stacks
create or replace function mc.s_empty() returns mc.stk language sql immutable parallel safe as $$ select row(null::text, 0, null::text)::mc.stk $$;
create or replace function mc.s_is_empty(s mc.stk) returns boolean language sql immutable parallel safe as $$ select s.item is null or coalesce(s.n, 0) <= 0 $$;
-- a stack with a count: an empty one when the count is not positive
create or replace function mc.s_mk(p_item text, p_n int, p_comp text) returns mc.stk language sql immutable parallel safe as $$
    select case when p_item is null or coalesce(p_n, 0) <= 0 then row(null::text, 0, null::text)::mc.stk else row(p_item, p_n, p_comp)::mc.stk end $$;
create or replace function mc.s_with(s mc.stk, p_n int) returns mc.stk language sql immutable parallel safe as $$ select mc.s_mk(s.item, p_n, s.comp) $$;
-- ItemStack.isSameItem / isSameItemSameComponents / matches
create or replace function mc.s_same_item(a mc.stk, b mc.stk) returns boolean language sql immutable parallel safe as $$
    select (mc.s_is_empty(a) and mc.s_is_empty(b)) or (a.item is not distinct from b.item) $$;
create or replace function mc.s_same(a mc.stk, b mc.stk) returns boolean language sql immutable parallel safe as $$
    select (mc.s_is_empty(a) and mc.s_is_empty(b)) or (a.item is not distinct from b.item and a.comp is not distinct from b.comp) $$;
create or replace function mc.s_matches(a mc.stk, b mc.stk) returns boolean language sql immutable parallel safe as $$
    select (mc.s_is_empty(a) and mc.s_is_empty(b)) or (coalesce(a.n, 0) = coalesce(b.n, 0) and a.item is not distinct from b.item and a.comp is not distinct from b.comp) $$;
-- ItemStack.getMaxStackSize (minecraft:max_stack_size of the item)
create or replace function mc.s_max(p_item text) returns int language sql stable parallel safe as $$
    select coalesce((select max_stack from ref.item_def where item = p_item), 64) $$;
-- the stack as the wire carries it (ItemStack.OPTIONAL_STREAM_CODEC): VarInt count (0 = empty), VarInt item id, the component patch (VarInt added, VarInt removed, entries)
create or replace function mc.s_wire(s mc.stk) returns bytea language sql stable parallel safe as $$
    select case when mc.s_is_empty(s) then '\x00'::bytea
                else proto.varint(s.n) || proto.varint(mc.item_id(s.item)) || coalesce(decode(s.comp, 'hex'), '\x0000'::bytea) end $$;
-- the elements of a stack array with their 1-based position (unnest would expand the composite into its columns)
create or replace function mc.stk_rows(arr mc.stk[]) returns table (ord int, s mc.stk) language sql immutable parallel safe as $$
    select g, arr[g] from generate_series(1, coalesce(array_length(arr, 1), 0)) g $$;
-- rows of mc.inventory_slot / mc.container_slot -> stack
create or replace function mc.s_row(p_item text, p_n int, p_comp jsonb) returns mc.stk language sql immutable parallel safe as $$
    select mc.s_mk(p_item, p_n, p_comp ->> 'raw_hex') $$;

------------------------------------------------------------------------------------------------ recipes
-- Hall's condition: items k = 0..n-1 can be assigned to distinct ingredients when every subset S of the items has at least |S| ingredients that accept one of them.
-- adj[k + 1] = bit mask of the ingredients item k fits.
create or replace function mc.hall_ok(adj int[], n int) returns boolean language plpgsql immutable parallel safe as $$
declare nb int[] := array_fill(0, array[(1 << n)]); pc int[] := array_fill(0, array[(1 << n)]); s int; low int; k int; c int; m int;
begin
  for s in 1 .. (1 << n) - 1 loop
    low := s & -s; k := 0; while (1 << k) <> low loop k := k + 1; end loop;
    nb[s + 1] := nb[(s - low) + 1] | adj[k + 1];
    pc[s + 1] := pc[(s - low) + 1] + 1;
    m := nb[s + 1]; c := 0; while m <> 0 loop c := c + (m & 1); m := m >> 1; end loop;
    if c < pc[s + 1] then return false; end if;
  end loop;
  return true;
end $$;

-- Does a shapeless / transmute recipe accept exactly these items (one per non-empty grid cell)?
create or replace function mc.shapeless_ok(p_recipe text, p_items text[]) returns boolean language plpgsql stable as $$
declare n int := coalesce(array_length(p_items, 1), 0); ing int[]; adj int[] := '{}'; k int; j int; mask int; its text[];
begin
  select array_agg(ingredient order by pos) into ing from ref.recipe_slot where recipe = p_recipe;
  if ing is null or array_length(ing, 1) <> n then return false; end if;
  for k in 1 .. n loop
    mask := 0;
    for j in 1 .. n loop
      select items into its from ref.ingredient where id = ing[j];
      if p_items[k] = any (its) then mask := mask | (1 << (j - 1)); end if;
    end loop;
    if mask = 0 then return false; end if;
    adj := adj || mask;
  end loop;
  return mc.hall_ok(adj, n);
end $$;

-- The recipe a crafting grid matches, or null.  p_items: the grid, row-major, null for an empty cell.
create or replace function mc.craft_match(p_w int, p_h int, p_items text[]) returns text language plpgsql stable as $$
declare minx int := 99; maxx int := -1; miny int := 99; maxy int := -1; x int; y int; n int := 0; tw int; th int; tg text[] := '{}'; flat text[] := '{}'; rid text;
begin
  for y in 0 .. p_h - 1 loop
    for x in 0 .. p_w - 1 loop
      if p_items[y * p_w + x + 1] is not null then
        n := n + 1; minx := least(minx, x); maxx := greatest(maxx, x); miny := least(miny, y); maxy := greatest(maxy, y);
        flat := flat || p_items[y * p_w + x + 1];
      end if;
    end loop;
  end loop;
  if n = 0 then return null; end if;
  tw := maxx - minx + 1; th := maxy - miny + 1;
  for y in miny .. maxy loop for x in minx .. maxx loop tg := array_append(tg, p_items[y * p_w + x + 1]); end loop; end loop;
  -- shaped (a cell the pattern leaves empty is empty in the grid by the count: both have n non-empty cells)
  select r.id into rid from ref.recipe r
   where r.type = 'crafting_shaped' and r.w = tw and r.h = th and r.n_ingredients = n
     and (not exists (select 1 from ref.recipe_slot s join ref.ingredient i on i.id = s.ingredient
                       where s.recipe = r.id and not coalesce(tg[s.pos + 1] = any (i.items), false))
          or not exists (select 1 from ref.recipe_slot s join ref.ingredient i on i.id = s.ingredient
                          where s.recipe = r.id and not coalesce(tg[(s.pos / tw) * tw + (tw - 1 - s.pos % tw) + 1] = any (i.items), false)))
   order by r.id limit 1;
  if rid is not null then return rid; end if;
  -- shapeless and transmute: a quick filter in SQL, then the exact assignment
  for rid in
    select r.id from ref.recipe r
     where r.type in ('crafting_shapeless', 'crafting_transmute') and r.n_ingredients = n
       and not exists (select 1 from ref.recipe_slot s join ref.ingredient i on i.id = s.ingredient
                        where s.recipe = r.id and not exists (select 1 from unnest(flat) g where g = any (i.items)))
       and not exists (select 1 from unnest(flat) g where not exists (select 1 from ref.recipe_slot s join ref.ingredient i on i.id = s.ingredient
                                                                       where s.recipe = r.id and g = any (i.items)))
     order by r.id
  loop
    if mc.shapeless_ok(rid, flat) then return rid; end if;
  end loop;
  return null;
end $$;

-- CraftingRecipe.assemble: the result stack.  A transmute recipe keeps the components of its input item (the grid item its first ingredient accepts).
-- p_items / p_comps: the non-empty grid cells in row-major order.
create or replace function mc.craft_result(p_recipe text, p_items text[], p_comps text[]) returns mc.stk language plpgsql stable as $$
declare r ref.recipe; comp text; k int; its text[];
begin
  select * into r from ref.recipe where id = p_recipe;
  if r.id is null then return mc.s_empty(); end if;
  if r.type = 'crafting_transmute' then
    select i.items into its from ref.recipe_slot s join ref.ingredient i on i.id = s.ingredient where s.recipe = p_recipe and s.pos = 0;
    for k in 1 .. coalesce(array_length(p_items, 1), 0) loop
      if p_items[k] = any (its) then comp := p_comps[k]; exit; end if;
    end loop;
    return mc.s_mk(r.result_item, r.result_count + case when r.flag then r.n_ingredients - 1 else 0 end, comp);
  end if;
  return mc.s_mk(r.result_item, r.result_count, null);
end $$;
