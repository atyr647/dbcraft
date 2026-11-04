-- A shared chunk budget for a storm (async chunk generation only).  sql/430's mc.deliver_ready_chunks caps the chunks sent to ONE connection per tick
-- (dbcraft.chunk-batch-max, 64), which is fine for a few joiners but unbounded across many: 50 joiners in one tick are 3,200 chunk packets (about 25 MB) in one tick.
-- This version adds a GLOBAL cap per tick, dbcraft.chunk-budget-per-tick (0 = unlimited): the chunks that may go now are taken round-robin across the connections (every
-- connection's nearest chunk first, then every connection's second nearest, ...), so nobody starves and everybody sees their nearest chunks first.  What is not sent
-- stays in mc.chunk_wanted for the next tick.  Inline generation (the default) sends a join's chunks inside the join (net.hook_chunks), where the join budget
-- (sql/790) already limits how many joins happen per tick; the global cap applies in async mode, which is the mode for large view distances anyway.
-- Everything else is exactly sql/430's function: the same packets, in the same order per connection.

insert into mc.server_property (key, value, default_value, note) values
    ('dbcraft.chunk-budget-per-tick', '600', '600', 'dbcraft: async chunk generation: most chunk packets sent to ALL connections together per tick (round-robin, nearest first); 0 = unlimited')
on conflict (key) do nothing;

create or replace function mc.deliver_ready_chunks() returns int language plpgsql volatile as $$
declare
    r     int := mc.prop_int('view-distance') + 1;
    async boolean := mc.chunk_generation_async();
    cap   int := case when async then coalesce(mc.prop_int('dbcraft.chunk-batch-max'), 64) else 2147483647 end;
    gcap  int := case when async then nullif(coalesce(mc.prop_int('dbcraft.chunk-budget-per-tick'), 600), 0) end;      -- null: unlimited
    i_bs  int := mc.pid('chunk_batch_start');
    i_bf  int := mc.pid('chunk_batch_finished');
    n     int;
    rc int[]; rd text[]; rx int[]; rz int[]; rdist int[];       -- what is sent now: connection, dimension, chunk, distance (kept in arrays: see sql/437 on temp tables)
begin
    if not exists (select 1 from mc.chunk_wanted) then return 0; end if;
    delete from mc.chunk_wanted w
     where not exists (select 1 from net.conn c where c.conn_id = w.conn_id and c.state = 'play' and not c.closing and c.view_cx is not null
                          and abs(c.view_cx - w.cx) <= coalesce(c.view_r, r) and abs(c.view_cz - w.cz) <= coalesce(c.view_r, r));
    select array_agg(q.conn_id), array_agg(q.dimension), array_agg(q.cx), array_agg(q.cz), array_agg(q.dist) into rc, rd, rx, rz, rdist
      from (select q0.*, row_number() over (order by q0.rn, q0.conn_id) as gr         -- round-robin: every connection's nearest first, then every one's second, ...
              from (select w.conn_id, w.dimension, w.cx, w.cz, w.dist, row_number() over (partition by w.conn_id order by w.dist, w.cx, w.cz) rn
                      from mc.chunk_wanted w join mc.chunk c on c.dimension = w.dimension and c.cx = w.cx and c.cz = w.cz) q0
             where q0.rn <= cap) q
     where gcap is null or q.gr <= gcap;
    n := coalesce(cardinality(rc), 0);
    if n = 0 then return 0; end if;
    delete from mc.chunk_wanted w using unnest(rc, rd, rx, rz) as d(conn_id, dimension, cx, cz)
     where w.conn_id = d.conn_id and w.dimension = d.dimension and w.cx = d.cx and w.cz = d.cz;
    insert into mc.play_out (conn_id, data) select distinct d.conn_id, proto.frame(i_bs, '\x') from unnest(rc) as d(conn_id);
    insert into mc.play_out (conn_id, data) select d.conn_id, mc.chunk_packet(d.dimension, d.cx, d.cz) from unnest(rc, rd, rx, rz, rdist) as d(conn_id, dimension, cx, cz, dist) order by d.conn_id, d.dist, d.cx, d.cz;
    insert into mc.play_out (conn_id, data) select d.conn_id, proto.frame(i_bf, proto.varint(count(*)::int)) from unnest(rc) as d(conn_id) group by d.conn_id;
    return n;
end $$;
