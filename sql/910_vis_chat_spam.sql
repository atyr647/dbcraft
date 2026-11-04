-- Player visibility, part 11: chat and command rate limits.  ServerGamePacketListenerImpl.detectRateSpam / util.TickThrottler (26.3, javap -c): every chat message and every
-- command adds 20 to its counter (separate counters), the counter loses 1 each tick, and a player who is not an operator whose counter reaches
-- 20 x chat-spam-threshold-seconds (command-spam-threshold-seconds: server.properties, default 10, 0 = off) is disconnected with the translation key disconnect.spam.
-- At the default that is 10 messages in a burst, or a steady rate above one a second.  Messages are counted from mc.chat_log, which the chat intake (sql/360) writes for
-- every chat message and command; the tick after the last counted row is where the next one continues.

alter table mc.player add column if not exists spam_chat int not null default 0, add column if not exists spam_chat_tick bigint,
                      add column if not exists spam_cmd  int not null default 0, add column if not exists spam_cmd_tick  bigint;
alter table mc.game_state add column if not exists spam_log_id bigint;

create or replace function mc.vis_chat_spam(p_cur bigint) returns void language plpgsql as $$
declare wm bigint; mx bigint; cthr int := 20 * coalesce(mc.prop_int('chat-spam-threshold-seconds'), 10); kthr int := 20 * coalesce(mc.prop_int('command-spam-threshold-seconds'), 10);
        r record;
begin
  select spam_log_id into wm from mc.game_state;
  select max(id) into mx from mc.chat_log;
  if mx is null then return; end if;
  if wm is null then wm := coalesce((select max(id) from mc.chat_log where at < now() - interval '2 seconds'), 0); end if;      -- the first look: what was said more than two seconds ago (before this server run) does not count
  if mx = wm then return; end if;
  for r in
    with n as (select l.sender, count(*) filter (where l.kind = 'chat')::int as chats, count(*) filter (where l.kind = 'command')::int as cmds
                 from mc.chat_log l where l.id > wm and l.id <= mx and l.kind in ('chat', 'command') and l.sender is not null group by l.sender),
    calc as (
      select p.uuid, p.conn_id, n.chats, n.cmds,
             greatest(0, p.spam_chat - (p_cur - 1 - coalesce(p.spam_chat_tick, p_cur - 1))) + 20 * n.chats as c1,       -- the counters as they stood before this tick's decay, plus what arrived
             greatest(0, p.spam_cmd  - (p_cur - 1 - coalesce(p.spam_cmd_tick,  p_cur - 1))) + 20 * n.cmds  as k1
        from n join mc.player p on p.uuid = n.sender and p.conn_id is not null),
    u as (
      update mc.player p set
          spam_chat = case when calc.chats > 0 then greatest(0, calc.c1 - 1) else p.spam_chat end, spam_chat_tick = case when calc.chats > 0 then p_cur else p.spam_chat_tick end,
          spam_cmd  = case when calc.cmds  > 0 then greatest(0, calc.k1 - 1) else p.spam_cmd  end, spam_cmd_tick  = case when calc.cmds  > 0 then p_cur else p.spam_cmd_tick  end
        from calc where p.uuid = calc.uuid
      returning calc.conn_id, calc.uuid, ((calc.chats > 0 and cthr > 0 and calc.c1 >= cthr) or (calc.cmds > 0 and kthr > 0 and calc.k1 >= kthr)) as over)
    select * from u
  loop
    if r.over and not exists (select 1 from mc.op where uuid = r.uuid) then perform mc.kick(r.conn_id, 'disconnect.spam'); end if;
  end loop;
  update mc.game_state set spam_log_id = mx;
end $$;
