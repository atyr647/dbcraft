-- World dynamics, part 6: the tick step and the entry points that feed the engine (sql/884).
--
--   mc.dyn_step(cur)        called once per tick by mc.tick_core (sql/837): runs the scheduled block ticks, then the fluid ticks that are due in chunks a player simulates, in vanilla's
--                           order (priority, then the order they were scheduled), then the random ticks (sql/887), then the landings of falling blocks (the entity phase).
--                           It costs a few index probes when nothing is due.
--   mc.dyn_on_events()      statement trigger on mc.block_event: a block changed from outside (a player, a command, SQL): onPlace of the new block and the neighbour updates
--   mc.dyn_schedule(...)    schedule a tick from SQL
--
-- Which chunks tick: vanilla runs scheduled ticks only in chunks inside the players' simulation distance (DistanceManager.inBlockTickingRange); ticks elsewhere wait in the
-- chunk.  dbcraft: a chunk ticks when an online player's chunk is within simulation-distance chunks of it (square, Chebyshev).

create index if not exists block_tick_due_only_idx on mc.block_tick (due);

-- position of a key in a sorted int8 array (binary search), null when absent
create or replace function mc.dyn_bsearch(p_arr int8[], p_key int8) returns int language plpgsql immutable parallel safe as $$
declare lo int := 1; hi int := cardinality(p_arr); mid int;
begin
    while lo <= hi loop
        mid := (lo + hi) / 2;
        if p_arr[mid] = p_key then return mid; elsif p_arr[mid] < p_key then lo := mid + 1; else hi := mid - 1; end if;
    end loop;
    return null;
end $$;

-- connected components of a set of chunk coordinates, where two chunks are connected when they are at most one apart in both axes: ticks inside one component can influence each other
-- (a fluid reaches 4 blocks, a cascade 1), ticks in different components cannot, so each component is run on its own part of the world.  Returns the component number (1 ..) of every
-- input position.
create or replace function mc.dyn_components(p_cx int[], p_cz int[]) returns int[] language plpgsql immutable as $$
declare
    n int := coalesce(cardinality(p_cx), 0); ukeys int8[]; ulab int[]; un int; i int; j int; comp int := 0; stack int[]; sp int; cur int; dx int; dz int; nk int8; pos int; res int[];
begin
    if n = 0 then return '{}'; end if;
    select array_agg(k order by k) into ukeys from (select distinct (t.cx::int8 << 32) | (t.cz::int8 & 4294967295) as k from unnest(p_cx, p_cz) t(cx, cz)) q;
    un := cardinality(ukeys); ulab := array_fill(0, array[un]); stack := array_fill(0, array[un + 1]);
    for i in 1 .. un loop
        if ulab[i] <> 0 then continue; end if;
        comp := comp + 1; ulab[i] := comp; sp := 1; stack[1] := i;
        while sp > 0 loop
            cur := stack[sp]; sp := sp - 1;
            for dx in -1 .. 1 loop
                for dz in -1 .. 1 loop
                    if dx = 0 and dz = 0 then continue; end if;
                    nk := (((ukeys[cur] >> 32) + dx) << 32) | ((((ukeys[cur] & 4294967295) - (case when (ukeys[cur] & 2147483648) <> 0 then 4294967296 else 0 end)) + dz) & 4294967295);
                    pos := mc.dyn_bsearch(ukeys, nk);
                    if pos is not null and ulab[pos] = 0 then ulab[pos] := comp; sp := sp + 1; stack[sp] := pos; end if;
                end loop;
            end loop;
        end loop;
    end loop;
    res := array_fill(0, array[n]);
    for j in 1 .. n loop
        res[j] := ulab[mc.dyn_bsearch(ukeys, (p_cx[j]::int8 << 32) | (p_cz[j]::int8 & 4294967295))];
    end loop;
    return res;
end $$;

-- is the chunk (cx, cz) simulated by an online player?
create or replace function mc.dyn_ticking(p_cx int, p_cz int) returns boolean language sql stable as $$
  select exists (select 1 from mc.player p where p.conn_id is not null and abs(p.chunk_x - p_cx) <= mc.prop_int('simulation-distance') and abs(p.chunk_z - p_cz) <= mc.prop_int('simulation-distance')) $$;

-- Run the due ticks of one kind ('b' blocks, 'f' fluids).  The ticks are taken out of the queue first (vanilla polls them before running, so a tick may schedule itself again).
create or replace function mc.dyn_run_due(p_cur bigint, p_kind "char", p_max int) returns int language plpgsql volatile as $$
declare
    dim text := coalesce((select default_dimension from mc.world limit 1), 'minecraft:overworld');
    r int := mc.prop_int('simulation-distance');
    tk "char"[]; tx int[]; ty int[]; tz int[]; tt text[]; comp int[]; c int; kinds int[]; xs int[]; ys int[]; zs int[]; auxs int[]; total int := 0; k int; ftypes text[] := array['minecraft:water', 'minecraft:flowing_water', 'minecraft:lava', 'minecraft:flowing_lava'];
begin
    with due as materialized (
        select t.dimension, t.x, t.y, t.z, t.type, t.prio, t.seq
          from mc.block_tick t
         where t.kind = p_kind and t.due <= p_cur and t.dimension = dim
           and exists (select 1 from mc.player p where p.conn_id is not null and abs(p.chunk_x - (t.x >> 4)) <= r and abs(p.chunk_z - (t.z >> 4)) <= r)
         order by t.prio, t.seq limit p_max),
         del as (delete from mc.block_tick t using due d where t.dimension = d.dimension and t.x = d.x and t.y = d.y and t.z = d.z and t.kind = p_kind and t.type = d.type returning d.x, d.y, d.z, d.type, d.prio, d.seq)
    select array_agg(x order by prio, seq), array_agg(y order by prio, seq), array_agg(z order by prio, seq), array_agg(type order by prio, seq) into tx, ty, tz, tt from del;
    if tx is null then return 0; end if;
    comp := mc.dyn_components(array(select (a >> 4) from unnest(tx) a), array(select (a >> 4) from unnest(tz) a));
    for c in 1 .. (select max(v) from unnest(comp) v) loop
        select array_agg(case when p_kind = 'f' then 1 else 2 end), array_agg(tx[i]), array_agg(ty[i]), array_agg(tz[i]),
               array_agg(case when p_kind = 'f' then (case tt[i] when 'minecraft:water' then 0 when 'minecraft:flowing_water' then 1 when 'minecraft:lava' then 2 else 3 end)
                              else (select b.bid from mc.dyn_block b where b.name = tt[i]) end)
          into kinds, xs, ys, zs, auxs from generate_series(1, cardinality(tx)) i where comp[i] = c;
        total := total + mc.dyn_run(dim, p_cur, kinds, xs, ys, zs, auxs);
    end loop;
    return total;
end $$;

-- the changes the last entity phase made (falling blocks that landed) are announced by the next tick's broadcast, as vanilla's is (its broadcast precedes the entity phase)
create or replace function mc.dyn_release_late() returns void language plpgsql volatile as $$
begin
    if not exists (select 1 from mc.dyn_late_event) then return; end if;
    perform set_config('mc.dyn_busy', 'on', false);
    with moved as (delete from mc.dyn_late_event returning *)
    insert into mc.block_event (kind, dimension, x, y, z, old_state, new_state, cells) select m.kind, m.dimension, m.x, m.y, m.z, m.old_state, m.new_state, m.cells from moved m order by m.seq;
    perform set_config('mc.dyn_busy', 'off', false);
end $$;

create or replace function mc.dyn_step(p_cur bigint) returns void language plpgsql volatile as $$
declare mx int := coalesce(mc.prop_int('dbcraft.dynamics-max-ticks'), 4000);
begin
    -- idle test in ONE statement (no tick due, nothing late, nobody to random-tick for): the whole step is about this
    if not (select coalesce((select value <> 'off' from mc.server_property where key = 'dbcraft.dynamics'), true) and exists (select 1 from mc.dyn_vec)
                   and (exists (select 1 from mc.block_tick where due <= p_cur) or exists (select 1 from mc.dyn_late_event)
                        or (exists (select 1 from mc.player where conn_id is not null) and coalesce((select value::int from mc.game_rule where name = 'minecraft:random_tick_speed'), 3) > 0))) then return; end if;
    begin
        perform mc.dyn_release_late();
        if exists (select 1 from mc.block_tick where due <= p_cur) then
            perform mc.dyn_run_due(p_cur, 'b', mx);
            perform mc.dyn_run_due(p_cur, 'f', mx);
        end if;
        perform mc.dyn_random_ticks(p_cur);
        if exists (select 1 from mc.block_tick where kind = 'l' and due <= p_cur) then perform mc.dyn_run_landings(p_cur); end if;
    exception when others then
        -- a failure in the dynamics must not stop the tick of every player: the step is rolled back (its ticks stay queued) and the error recorded
        perform set_config('mc.dyn_busy', 'off', false);
        insert into mc.error_log (tick, step, message) values (p_cur, 'dyn_step', sqlerrm);
        raise warning 'dyn_step failed: %', sqlerrm;
    end;
end $$;

-- landings: the falling blocks whose fall time is over
create or replace function mc.dyn_run_landings(p_cur bigint) returns int language plpgsql volatile as $$
declare dim text := coalesce((select default_dimension from mc.world limit 1), 'minecraft:overworld'); xs int[]; ys int[]; zs int[]; auxs int[]; kinds int[]; total int := 0;
begin
    with del as (delete from mc.block_tick t where t.kind = 'l' and t.due <= p_cur and t.dimension = dim returning t.x, t.y, t.z, t.state, t.seq)
    select array_agg(5 order by seq), array_agg(x order by seq), array_agg(y order by seq), array_agg(z order by seq), array_agg((select s.sid from mc.dyn_state s where s.name = state) order by seq)
      into kinds, xs, ys, zs, auxs from del;
    if xs is null then return 0; end if;
    return mc.dyn_run(dim, p_cur, kinds, xs, ys, zs, auxs, true);
end $$;

-- schedule a tick from SQL: kind 'b' (type = the block name) or 'f' (type = 'minecraft:water' | 'minecraft:flowing_water' | 'minecraft:lava' | 'minecraft:flowing_lava'); ignored when pending
create or replace function mc.dyn_schedule(p_dim text, x int, y int, z int, p_kind "char", p_type text, p_delay int, p_prio int default 0) returns boolean language plpgsql volatile as $$
declare n int;
begin
    insert into mc.block_tick (dimension, x, y, z, kind, type, due, prio)
    values (p_dim, x, y, z, p_kind, p_type, (select game_time from mc.game_state) + p_delay, p_prio) on conflict do nothing;
    get diagnostics n = row_count;
    return n = 1;
end $$;

-- A block changed from outside (set_block, set_blocks, fill, a player): run onPlace and the neighbour updates of the changed cells in the order they were recorded.
-- Cheap filter first: only cells that are, were or touch something dynamic (a fluid, a falling block) are handed to the engine (their neighbours are peeked at with one section read each);
-- statements that change more than 64 cells are filtered by the cell's own old and new state only.  Fills (kind 'cells') hand over the cells whose new state is dynamic.
create or replace function mc.dyn_peek(p_dim text, x int, y int, z int) returns int language plpgsql stable as $$
declare s record; e int; nm text; r int;
begin
    select cs.bits, cs.data, cs.palette into s from mc.chunk_section cs where cs.dimension = p_dim and cs.cx = x >> 4 and cs.cz = z >> 4 and cs.sy = y >> 4;
    if not found then return 0; end if;
    e := mc.entry_at(s.bits, s.data, ((y & 15) << 8) | ((z & 15) << 4) | (x & 15));
    nm := case when s.bits = 0 then s.palette[1] when cardinality(s.palette) = 0 then mc.state_name(e) else s.palette[e + 1] end;
    select d.sid into r from mc.dyn_state d where d.name = nm;
    return coalesce(r, 0);
end $$;

create or replace function mc.dyn_on_events() returns trigger language plpgsql volatile as $$
declare
    v mc.dyn_vec%rowtype; e record; cur bigint; dim text; osid int; nsid int; keep boolean; k int; many boolean;
    xs int[] := '{}'; ys int[] := '{}'; zs int[] := '{}'; auxs int[] := '{}'; kinds int[] := '{}'; n int := 0; pos int[]; p int; cx0 int; sy int; cz0 int; ci int;
    dirs int[][] := array[[0,1,0],[0,-1,0],[1,0,0],[-1,0,0],[0,0,1],[0,0,-1]]; interesting int := 4 | 8 | 4096 | 65536 | 262144; dims text;
begin
    if coalesce(current_setting('mc.dyn_busy', true), 'off') = 'on' then return null; end if;
    if not mc.dyn_enabled() then return null; end if;
    select * into v from mc.dyn_vec;
    select game_time into cur from mc.game_state;
    select count(*) > 64 into many from new_ev where kind = 'block';
    select ',' || coalesce(value, '') || ',' into dims from mc.server_property where key = 'dbcraft.dynamics-dimensions';
    for e in select * from new_ev order by id loop
        continue when dims is not null and position(',' || e.dimension || ',' in dims) = 0;      -- not a dynamics dimension: blocks are stored, nothing reacts
        dim := e.dimension;
        if e.kind = 'block' then
            select d.sid into osid from mc.dyn_state d where d.name = e.old_state;
            select d.sid into nsid from mc.dyn_state d where d.name = e.new_state;
            keep := ((v.flags[osid + 1] | v.flags[nsid + 1]) & interesting) <> 0;
            if not keep and not many then
                for k in 1 .. 6 loop
                    if (v.flags[mc.dyn_peek(dim, e.x + dirs[k][1], e.y + dirs[k][2], e.z + dirs[k][3]) + 1] & interesting) <> 0 then keep := true; exit; end if;
                end loop;
            end if;
            if keep then
                n := n + 1; kinds[n] := 4; xs[n] := e.x; ys[n] := e.y; zs[n] := e.z; auxs[n] := osid;
            end if;
        elsif e.kind = 'cells' then
            select d.sid into nsid from mc.dyn_state d where d.name = e.new_state;
            if (v.flags[nsid + 1] & interesting) <> 0 then
                for p in select unnest(mc.cells_positions(e.cells)) loop
                    exit when n >= 2000;
                    n := n + 1; kinds[n] := 4; xs[n] := (e.x >> 4) * 16 + ((p >> 8) & 15); ys[n] := (e.y >> 4) * 16 + (p & 15); zs[n] := (e.z >> 4) * 16 + ((p >> 4) & 15); auxs[n] := v.k[1];
                end loop;
            end if;
        end if;
    end loop;
    if n > 0 then perform mc.dyn_run(dim, cur, kinds, xs, ys, zs, auxs); end if;
    return null;
end $$;

drop trigger if exists dyn_on_events on mc.block_event;
create trigger dyn_on_events after insert on mc.block_event referencing new table as new_ev for each statement execute function mc.dyn_on_events();
