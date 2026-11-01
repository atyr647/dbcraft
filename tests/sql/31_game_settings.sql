-- settings, permissions, bans, login decision
select t.eq('default max-players', mc.prop_int('max-players'), 20);
select t.eq('default white-list off', mc.prop_bool('white-list'), false);
select t.eq('default motd', mc.prop('motd'), 'A Minecraft Server');

insert into mc.player (uuid, name) values ('00000000-0000-0000-0000-00000000aaa1', 'Alice') on conflict do nothing;
select t.is_true('open server allows login', (select allowed from mc.login_check('00000000-0000-0000-0000-00000000aaa1', 'Alice')));

-- whitelist
update mc.server_property set value = 'true' where key = 'white-list';
select t.eq('whitelist on: stranger refused with the vanilla key', (select reason_key from mc.login_check('00000000-0000-0000-0000-00000000bbb1', 'Stranger')), 'multiplayer.disconnect.not_whitelisted');
insert into mc.whitelist values ('00000000-0000-0000-0000-00000000bbb1', 'Stranger');
select t.is_true('whitelisted player allowed', (select allowed from mc.login_check('00000000-0000-0000-0000-00000000bbb1', 'Stranger')));
insert into mc.op values ('00000000-0000-0000-0000-00000000ccc1', 'Boss', 4, false);
select t.is_true('ops bypass the whitelist', (select allowed from mc.login_check('00000000-0000-0000-0000-00000000ccc1', 'Boss')));
update mc.server_property set value = 'false' where key = 'white-list';

-- bans
insert into mc.ban (kind, uuid, name, reason) values ('player', '00000000-0000-0000-0000-00000000ddd1', 'Griefer', 'No griefing');
select t.eq('banned player: key', (select reason_key from mc.login_check('00000000-0000-0000-0000-00000000ddd1', 'Griefer')), 'multiplayer.disconnect.banned.reason');
select t.eq('banned player: reason argument', (select reason_args from mc.login_check('00000000-0000-0000-0000-00000000ddd1', 'Griefer')), array['No griefing']);
select t.is_true('permanent ban has no expiry text', (select expiry_args is null from mc.login_check('00000000-0000-0000-0000-00000000ddd1', 'Griefer')));
insert into mc.ban (kind, uuid, name, reason, expires) values ('player', '00000000-0000-0000-0000-00000000eee1', 'Temp', 'cool off', '2099-01-02 03:04:05+00');
select t.eq('temporary ban: expiry formatted in UTC', (select expiry_args from mc.login_check('00000000-0000-0000-0000-00000000eee1', 'Temp')), array['2099-01-02 at 03:04:05 UTC']);
insert into mc.ban (kind, uuid, name, reason, expires) values ('player', '00000000-0000-0000-0000-00000000fff1', 'Old', 'expired', now() - interval '1 day');
select t.is_true('expired ban is ignored', (select allowed from mc.login_check('00000000-0000-0000-0000-00000000fff1', 'Old')));
insert into mc.ban (kind, ip, reason) values ('ip', '203.0.113.7', 'bad network');
select t.eq('ip ban', (select reason_key from mc.login_check('00000000-0000-0000-0000-00000000ab01', 'Anyone', '203.0.113.7')), 'multiplayer.disconnect.banned_ip.reason');
select t.is_true('other ip fine', (select allowed from mc.login_check('00000000-0000-0000-0000-00000000ab01', 'Anyone', '203.0.113.8')));

-- the message forms
select t.eq('login phase JSON (not whitelisted)', mc.disconnect_json('multiplayer.disconnect.not_whitelisted')::jsonb, '{"translate":"multiplayer.disconnect.not_whitelisted"}'::jsonb);
select t.eq('login phase JSON (ban with expiry)', mc.disconnect_json('multiplayer.disconnect.banned.reason', array['x'], array['d'])::jsonb,
            '{"translate":"multiplayer.disconnect.banned.reason","with":["x"],"extra":[{"translate":"multiplayer.disconnect.banned.expiration","with":["d"]}]}'::jsonb);
select t.eq('play phase NBT (not whitelisted) is {translate:...}', proto.nbt_root(mc.disconnect_nbt('multiplayer.disconnect.not_whitelisted')),
            '\x0a08'::bytea || '\x0009'::bytea || convert_to('translate', 'UTF8') || '\x0026'::bytea || convert_to('multiplayer.disconnect.not_whitelisted', 'UTF8') || '\x00'::bytea);

-- server full: max-players 2 with two online, an op that bypasses the limit still gets in
update mc.server_property set value = '2' where key = 'max-players';
update mc.player set conn_id = 1, entity_id = 1 where uuid = '00000000-0000-0000-0000-00000000aaa1';
insert into mc.player (uuid, name, conn_id, entity_id) values ('00000000-0000-0000-0000-00000000aaa2', 'Bob', 2, 2) on conflict do nothing;
select t.eq('full server refuses', (select reason_key from mc.login_check('00000000-0000-0000-0000-00000000aaa3', 'Carl')), 'multiplayer.disconnect.server_full');
insert into mc.op values ('00000000-0000-0000-0000-00000000aaa4', 'Vip', 4, true);
select t.is_true('op with bypassesPlayerLimit joins a full server', (select allowed from mc.login_check('00000000-0000-0000-0000-00000000aaa4', 'Vip')));
update mc.server_property set value = '20' where key = 'max-players';
update mc.player set conn_id = null, entity_id = null;

select t.eq('permission level of a non-op', mc.permission_level('00000000-0000-0000-0000-00000000aaa1'), 0);
select t.eq('permission level of an op', mc.permission_level('00000000-0000-0000-0000-00000000ccc1'), 4);
