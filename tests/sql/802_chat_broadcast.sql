-- sql/802: mc.chat_broadcast (the player_chat packet of every recipient built from one tail) against the statement mc.apply_chat used before, kept here as the oracle:
-- the same frames, in the same order, for global indices of 1, 2 and 3 bytes, texts with multi-byte characters, and the same counters afterwards.
create or replace function t.chat_old(p_uuid uuid, p_name text, p_idx int, p_text text, p_ts bigint, p_salt bigint, p_ctype int) returns void language plpgsql as $$
begin
  with up as (update mc.player set chat_recv = chat_recv + 1 where conn_id is not null returning conn_id, entity_id, chat_recv - 1 as gidx)
  insert into mc.play_out (conn_id, data)
    select conn_id, mc.pkt_player_chat(gidx, p_uuid, p_idx, p_text, p_ts, p_salt, p_ctype, mc.tc_player(p_uuid, p_name)) from up order by entity_id;
end $$;
create or replace function t.cb_build(p_base int) returns void language plpgsql as $$
begin
  truncate mc.play_out;
  delete from mc.player;
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode, chat_recv)
  select md5(g::text)::uuid, 'who' || g, g, 100 - g, 0, 70, 0, 0, 0, 1, p_base + g * 40 from generate_series(1, 6) g;     -- entity ids descending: the order of the rows is by entity id, not by connection
end $$;
create or replace function t.cb_digest() returns text language sql as $$
  select (select string_agg(conn_id || ':' || encode(data, 'hex'), '|' order by seq) from mc.play_out) || '#' || (select string_agg(conn_id || '=' || chat_recv, ',' order by conn_id) from mc.player) $$;
create or replace function t.cb_compare(p_base int, p_text text, p_idx int) returns text language plpgsql as $$
declare a text; b text; u uuid := md5('sender')::uuid;
begin
  perform t.cb_build(p_base);
  perform t.chat_old(u, 'Sender', p_idx, p_text, 1700000000123, -5, 1);
  a := t.cb_digest();
  perform t.cb_build(p_base);
  perform mc.chat_broadcast(u, 'Sender', p_idx, p_text, 1700000000123, -5, 1);
  b := t.cb_digest();
  if a is null then return 'oracle produced nothing'; end if;
  return case when a = b then 'same' else 'differs' end;
end $$;
select t.eq('chat_broadcast: global indices around ' || base || ', index ' || idx || ', "' || txt || '"', t.cb_compare(base, txt, idx), 'same')
  from unnest(array[0, 100, 16300, 2097000]) base, unnest(array[0, 5, 300]) idx, unnest(array['hello', 'ünïcödé ✓ 日本語', repeat('x', 256)]) txt;
select t.is_true('the counters moved by exactly one per recipient', (select count(*) from mc.player where chat_recv > 0) = 6);
select t.is_true('chat_broadcast uses a generic plan (the setting travels with the function)', (select 'plan_cache_mode=force_generic_plan' = any (proconfig) from pg_proc where oid = 'mc.chat_broadcast(uuid,text,int,text,bigint,bigint,int)'::regprocedure));
