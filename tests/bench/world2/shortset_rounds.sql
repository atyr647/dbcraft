-- A loop-free (no loop over positions) formulation of the iteration order of fastutil's ShortOpenHashSet, as a recursive CTE per table size: the result of linear probing with insertion
-- order is the "serial dictatorship" outcome, and equals what the proposal rounds below converge to: every key proposes a slot (its home first), a slot keeps the proposer or holder that was
-- inserted first, the others move on to the next slot, until nobody is displaced.  One level is one table size (32, 64, ...): the keys of the previous table in reverse slot order, then the keys
-- inserted before the next rehash.  This file is the EVIDENCE for docs/PERF-WORLD2.md "Cold fills": it is equal to mc.shortset_order_sql on random sequences (check at the end) and slower than the
-- PL/pgSQL loop (the timings printed at the end), which is why sql/962 uses the native function when available and the loop otherwise.
--   usage: psql -X -d DB -f tests/bench/world2/shortset_rounds.sql

create schema if not exists bench_set;

-- one level: table of n slots, keys in insertion order p_keys (each distinct); returns the table as key + 1 per slot (0 = empty)
create or replace function bench_set.level(p_keys int[], p_n int) returns int[] language sql immutable as $$
  with recursive keys as (
        select k, i::int as pr, (((((k::bigint * 2654435769) & 4294967295) # ((((k::bigint * 2654435769) & 4294967295)) >> 16)) & (p_n - 1)))::int as home
          from unnest(p_keys) with ordinality t(k, i)),
  r(rnd, occ, ak, ap) as (                                   -- occ[slot + 1] = priority of the key that holds the slot (0 = none); ak / ap: priorities and slots of the keys that still look for one
        select 0, array_fill(0, array[p_n]), array(select pr from keys order by pr), array(select home from keys order by pr)
        union all
        select r.rnd + 1,
               array(select case when b.w is not null and (r.occ[s + 1] = 0 or b.w < r.occ[s + 1]) then b.w else r.occ[s + 1] end
                       from generate_series(0, p_n - 1) s left join (select p, min(i) w from unnest(r.ak, r.ap) u(i, p) group by p) b on b.p = s),
               -- the keys that go on: the proposers that did not win their slot, and the holders that were displaced; each to the next slot
               (select coalesce(array_agg(x.i order by x.i), '{}') from (
                    select u.i from unnest(r.ak, r.ap) u(i, p) join (select p, min(i) w from unnest(r.ak, r.ap) u2(i, p) group by p) b on b.p = u.p
                     where u.i <> b.w or (r.occ[u.p + 1] <> 0 and r.occ[u.p + 1] < b.w)
                    union all
                    select r.occ[b.p + 1] from (select p, min(i) w from unnest(r.ak, r.ap) u(i, p) group by p) b where r.occ[b.p + 1] <> 0 and b.w < r.occ[b.p + 1]) x),
               (select coalesce(array_agg(((x.p + 1) & (p_n - 1)) order by x.i), '{}') from (
                    select u.i, u.p from unnest(r.ak, r.ap) u(i, p) join (select p, min(i) w from unnest(r.ak, r.ap) u2(i, p) group by p) b on b.p = u.p
                     where u.i <> b.w or (r.occ[u.p + 1] <> 0 and r.occ[u.p + 1] < b.w)
                    union all
                    select r.occ[b.p + 1], b.p from (select p, min(i) w from unnest(r.ak, r.ap) u(i, p) group by p) b where r.occ[b.p + 1] <> 0 and b.w < r.occ[b.p + 1]) x)
          from r where cardinality(r.ak) > 0)
  select array(select case when o = 0 then 0 else (select k + 1 from keys where pr = o) end from unnest((select occ from r order by rnd desc limit 1)) o) $$;

create or replace function bench_set.shortset_order_rounds(p_pos int[]) returns int[] language plpgsql immutable as $$
declare d int[]; n int := 32; maxfill int := 24; lst int[] := '{}'; seg int[]; tab int[]; i int := 1; take int; res int[]; zero_seen boolean := false; sz int;
begin
    select array_agg(k order by f) into d from (select k, min(o) f from unnest(p_pos) with ordinality t(k, o) group by k) q;       -- the distinct keys in order of first insertion; key 0 is a flag of its own but counts in size
    d := coalesce(d, '{}');
    loop
        sz := cardinality(lst) + case when zero_seen then 1 else 0 end;
        take := least(maxfill + 1 - sz, cardinality(d) - i + 1);
        seg := case when take > 0 then d[i : i + take - 1] else '{}' end; i := i + take;
        tab := bench_set.level(lst || array(select x from unnest(seg) x where x <> 0), n);
        res := array(select tab[s] - 1 from generate_series(n, 1, -1) s where tab[s] <> 0);                  -- iteration order: from the last slot to the first
        zero_seen := zero_seen or 0 = any (seg);
        if sz + take = maxfill + 1 then                                                                        -- add() rehashes when the size before an insertion has reached maxFill: the old table
            lst := res; n := n * 2; maxfill := n * 3 / 4;                                                      -- is re-inserted from its last slot down into a table of twice the size
        else
            exit;
        end if;
    end loop;
    if zero_seen then res := 0 || res; end if;
    return res;
end $$;

-- equality with the PL/pgSQL simulation on random sequences, and the time of each
do $$
declare a int[]; ok int := 0; bad int := 0; t0 timestamptz; t_rounds float8 := 0; t_loop float8 := 0; r1 int[]; r2 int[]; n int; k int;
begin
    perform setseed(0.77);
    foreach n in array array[1, 5, 24, 25, 26, 48, 49, 50, 96, 97, 200, 400, 800, 1728] loop
        for k in 1 .. 3 loop
            a := array(select (random() * 4095)::int from generate_series(1, n));
            t0 := clock_timestamp(); r1 := bench_set.shortset_order_rounds(a); t_rounds := t_rounds + extract(epoch from clock_timestamp() - t0) * 1000;
            t0 := clock_timestamp(); r2 := mc.shortset_order_sql(a);           t_loop := t_loop + extract(epoch from clock_timestamp() - t0) * 1000;
            if r1 = r2 then ok := ok + 1; else bad := bad + 1; raise notice 'DIFFERENT n=% (rounds %, loop %)', n, cardinality(r1), cardinality(r2); end if;
        end loop;
    end loop;
    raise notice 'rounds formulation: % sequences equal, % different; total time % ms against % ms for the loop', ok, bad, round(t_rounds::numeric, 1), round(t_loop::numeric, 1);
    a := mc.cells_positions(mc.block_event_full_cells());
    t0 := clock_timestamp(); r1 := bench_set.shortset_order_rounds(a); t_rounds := extract(epoch from clock_timestamp() - t0) * 1000;
    t0 := clock_timestamp(); r2 := mc.shortset_order_sql(a); t_loop := extract(epoch from clock_timestamp() - t0) * 1000;
    raise notice 'a whole section (4096 positions): rounds % ms (equal: %), loop % ms', round(t_rounds::numeric, 1), r1 = r2, round(t_loop::numeric, 1);
end $$;
