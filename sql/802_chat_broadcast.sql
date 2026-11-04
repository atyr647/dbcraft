-- Idle cost, part 3: the cost of one chat message.  See docs/PERF-IDLE.md.
--
-- mc.apply_chat built the player_chat packet of EVERY recipient from scratch (about 15 function calls per recipient: the global index is the only field that differs between
-- recipients) inside one statement that PL/pgSQL planned again for every message (3.2 ms of planning per message whatever the number of players: the statement has the message as
-- parameters, so the cached plan was never used).  mc.chat_broadcast builds everything after the global index once, per recipient only varint(global index) || tail is framed, and
-- the function runs with plan_cache_mode = force_generic_plan so the statement is planned once per session.  Same bytes (tests/sql/802 compares it with mc.pkt_player_chat for
-- global indices of 1, 2 and 3 bytes), same order of rows in mc.play_out (by entity id), same counters.
--   5.4 -> about 1 ms of the chat message's statement at 200 players, 3.2 ms of planning -> 0.
-- The function is called by mc.apply_chat (sql/360, edited in place); nothing else calls it.

create or replace function mc.chat_broadcast(p_uuid uuid, p_name text, p_idx int, p_text text, p_ts bigint, p_salt bigint, p_ctype int) returns void
language plpgsql volatile set plan_cache_mode = force_generic_plan as $$
declare tail bytea;
begin
  -- everything of the player_chat body that follows the global index (mc.pkt_player_chat, sql/310, in the same order)
  tail := proto.uuid(p_uuid) || proto.varint(p_idx) || proto.bool(false) || proto.string(p_text) || proto.i64(p_ts) || proto.i64(p_salt) || proto.varint(0)
       || proto.bool(false) || proto.varint(0) || proto.varint(p_ctype + 1) || proto.nbt_root(mc.tc_player(p_uuid, p_name)) || proto.bool(false);
  with up as (update mc.player set chat_recv = chat_recv + 1 where conn_id is not null returning conn_id, entity_id, chat_recv - 1 as gidx)
  insert into mc.play_out (conn_id, data)
    select conn_id, proto.frame(mc.pid('player_chat'), proto.varint(gidx) || tail) from up order by entity_id;
end $$;
