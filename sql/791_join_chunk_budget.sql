-- A shared chunk budget for a storm.  sql/430's mc.deliver_ready_chunks caps the chunks sent to ONE connection per tick
-- (dbcraft.chunk-batch-max, 64), which is fine for a few joiners but unbounded across many: 50 joiners in one tick are 3,200 chunk packets (about 25 MB) in one tick.
-- This version adds a GLOBAL cap per tick, dbcraft.chunk-budget-per-tick (0 = unlimited): the chunks that may go now are taken round-robin across the connections (every
-- connection's nearest chunk first, then every connection's second nearest, ...), so nobody starves and everybody sees their nearest chunks first.  What is not sent
-- stays in mc.chunk_wanted for the next tick.  Inline generation (the default) sends a join's chunks inside the join (net.hook_chunks), where the join budget
-- (sql/790) already limits how many joins happen per tick.  (Since sql/920's rewrite below both caps apply in inline mode too: a join sends only dbcraft.join-chunks-inline chunks itself.)
-- Everything else is exactly sql/430's function: the same packets, in the same order per connection.

insert into mc.server_property (key, value, default_value, note) values
    ('dbcraft.chunk-budget-per-tick', '600', '600', 'dbcraft: most chunk packets sent to ALL connections together per tick (round-robin, nearest first); 0 = unlimited'),
    ('dbcraft.tick-budget-ms', '40', '40', 'dbcraft: login storms: chunk packets of waiting joiners are sent with whatever is left of this many ms in the tick (a tick that already spent it sends 25% of dbcraft.chunk-budget-per-tick, an idle one all of it); off = the cap alone'),
    ('dbcraft.join-chunks-inline', '49', '49', 'dbcraft: a joiner is sent the nearest this many chunks of its square inside the join burst; the rest follows over the next ticks (dbcraft.chunk-batch-max per tick); 0 = the whole square at once (the old behaviour)')
on conflict (key) do nothing;

-- sql/920 (docs/PERF-STORM.md) rewrote the function for a backlog of ten thousands of wanted rows (a storm of 200 joiners at view distance 10 leaves 96,000 of them) and
-- applies both caps in inline mode too (the tail of a joiner's square is sent over the following ticks, see net.hook_chunks):
--   * the work per tick is bounded by the CAPS, not by the backlog: each connection's nearest chunks come from an index (conn_id, dist, cx, cz) with LIMIT, joined to
--     the chunks that exist, instead of ranking every wanted row of every connection every tick (that was O(backlog), about 100 ms at 96,000 rows);
--   * rows of connections that are gone are found with a loose index scan over the primary key (a few hundred probes), rows outside a moved client's square are deleted when its
--     view moved (mc.chunk_wanted_view remembers the view they were last cleaned for) and are in any case never sent (the candidate query checks the square);
--   * the cached packet is read with a join to mc.chunk_cache (the fast path of mc.chunk_packet written out); the plpgsql function only runs for a stale or missing one.
-- Same frames, same order per connection, same rows left as before (tests/sql/437 compares it with the previous body).
create unlogged table if not exists mc.chunk_wanted_view (conn_id int primary key, vcx int not null, vcz int not null);
create index if not exists chunk_wanted_order on mc.chunk_wanted (conn_id, dist, cx, cz);

create or replace function mc.deliver_ready_chunks() returns int language plpgsql volatile as $$
declare
    r     int := mc.prop_int('view-distance') + 1;
    cap   int := coalesce(mc.prop_int('dbcraft.chunk-batch-max'), 64);                                   -- per connection and tick
    gcap  int := nullif(coalesce(mc.prop_int('dbcraft.chunk-budget-per-tick'), 600), 0);                 -- all connections together; null: unlimited
    i_bs  int := mc.pid('chunk_batch_start');
    i_bf  int := mc.pid('chunk_batch_finished');
    n     int; nc int; m int;
    tb    numeric := coalesce(nullif(case when lower(mc.prop('dbcraft.tick-budget-ms')) in ('off', '0', '-1', '') then null else mc.prop('dbcraft.tick-budget-ms') end, '')::numeric, 0);
    t0    timestamptz; el numeric;
    conns int[]; dead int[]; live int[];
    rc int[]; rd text[]; rx int[]; rz int[]; rdist int[];       -- what is sent now: connection, dimension, chunk, distance (kept in arrays: see sql/437 on temp tables)
begin
    if not exists (select 1 from mc.chunk_wanted) then return 0; end if;
    -- dbcraft.tick-budget-ms: the shared cap shrinks with the time this tick has already used (process_fast records its start): a tick that spent 25 ms of a 35 ms budget on a join
    -- sends 25% of the cap, a tick without joins all of it.  Without a recorded start (anything but the tick) or with an implausible one (a test running many ticks inside one statement) the cap is not scaled.
    if tb > 0 and gcap is not null then
        t0 := nullif(current_setting('dbcraft.tick_t0', true), '')::timestamptz;                -- set by net.process_fast in this transaction; not set (no scaling) anywhere else
        el := extract(epoch from clock_timestamp() - t0) * 1000;
        if el >= 0 and el < 2000 then gcap := greatest(1, ceil(gcap * greatest(0.25, least(1, (tb - el) / tb)))::int); end if;
    end if;
    -- the connections that have wanted rows (a loose index scan: the rows are many during a storm, the connections are few), and which of them still play
    select coalesce(array_agg(q.c), '{}') into conns from (
        with recursive cs(c) as (select min(conn_id) from mc.chunk_wanted union all select (select min(w.conn_id) from mc.chunk_wanted w where w.conn_id > cs.c) from cs where cs.c is not null)
        select c from cs where c is not null) q;
    select coalesce(array_agg(u.c) filter (where lv.conn_id is null), '{}'), coalesce(array_agg(u.c) filter (where lv.conn_id is not null), '{}') into dead, live
      from unnest(conns) u(c) left join net.conn lv on lv.conn_id = u.c and lv.state = 'play' and not lv.closing and lv.view_cx is not null;
    if cardinality(dead) > 0 then
        delete from mc.chunk_wanted where conn_id = any (dead);
        delete from mc.chunk_wanted_view where conn_id = any (dead);
    end if;
    nc := cardinality(live);
    if nc = 0 then return 0; end if;
    -- a client whose view moved since its rows were last cleaned: what left its square is not wanted any more
    with mv as (select c.conn_id, c.view_cx as vx, c.view_cz as vz from net.conn c left join mc.chunk_wanted_view v on v.conn_id = c.conn_id
                 where c.conn_id = any (live) and (v.conn_id is null or v.vcx <> c.view_cx or v.vcz <> c.view_cz)),
         del as (delete from mc.chunk_wanted w using mv where w.conn_id = mv.conn_id and (abs(w.cx - mv.vx) > r or abs(w.cz - mv.vz) > r) returning 1)
    insert into mc.chunk_wanted_view (conn_id, vcx, vcz) select conn_id, vx, vz from mv
    on conflict (conn_id) do update set vcx = excluded.vcx, vcz = excluded.vcz;
    -- every connection's nearest wanted chunks that exist now; round-robin across connections (rank 1 of everybody, then rank 2, ...) up to the shared cap
    m := case when gcap is null then cap else least(cap, greatest(1, ceil(gcap::numeric / nc)::int)) end;
    select array_agg(x.conn_id), array_agg(x.dimension), array_agg(x.cx), array_agg(x.cz), array_agg(x.dist) into rc, rd, rx, rz, rdist
      from (select q.*, row_number() over (order by q.rn, q.conn_id) as gr
              from (select l.*, row_number() over (partition by l.conn_id order by l.dist, l.cx, l.cz) as rn
                      from unnest(live) u(c) join net.conn n on n.conn_id = u.c
                      cross join lateral (select w.conn_id, w.dimension, w.cx, w.cz, w.dist
                                            from mc.chunk_wanted w join mc.chunk ch on ch.dimension = w.dimension and ch.cx = w.cx and ch.cz = w.cz
                                           where w.conn_id = n.conn_id and abs(n.view_cx - w.cx) <= r and abs(n.view_cz - w.cz) <= r
                                           order by w.dist, w.cx, w.cz limit m) l) q) x
     where gcap is null or x.gr <= gcap;
    n := coalesce(cardinality(rc), 0);
    if n = 0 then return 0; end if;
    delete from mc.chunk_wanted w using unnest(rc, rd, rx, rz) as d(conn_id, dimension, cx, cz)
     where w.conn_id = d.conn_id and w.dimension = d.dimension and w.cx = d.cx and w.cz = d.cz;
    insert into mc.play_out (conn_id, data) select distinct d.conn_id, proto.frame(i_bs, '\x') from unnest(rc) as d(conn_id);
    insert into mc.play_out (conn_id, data)
    select d.conn_id, coalesce(k.packet, mc.chunk_packet(d.dimension, d.cx, d.cz))
      from unnest(rc, rd, rx, rz, rdist) as d(conn_id, dimension, cx, cz, dist)
      left join mc.chunk c on c.dimension = d.dimension and c.cx = d.cx and c.cz = d.cz and not c.dirty and not c.hm_dirty and c.hm_world_surface is not null
      left join mc.chunk_cache k on k.dimension = c.dimension and k.cx = c.cx and k.cz = c.cz and k.version = c.version
     order by d.conn_id, d.dist, d.cx, d.cz;
    insert into mc.play_out (conn_id, data) select d.conn_id, proto.frame(i_bf, proto.varint(count(*)::int)) from unnest(rc) as d(conn_id) group by d.conn_id;
    return n;
end $$;
