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

drop index if exists mc.block_tick_due_only_idx;                 -- (a second index on due only cost a quarter of every tick insert; the (kind, due) index of sql/880 answers the same questions)

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

-- Run the due ticks of one kind ('b' blocks, 'f' fluids), in vanilla's order: due time, priority, the order they were scheduled (LevelTicks.DRAIN_ORDER; within one tick INTRA_TICK_DRAIN_ORDER).
-- The ticks are taken out of the queue first (vanilla polls them before running, so a tick may schedule itself again), p_max at most (vanilla's own limit of 65,536 per kind per tick: the
-- rest stays queued, in order).
-- A time budget (dbcraft.dynamics-tick-budget-ms, 0 = none) keeps one tick from taking seconds when a huge burst is due: the ticks are taken and run in slices sized by the measured cost per
-- tick (a session-level average), and when the budget is used up the rest stays queued and runs first in the next tick.  That deviates from vanilla only when a tick costs more than the budget
-- (vanilla itself would take the whole burst in one tick); the packets of a burst then arrive spread over more ticks.  The clock starts at mc.dyn_step (setting mc.dyn_t0).
-- All ticks of a slice run in ONE call of the engine in vanilla's order (so the ticks they schedule get their order numbers in vanilla's global order, and the random draws of the engine come in
-- vanilla's order) unless they are spread over a very large area (more than dbcraft.dynamics-single-run-chunks = 1,024 chunk columns): then they are split into groups of chunks that touch each
-- other, which cannot influence one another (the starting commit always split: 0 gives that back, the equivalence tests use it).
create or replace function mc.dyn_run_due(p_cur bigint, p_kind "char", p_max int) returns int language plpgsql volatile as $$
declare
    dim text := coalesce((select default_dimension from mc.world limit 1), 'minecraft:overworld');
    r int := mc.prop_int('simulation-distance');
    tx int[]; ty int[]; tz int[]; tt text[]; td bigint[]; tp int[]; tq bigint[]; comp int[]; c int; kinds int[]; xs int[]; ys int[]; zs int[]; auxs int[]; total int := 0; dl timestamptz; done int;
    budget float8 := coalesce(mc.prop_int('dbcraft.dynamics-tick-budget-ms'), 0);
    t0 timestamptz := coalesce(nullif(current_setting('mc.dyn_t0', true), '')::timestamptz, clock_timestamp());
    per float8 := coalesce(nullif(current_setting('mc.dyn_ms_per_item', true), '')::float8, 0.12);
    remaining int := p_max; take int; got int; el float8; ts timestamptz; cx0 int; cx1 int; cz0 int; cz1 int; first boolean := true;
begin
    loop
        take := remaining;
        if budget > 0 then
            el := extract(epoch from clock_timestamp() - t0) * 1000;
            exit when el >= budget and not first;                                                     -- (every tick runs at least a slice of each kind, however little time is left: nothing starves)
            take := least(remaining, greatest(32, floor((budget - el) / (per * 1.3))::int));
        end if;
        exit when take <= 0;
        ts := clock_timestamp();
        with due as materialized (
            select t.ctid as tid
              from mc.block_tick t
             where t.kind = p_kind and t.due <= p_cur and t.dimension = dim
               and exists (select 1 from mc.player p where p.conn_id is not null and abs(p.chunk_x - (t.x >> 4)) <= r and abs(p.chunk_z - (t.z >> 4)) <= r)
             order by t.due, t.prio, t.seq limit take),
             del as (delete from mc.block_tick t where t.ctid = any (array(select d.tid from due d)) returning t.x, t.y, t.z, t.type, t.due, t.prio, t.seq)
        select array_agg(x order by due, prio, seq), array_agg(y order by due, prio, seq), array_agg(z order by due, prio, seq), array_agg(type order by due, prio, seq),
               array_agg(due order by due, prio, seq), array_agg(prio order by due, prio, seq), array_agg(seq order by due, prio, seq) into tx, ty, tz, tt, td, tp, tq from del;
        exit when tx is null;
        got := cardinality(tx);
        select min(a >> 4), max(a >> 4) into cx0, cx1 from unnest(tx) a;
        select min(a >> 4), max(a >> 4) into cz0, cz1 from unnest(tz) a;
        if (cx1 - cx0 + 1)::bigint * (cz1 - cz0 + 1) <= coalesce(mc.prop_int('dbcraft.dynamics-single-run-chunks'), 1024) then
            select array_agg(case when p_kind = 'f' then 1 else 2 end), array_agg(tx[i]), array_agg(ty[i]), array_agg(tz[i]),
                   array_agg(case when p_kind = 'f' then (case tt[i] when 'minecraft:water' then 0 when 'minecraft:flowing_water' then 1 when 'minecraft:lava' then 2 else 3 end)
                                  else (select b.bid from mc.dyn_block b where b.name = tt[i]) end)
              into kinds, xs, ys, zs, auxs from generate_series(1, got) i;
            dl := case when budget > 0 then greatest(t0 + (budget * 1.25) * interval '1 millisecond', clock_timestamp() + interval '3 milliseconds') end;      -- (the slice is sized to fit the budget; a clear overshoot stops it)
            total := total + mc.dyn_run(dim, p_cur, kinds, xs, ys, zs, auxs, false, '{}', 0, dl);
            done := coalesce(nullif(current_setting('mc.dyn_done', true), '')::int, got);
            if done < got then
                -- the ticks that did not run go back into the queue as they were (an equal tick scheduled meanwhile is the one that was not pending in vanilla: the original wins)
                insert into mc.block_tick (dimension, x, y, z, kind, type, due, prio, seq)
                select dim, tx[i], ty[i], tz[i], p_kind, tt[i], td[i], tp[i], tq[i] from generate_series(done + 1, got) i
                on conflict (dimension, x, y, z, kind, type) do update set due = excluded.due, prio = excluded.prio, seq = excluded.seq;
                got := done;
            end if;
        else
            comp := mc.dyn_components(array(select (a >> 4) from unnest(tx) a), array(select (a >> 4) from unnest(tz) a));
            for c in 1 .. (select max(v) from unnest(comp) v) loop
                select array_agg(case when p_kind = 'f' then 1 else 2 end), array_agg(tx[i]), array_agg(ty[i]), array_agg(tz[i]),
                       array_agg(case when p_kind = 'f' then (case tt[i] when 'minecraft:water' then 0 when 'minecraft:flowing_water' then 1 when 'minecraft:lava' then 2 else 3 end)
                                      else (select b.bid from mc.dyn_block b where b.name = tt[i]) end)
                  into kinds, xs, ys, zs, auxs from generate_series(1, got) i where comp[i] = c;
                total := total + mc.dyn_run(dim, p_cur, kinds, xs, ys, zs, auxs);
            end loop;
        end if;
        remaining := remaining - got;
        first := false;
        if budget > 0 then
            -- the cost of one tick of this kind, smoothed (the next slice and the next tick are sized by it)
            if got > 0 then
                per := greatest(0.002, 0.6 * per + 0.4 * (extract(epoch from clock_timestamp() - ts) * 1000 / got));
                perform set_config('mc.dyn_ms_per_item', per::text, false);
            end if;
        end if;
        exit when got < take;
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

-- The reactions of fills that did not fit in a tick's budget (mc.dyn_work, queued by mc.dyn_on_events): run in the order they were queued, the oldest fill first, each slice as long as the
-- budget allows; the part of a fill that is left stays queued.  The engine gets the whole remainder of the fill (it puts the cells of the placements back for all of it) and a deadline.
create or replace function mc.dyn_run_work(p_cur bigint) returns int language plpgsql volatile as $$
declare
    budget float8 := coalesce(mc.prop_int('dbcraft.dynamics-tick-budget-ms'), 0);
    t0 timestamptz := coalesce(nullif(current_setting('mc.dyn_t0', true), '')::timestamptz, clock_timestamp());
    dl timestamptz; gt bigint; dim text; ids bigint[]; kinds int[]; xs int[]; ys int[]; zs int[]; auxs int[]; aux2s int[]; n int; done int; total int := 0;
begin
    loop
        select w.t, w.dimension into gt, dim from mc.dyn_work w order by w.id limit 1;
        exit when gt is null;
        select array_agg(q.id order by q.id), array_agg(q.kind order by q.id), array_agg(q.x order by q.id), array_agg(q.y order by q.id), array_agg(q.z order by q.id), array_agg(q.aux order by q.id), array_agg(q.aux2 order by q.id)
          into ids, kinds, xs, ys, zs, auxs, aux2s from mc.dyn_work q where q.t = gt and q.dimension = dim;
        n := cardinality(ids);
        dl := case when budget > 0 then t0 + budget * interval '1 millisecond' end;
        total := total + mc.dyn_run(dim, gt, kinds, xs, ys, zs, auxs, false, aux2s, 0, dl);
        done := coalesce(nullif(current_setting('mc.dyn_done', true), '')::int, n);
        delete from mc.dyn_work w where w.id = any (ids[1 : done]);
        exit when done < n or (budget > 0 and clock_timestamp() >= t0 + budget * interval '1 millisecond');
    end loop;
    return total;
end $$;

create or replace function mc.dyn_step(p_cur bigint) returns void language plpgsql volatile as $$
declare mx int := coalesce(mc.prop_int('dbcraft.dynamics-max-ticks'), 65536);
begin
    -- idle test in ONE statement (no tick due, nothing late, no random-tick run this tick, no list to rebuild): the whole step is about this
    if not (select coalesce((select value <> 'off' from mc.server_property where key = 'dbcraft.dynamics'), true) and exists (select 1 from mc.dyn_vec)
                   and (exists (select 1 from mc.block_tick where kind in ('b', 'f', 'l') and due <= p_cur) or exists (select 1 from mc.dyn_late_event) or exists (select 1 from mc.dyn_work) or exists (select 1 from mc.dyn_rt_dirty d where d.mt <= p_cur - coalesce((select value::int from mc.server_property where key = 'dbcraft.random-tick-quiet'), 100))
                        or (p_cur % greatest(coalesce((select value::int from mc.server_property where key = 'dbcraft.random-tick-interval'), 4), 1) = 0
                            and exists (select 1 from mc.player where conn_id is not null) and coalesce((select value::int from mc.game_rule where name = 'minecraft:random_tick_speed'), 3) > 0))) then return; end if;
    begin
        perform set_config('mc.dyn_t0', clock_timestamp()::text, true);
        perform mc.dyn_release_late();
        if exists (select 1 from mc.dyn_work) then perform mc.dyn_run_work(p_cur); end if;
        if exists (select 1 from mc.block_tick where kind in ('b', 'f', 'l') and due <= p_cur) then
            perform mc.dyn_run_due(p_cur, 'b', mx);
            perform mc.dyn_run_due(p_cur, 'f', mx);
        end if;
        perform mc.dyn_rt_maintain(p_cur);
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
    xs int[] := '{}'; ys int[] := '{}'; zs int[] := '{}'; auxs int[] := '{}'; aux2s int[] := '{}'; kinds int[] := '{}'; n int := 0; pos int[]; p int; cx0 int; sy int; cz0 int; ci int;
    dirs int[][] := array[[0,1,0],[0,-1,0],[1,0,0],[-1,0,0],[0,0,1],[0,0,-1]]; interesting int := 4 | 8 | 4096 | 65536 | 262144 | 8388608 | 16777216 | 33554432; dims text; any_react boolean; any_tick boolean; budget float8; done int; wats boolean[];
begin
    if not mc.dyn_enabled() then return null; end if;
    -- Is there anything here that can react, or whose random-tick list can change?  Asked of the PALETTES of the sections the events are in (and of the face neighbours: a block event only when
    -- it is on that face, a fill or section replacement always) and of the old and new states of the events, by name: no block of a reactive or random-ticking kind anywhere near means the
    -- whole statement is skipped, without reading the 200 KB arrays of the engine.  An empty palette (more than 256 states: the global palette) counts as reactive.
    select coalesce(bool_or(q.react), false), coalesce(bool_or(q.tickc), false) into any_react, any_tick from (
        select d.react, d.tickc
          from (select distinct ne.dimension, ne.x >> 4 as cx, ne.y >> 4 as sy, ne.z >> 4 as cz, ne.kind <> 'block' as whole,
                       case when (ne.x & 15) = 0 then -1 when (ne.x & 15) = 15 then 1 else 0 end as bx, case when (ne.y & 15) = 0 then -1 when (ne.y & 15) = 15 then 1 else 0 end as by_,
                       case when (ne.z & 15) = 0 then -1 when (ne.z & 15) = 15 then 1 else 0 end as bz from new_ev ne) s
          cross join lateral (values (0, 0, 0), (-1, 0, 0), (1, 0, 0), (0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1)) o(dx, dy, dz)
          join mc.chunk_section cs on cs.dimension = s.dimension and cs.cx = s.cx + o.dx and cs.sy = s.sy + o.dy and cs.cz = s.cz + o.dz
          cross join lateral (select unnest(case when cardinality(cs.palette) = 0 then array['minecraft:water[level=0]', 'minecraft:grass_block[snowy=false]'] else cs.palette end) as pn) pl
          join mc.dyn_state d on d.name = pl.pn
         where (o.dx = 0 and o.dy = 0 and o.dz = 0) or s.whole or (o.dx = s.bx and o.dx <> 0) or (o.dy = s.by_ and o.dy <> 0) or (o.dz = s.bz and o.dz <> 0)
        union all
        select d.react, d.tickc from (select distinct x.nm from new_ev ne, lateral (values (ne.old_state), (ne.new_state)) x(nm)) st join mc.dyn_state d on d.name = st.nm
    ) q;
    if not any_react and not any_tick then return null; end if;
    if any_tick and (select count(*) from new_ev) <= 24 and not exists (select 1 from new_ev where kind <> 'block') then
        -- a few single-block edits: patch the lists of the cells around them now (no rebuild of the chunk 100 ticks later) when the chunks have lists
        select array_agg(ne.x order by ne.id), array_agg(ne.y order by ne.id), array_agg(ne.z order by ne.id), min(ne.dimension),
               array_agg(exists (select 1 from mc.dyn_state s where s.name in (ne.old_state, ne.new_state) and s.fluid <> '') order by ne.id) into xs, ys, zs, dims, wats from new_ev ne;
        begin
            if mc.dyn_rt_patch(dims, xs, ys, zs, wats) then any_tick := false; end if;
        exception when others then
            insert into mc.error_log (tick, step, message) values ((select game_time from mc.game_state), 'dyn_rt_patch', sqlerrm);          -- (the chunks are queued for a rebuild below)
        end;
        xs := '{}'; ys := '{}'; zs := '{}'; dims := null;
    end if;
    if any_tick then
        -- the random-tick lists (sql/887) of the chunks a change touches, and of the neighbours when it is within 4 cells of them (water reaches farmland, dirt grass, over a chunk border)
        insert into mc.dyn_rt_dirty (dimension, cx, cz, mt)
        select distinct q.dimension, q.cx + dx.v, q.cz + dz.v, (select game_time from mc.game_state)
          from (select distinct ne.dimension, ne.x >> 4 as cx, ne.z >> 4 as cz, ne.kind <> 'block' as whole,
                       case when (ne.x & 15) < 4 then -1 when (ne.x & 15) >= 12 then 1 else 0 end as bx,
                       case when (ne.z & 15) < 4 then -1 when (ne.z & 15) >= 12 then 1 else 0 end as bz
                  from new_ev ne) q, (values (0), (-1), (1)) dx(v), (values (0), (-1), (1)) dz(v)
         where (dx.v = 0 or q.whole or dx.v = q.bx) and (dz.v = 0 or q.whole or dz.v = q.bz)
        on conflict (dimension, cx, cz) do update set seq = excluded.seq, mt = excluded.mt;
    end if;
    if not any_react or coalesce(current_setting('mc.dyn_busy', true), 'off') = 'on' then return null; end if;
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
                n := n + 1; kinds[n] := 4; xs[n] := e.x; ys[n] := e.y; zs[n] := e.z; auxs[n] := osid; aux2s[n] := 0;
            end if;
        elsif e.kind = 'cells' then
            select d.sid into nsid from mc.dyn_state d where d.name = e.new_state;
            select d.sid into osid from mc.dyn_state d where d.name = e.old_state;
            if (v.flags[nsid + 1] & interesting) <> 0 then
                for p in select unnest(mc.cells_positions(e.cells)) loop
                    exit when n >= 2000;
                    n := n + 1; kinds[n] := 9; xs[n] := (e.x >> 4) * 16 + ((p >> 8) & 15); ys[n] := (e.y >> 4) * 16 + (p & 15); zs[n] := (e.z >> 4) * 16 + ((p >> 4) & 15); auxs[n] := coalesce(osid, v.k[1]); aux2s[n] := nsid;
                end loop;
            end if;
        end if;
    end loop;
    -- a fill: every block is placed first (kind 9), then the neighbours of every one of them are told, in the same order (kind 10)
    k := n;
    for p in 1 .. k loop
        if kinds[p] = 9 then n := n + 1; kinds[n] := 10; xs[n] := xs[p]; ys[n] := ys[p]; zs[n] := zs[p]; auxs[n] := auxs[p]; aux2s[n] := 0; end if;
    end loop;
    if n > 0 then
        perform set_config('mc.dyn_nocache', 'on', true);
        budget := coalesce(mc.prop_int('dbcraft.dynamics-tick-budget-ms'), 0);
        perform mc.dyn_run(dim, cur, kinds, xs, ys, zs, auxs, false, aux2s, 0, case when budget > 0 then clock_timestamp() + budget * interval '1 millisecond' end);
        perform set_config('mc.dyn_nocache', 'off', true);
        -- a fill whose reactions do not fit in the budget: the rest is queued (run by mc.dyn_run_work in the following ticks, with this game time)
        done := coalesce(nullif(current_setting('mc.dyn_done', true), '')::int, n);
        if done < n then
            insert into mc.dyn_work (dimension, t, kind, x, y, z, aux, aux2)
            select dim, cur, kinds[i], xs[i], ys[i], zs[i], auxs[i], aux2s[i] from generate_series(done + 1, n) i order by i;
        end if;
    end if;
    return null;
end $$;

drop trigger if exists dyn_on_events on mc.block_event;
create trigger dyn_on_events after insert on mc.block_event referencing new table as new_ev for each statement execute function mc.dyn_on_events();
