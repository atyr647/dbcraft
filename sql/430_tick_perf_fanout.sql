-- Fan-out of this tick's movement packets to the viewers, for crowded worlds.
--
-- The row-wise way (what mc.apply_player_moves did until now) joins every mover's packet to its viewers through mc.visible and concatenates per viewer:
-- movers x viewers rows.  In a crowd (everybody within view distance of everybody) that is N^2/2 rows per tick: 125,000 rows for 500 walking players, about
-- 140-200 ms of executor work (a sort of 125,000 rows, a nested loop with 250 index scans, a sorted aggregate).
--
-- Who sees whom is a pure function of the chunk coordinates (sql/465 mc.refresh_visibility: |chunk_x - chunk_x'| <= r and |chunk_z - chunk_z'| <= r, r = view-distance
-- capped at 32, both players online): viewers that stand in the same chunk see exactly the same movers (except themselves).  So the packets are concatenated ONCE PER
-- OCCUPIED CHUNK ("viewer cell"), in entity id order, and each viewer gets its cell's blob minus its own packet (cut out with the offset of that packet in the blob):
-- the bytes of every viewer's row are identical to the row-wise result.  500 walking players in 9 chunks: 9 blobs instead of 125,000 rows.
--
-- Exactness: mc.visible is the cache of that rule as of the last refresh, i.e. of the chunk coordinates BEFORE this tick's moves; the caller passes those old
-- coordinates (a pre-update snapshot) and says whether any player still had a pending visibility change (vis_dirty: joined or teleported this tick, its pairs are not
-- in mc.visible yet or are stale): then the row-wise path runs, exactly as before.  The row-wise path also runs when viewers hardly share cells (the cell path would
-- cost cells x movers range tests and gain nothing): dbcraft.fanout-min-share (default 3) = viewers per occupied chunk needed for the cell path.
-- tests/sql/467_crowd_fanout.sql compares both paths byte for byte on random states.
create or replace function mc.fanout_moves(f_eid int[], f_data bytea[], f_ocx int[], f_ocz int[], v_conn int[], v_eid int[], v_cx int[], v_cz int[], any_dirty boolean, p_mode text default 'auto')
returns int language plpgsql volatile as $$
declare m int := coalesce(cardinality(f_eid), 0); np int := coalesce(cardinality(v_eid), 0); r int := least(mc.prop_int('view-distance'), 32); cells int; share int; use_cells boolean;
begin
  if m = 0 or np = 0 then return 0; end if;
  if p_mode = 'rows' or any_dirty then
    use_cells := false;
  elsif p_mode = 'cells' then
    use_cells := true;
  else
    select count(*) into cells from (select distinct cx, cz from unnest(v_cx, v_cz) as t(cx, cz)) q;
    share := coalesce((select value::int from mc.server_property where key = 'dbcraft.fanout-min-share'), 3);
    use_cells := np >= share * cells;
  end if;

  if not use_cells then
    insert into mc.play_out (conn_id, data)
    select v.viewer_conn, string_agg(pk.data, '\x'::bytea order by pk.eid)
      from mc.visible v join unnest(f_eid, f_data) as pk(eid, data) on pk.eid = v.target_eid
     group by v.viewer_conn;
    return 0;
  end if;

  with pk as materialized (select * from unnest(f_eid, f_data, f_ocx, f_ocz) as t(eid, data, ocx, ocz)),
  vc as materialized (select distinct cx, cz from unnest(v_cx, v_cz) as t(cx, cz)),
  pre as materialized (                       -- per (viewer cell, mover in range): its packet and the offset of the packet inside the cell's blob
    select vc.cx, vc.cz, pk.eid, pk.data,
           coalesce(sum(octet_length(pk.data)) over (partition by vc.cx, vc.cz order by pk.eid rows between unbounded preceding and 1 preceding), 0)::int as off
      from vc join pk on abs(vc.cx - pk.ocx) <= r and abs(vc.cz - pk.ocz) <= r),
  cb as materialized (select cx, cz, string_agg(data, '\x'::bytea order by eid) as blob from pre group by cx, cz)
  insert into mc.play_out (conn_id, data)
  select v.conn,
         case when p.eid is null then cb.blob
              else substring(cb.blob from 1 for p.off) || substring(cb.blob from p.off + octet_length(p.data) + 1) end
    from unnest(v_conn, v_eid, v_cx, v_cz) as v(conn, eid, cx, cz)
    join cb on cb.cx = v.cx and cb.cz = v.cz
    left join pre p on p.cx = v.cx and p.cz = v.cz and p.eid = v.eid
   where octet_length(cb.blob) > (case when p.eid is null then 0 else octet_length(p.data) end)       -- a viewer that would only receive its own packet gets no row
   order by v.conn;
  return 1;
end $$;
