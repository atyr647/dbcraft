select t.eq('block states loaded', (select count(*) from ref.block_state)::int, 35723);
select t.eq('blocks loaded', (select count(*) from ref.block)::int, 1286);
select t.eq('air is state 0', (select state_id from ref.block_state where name = 'minecraft:air'), 0);
select t.eq('oak_log default axis=y', (select name from ref.block_state where block = 'minecraft:oak_log' and is_default), 'minecraft:oak_log[axis=y]');
select t.eq('state ids contiguous', (select max(state_id) + 1 - count(*) from ref.block_state)::int, 0);
select t.eq('one default per block', (select count(*) from ref.block b where (select count(*) from ref.block_state s where s.block = b.name and s.is_default) <> 1)::int, 0);
select t.eq('block default_state matches', (select count(*) from ref.block b join ref.block_state s on s.state_id = b.default_state where not s.is_default or s.block <> b.name)::int, 0);
select t.is_true('login hello packet is id 0', (select protocol_id = 0 from ref.packet where state = 'login' and direction = 'serverbound' and name = 'minecraft:hello'));
select t.is_true('items present', (select count(*) > 1000 from ref.item));
