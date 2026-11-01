-- Batched pipeline, part 2: fused ingest (flag `in`) and bulk visibility (flag `vis`).  See sql/380_batch_pipeline.sql.

------------------------------------------------------------------------------------------------ in: inbox -> play_in_work in one statement
-- Baseline: net.process() copies net.inbox into net.batch, deletes the forwardable play packets from it into net.play_inbox, mc.server_tick copies those into mc.play_in,
-- and mc.tick copies them again into mc.play_in_work.  Here one statement claims the inbox and routes every frame:
--   * a play packet of a connection in play state whose id exists and which the connection layer does not handle itself  -> mc.play_in_work (keeping the arrival
--     sequence, so handlers that order by seq see the same order)
--   * everything else (handshake, status, login, configuration, protocol-level play packets, unknown ids, unknown connections) -> net.batch for the per-connection loop
-- After the loop, keep-alive answers and teleport confirmations of connections still in play state are forwarded to the game (as the baseline's step 2 does).
-- Returns the number of frames consumed.
create or replace function mc.ingest_batched() returns int language plpgsql as $$
declare n int; r record;
        handled int[] := net.handled_play_ids();
        valid   int[] := (select coalesce(array_agg(protocol_id), '{}') from ref.packet where state = 'play' and direction = 'serverbound');
begin
    if exists (select 1 from net.batch) then delete from net.batch; end if;           -- leftovers of a failed tick (the baseline truncates here)
    with inb as (delete from net.inbox returning conn_id, seq, payload),
         c as materialized (select i.conn_id, i.seq, i.payload, net.pid(i.payload) as pid, n.state as st, coalesce(n.closing, true) as closing
                              from inb i left join net.conn n on n.conn_id = i.conn_id),
         touch as (update net.conn n set last_activity = now() from (select distinct conn_id from inb) t where n.conn_id = t.conn_id returning 1),
         fwd as (insert into mc.play_in_work (seq, conn_id, packet_id, body)
                 select seq, conn_id::int, pid, substring(payload from net.pid_len(payload) + 1)
                   from c where st = 'play' and not closing and pid = any (valid) and not (pid = any (handled)) returning 1),
         cold as (insert into net.batch (conn_id, seq, payload)
                  select conn_id, seq, payload from c
                   where not (st = 'play' and not closing and pid = any (valid) and not (pid = any (handled))) returning 1)
    select count(*)::int into n from inb;
    if n = 0 then return 0; end if;
    -- the rare ones, in order, one connection failure at a time (exactly net.process's loop)
    if exists (select 1 from net.batch) then
        for r in select conn_id, payload from net.batch order by conn_id, seq loop
            begin
                perform net.handle(r.conn_id, r.payload);
            exception when others then
                perform net.fail(r.conn_id, sqlerrm);
            end;
        end loop;
        insert into mc.play_in_work (seq, conn_id, packet_id, body)
        select b.seq, b.conn_id::int, net.pid(b.payload), substring(b.payload from net.pid_len(b.payload) + 1)
          from net.batch b join net.conn c on c.conn_id = b.conn_id and c.state = 'play' and not c.closing
         where net.pid(b.payload) = any (array[mc.sid('keep_alive'), mc.sid('accept_teleportation')]);
        delete from net.batch;
    end if;
    return n;
end $$;

------------------------------------------------------------------------------------------------ vis: the visibility refresh as one statement
-- Same visibility rule and the same packets as mc.refresh_visibility() (a pair is visible when the chunk coordinates differ by at most min(view-distance, 32); only
-- pairs involving a player who changed chunk are recomputed), but with no temp tables, no ANALYZE and no TRUNCATE: a CTE chain, and ONE insert into mc.play_out so
-- that a connection that is both told about new entities and about removed ones gets them in the baseline's order (add_entity first).
-- The dirty players are collected in an array first, and every access to mc.visible is driven from it through the primary key (viewer_eid, target_eid) and the
-- target_eid index, so the cost grows with the number of players that changed chunk, not with the size of mc.visible (an OR of two IN-subqueries made the planner
-- scan the whole table: measured 20 ms worse than the baseline at 500 crowded players, 79k pairs).
create or replace function mc.visibility_batched() returns table(added int, removed int) language plpgsql as $$
declare r int := least(mc.prop_int('view-distance'), 32); d int[] := array(select entity_id from mc.player where vis_dirty and conn_id is not null);
begin
    if cardinality(d) = 0 then
        update mc.player set vis_dirty = false where vis_dirty;                  -- offline players flagged dirty: nothing to compute, just clear the flag (as the baseline does)
        added := 0; removed := 0; return next; return;
    end if;
    with on_ as materialized (select entity_id as eid, conn_id as conn, chunk_x as cx, chunk_z as cz from mc.player where conn_id is not null),
    dd as materialized (select eid, conn, cx, cz from on_ where eid = any (d)),
    want as materialized (
        select a.eid as viewer_eid, b.eid as target_eid, a.conn as viewer_conn from dd a join on_ b on b.eid <> a.eid and abs(a.cx - b.cx) <= r and abs(a.cz - b.cz) <= r
        union
        select a.eid, b.eid, a.conn from dd b join on_ a on a.eid <> b.eid and abs(a.cx - b.cx) <= r and abs(a.cz - b.cz) <= r),
    ins as (
        insert into mc.visible (viewer_eid, target_eid, viewer_conn)
        select w.viewer_eid, w.target_eid, w.viewer_conn from want w
         where (select true from mc.visible v where v.viewer_eid = w.viewer_eid and v.target_eid = w.target_eid) is null     -- per-row primary-key probe, not a scan
        returning viewer_eid, target_eid, viewer_conn),
    cand as materialized (
        select v.viewer_eid, v.target_eid from mc.visible v where v.viewer_eid = any (d)
        union
        select v.viewer_eid, v.target_eid from mc.visible v where v.target_eid = any (d)),
    del as (
        delete from mc.visible v using cand c
         where v.viewer_eid = c.viewer_eid and v.target_eid = c.target_eid
           and not exists (select 1 from want w where w.viewer_eid = v.viewer_eid and w.target_eid = v.target_eid)
        returning v.viewer_conn, v.target_eid),
    -- the add_entity packet depends on the target only: built once per target, then fanned out to every new viewer of it
    tp as materialized (select t.entity_id as eid, mc.pkt_add_player_entity(t.entity_id, t.uuid, t.sent_qx / 4096.0, t.sent_qy / 4096.0, t.sent_qz / 4096.0, t.sent_yaw, t.sent_pitch, t.sent_yaw) as pkt
                          from mc.player t where t.entity_id in (select target_eid from ins)),
    addp as (select i.viewer_conn, string_agg(tp.pkt, '\x'::bytea order by i.target_eid) as data from ins i join tp on tp.eid = i.target_eid group by i.viewer_conn),
    remp as (select viewer_conn, mc.pkt_remove_entities(array_agg(target_eid)) as data from del group by viewer_conn),
    clr as (update mc.player set vis_dirty = false where vis_dirty returning 1),
    q as (insert into mc.play_out (conn_id, data) select conn_id, data from (select viewer_conn as conn_id, 1 as ph, data from addp union all select viewer_conn, 2, data from remp) u order by ph returning 1)
    select (select count(*) from ins)::int, (select count(*) from del)::int into added, removed;
    return next;
end $$;
