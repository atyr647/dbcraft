-- Game module, part 3: server settings, operators, whitelist, bans, and the checks made at login.
-- Everything is a readable row you can UPDATE live (the tick re-reads settings each time).

create table if not exists mc.server_property (
    key           text primary key,           -- the server.properties key, e.g. max-players
    value         text not null,
    default_value text not null,
    note          text
);
-- Keys are those the real 26.3 server writes into server.properties; defaults are vanilla's documented defaults
-- (keys verified against a real server's file, default values from documentation, not re-measured).
insert into mc.server_property (key, value, default_value) values
 ('accepts-transfers','false','false'),('allow-flight','false','false'),('broadcast-console-to-ops','true','true'),('broadcast-rcon-to-ops','true','true'),
 ('bug-report-link','',''),('chat-spam-threshold-seconds','10','10'),('command-spam-threshold-seconds','10','10'),('difficulty','easy','easy'),
 ('enable-code-of-conduct','false','false'),('enable-jmx-monitoring','false','false'),('enable-query','false','false'),('enable-rcon','false','false'),
 ('enable-status','true','true'),('enforce-secure-profile','true','true'),('enforce-whitelist','false','false'),('entity-broadcast-range-percentage','100','100'),
 ('force-gamemode','false','false'),('function-permission-level','2','2'),('gamemode','survival','survival'),('generate-structures','true','true'),
 ('generator-settings','{}','{}'),('hardcore','false','false'),('hide-online-players','false','false'),('initial-disabled-packs','',''),
 ('initial-enabled-packs','vanilla','vanilla'),('level-name','world','world'),('level-seed','',''),('level-type','minecraft:normal','minecraft:normal'),
 ('log-ips','true','true'),('max-chained-neighbor-updates','1000000','1000000'),('max-players','20','20'),('max-tick-time','60000','60000'),
 ('max-world-size','29999984','29999984'),('motd','A Minecraft Server','A Minecraft Server'),('network-compression-threshold','256','256'),
 ('online-mode','true','true'),('op-permission-level','4','4'),('pause-when-empty-seconds','60','60'),('player-idle-timeout','0','0'),
 ('prevent-proxy-connections','false','false'),('rate-limit','0','0'),('require-resource-pack','false','false'),('server-ip','',''),
 ('server-port','25565','25565'),('simulation-distance','10','10'),('spawn-animals','true','true'),('spawn-monsters','true','true'),
 ('spawn-npcs','true','true'),('spawn-protection','16','16'),('sync-chunk-writes','true','true'),('use-native-transport','true','true'),
 ('view-distance','10','10'),('white-list','false','false')
on conflict (key) do nothing;

create or replace function mc.prop(k text) returns text language sql stable parallel safe as $$
  select value from mc.server_property where key = k $$;
create or replace function mc.prop_int(k text) returns int language sql stable parallel safe as $$ select value::int from mc.server_property where key = k $$;
create or replace function mc.prop_bool(k text) returns boolean language sql stable parallel safe as $$ select value::boolean from mc.server_property where key = k $$;

create table if not exists mc.op (
    uuid uuid primary key, name text not null,
    level int not null default 4 check (level between 1 and 4),
    bypasses_player_limit boolean not null default false
);
create table if not exists mc.whitelist (uuid uuid primary key, name text not null);

create table if not exists mc.ban (
    id      bigint generated always as identity primary key,
    kind    text not null check (kind in ('player', 'ip')),
    uuid    uuid,                 -- player bans
    name    text,
    ip      inet,                 -- ip bans
    reason  text not null default 'Banned by an operator.',
    source  text not null default 'Server',
    created timestamptz not null default now(),
    expires timestamptz,          -- null = forever
    check ((kind = 'player' and uuid is not null) or (kind = 'ip' and ip is not null))
);
create unique index if not exists ban_player_uq on mc.ban (uuid) where kind = 'player';
create unique index if not exists ban_ip_uq on mc.ban (ip) where kind = 'ip';

-- permission level: ops table, 0 for everyone else
create or replace function mc.permission_level(p_uuid uuid) returns int language sql stable parallel safe as $$
  select coalesce((select level from mc.op where uuid = p_uuid), 0) $$;

-- vanilla: not using a whitelist, or an op, or listed
create or replace function mc.is_whitelisted(p_uuid uuid) returns boolean language sql stable parallel safe as $$
  select not mc.prop_bool('white-list') or exists (select 1 from mc.op where uuid = p_uuid) or exists (select 1 from mc.whitelist where uuid = p_uuid) $$;

create or replace function mc.active_ban(p_uuid uuid, p_ip inet) returns mc.ban language sql stable parallel safe as $$
  select b from mc.ban b
  where (b.expires is null or b.expires > now()) and ((b.kind = 'player' and b.uuid = p_uuid) or (b.kind = 'ip' and b.ip = p_ip))
  order by (b.kind = 'player') desc limit 1 $$;

------------------------------------------------------------------------------------------------ login decision
-- Result: allowed, or the translation key and arguments of the disconnect message, in vanilla's order of checks:
-- banned profile, whitelist, banned IP, server full (an op with bypasses_player_limit gets in).  Keys read from PlayerList.canPlayerLogin in the 26.3 bytecode.
-- In the login phase the reason travels as a JSON text component (mc.disconnect_json); in play it is network NBT (mc.disconnect_nbt).
create or replace function mc.login_check(p_uuid uuid, p_name text, p_ip inet default null, out allowed boolean, out reason_key text, out reason_args text[], out expiry_args text[])
language plpgsql stable as $$
declare b mc.ban; online int;
begin
  allowed := true;
  b := mc.active_ban(p_uuid, null);
  if b.id is not null then
    allowed := false; reason_key := 'multiplayer.disconnect.banned.reason'; reason_args := array[b.reason];
    if b.expires is not null then expiry_args := array[to_char(b.expires at time zone 'UTC', 'YYYY-MM-DD "at" HH24:MI:SS "UTC"')]; end if;
    return;
  end if;
  if not mc.is_whitelisted(p_uuid) then allowed := false; reason_key := 'multiplayer.disconnect.not_whitelisted'; return; end if;
  if p_ip is not null then
    b := mc.active_ban(null, p_ip);
    if b.id is not null then
      allowed := false; reason_key := 'multiplayer.disconnect.banned_ip.reason'; reason_args := array[b.reason];
      if b.expires is not null then expiry_args := array[to_char(b.expires at time zone 'UTC', 'YYYY-MM-DD "at" HH24:MI:SS "UTC"')]; end if;
      return;
    end if;
  end if;
  select count(*) into online from mc.player where conn_id is not null;
  if online >= mc.prop_int('max-players') and not coalesce((select bypasses_player_limit from mc.op where uuid = p_uuid), false) then
    allowed := false; reason_key := 'multiplayer.disconnect.server_full';
  end if;
end $$;

-- the same message as a JSON text component (login phase) ...
create or replace function mc.disconnect_json(reason_key text, reason_args text[] default null, expiry_args text[] default null) returns text language sql immutable parallel safe as $$
  select jsonb_strip_nulls(jsonb_build_object('translate', reason_key, 'with', to_jsonb(reason_args),
      'extra', case when expiry_args is not null then jsonb_build_array(jsonb_build_object('translate', replace(reason_key, '.reason', '.expiration'), 'with', to_jsonb(expiry_args))) end))::text $$;
-- ... and as fields for network NBT (play phase): translate with args, extra: [expiry]
create or replace function mc.disconnect_nbt(reason_key text, reason_args text[] default null, expiry_args text[] default null) returns bytea language sql immutable parallel safe as $$
  select proto.cat(array[
    case when reason_args is not null then proto.nbt_list_str('with', reason_args) end,
    proto.nbt_str('translate', reason_key),
    case when expiry_args is not null then proto.nbt_list_comp('extra', array[mc.tc_translate_strs(replace(reason_key, '.reason', '.expiration'), expiry_args)]) end]) $$;
