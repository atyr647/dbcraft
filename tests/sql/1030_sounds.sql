-- Sounds (sql/1030): the `sound` packet, who hears what, and the block sound types read from the jar.  Every packet marked (vanilla) is one the REAL vanilla 26.3 server
-- sent (tests/e2e/sound_probe.py and the survival scenarios, compared in order by tests/e2e/compare_sound.py): the frame is rebuilt byte for byte, the random seed taken from
-- the recording.  Needs the registries (ref.registry: sound events) and the sound data (tools/gen_sounds.sh) for the block types; the packet checks need only the registries.
select (select count(*) from ref.registry where registry = 'minecraft:sound_event') > 0 as have_reg, (select count(*) from mc.sound_type) > 0 as have_types \gset
\if :have_reg
create or replace function t.reset() returns void language sql as $$ truncate mc.play_out, mc.play_in, mc.play_in_work, mc.kick, mc.pending_ack $$;
create or replace function t.out(conn int) returns bytea language sql as $$ select coalesce(string_agg(data, '\x'::bytea order by seq), '\x'::bytea) from mc.play_out where conn_id = conn $$;
select t.eq('sound entity.item.pickup, players (vanilla, step "give")', encode(mc.pkt_sound('entity.item.pickup', 7, 0.5, -60.0, 0.5, 0.2::real, 2.629436492919922::real, 3590977878965552650::bigint), 'hex'), '207794070700000004fffffe20000000043e4ccccd402848b031d5b75ae807060a');
select t.eq('sound block.stone.place, blocks (vanilla, step "place minecraft:stone")', encode(mc.pkt_sound('block.stone.place', 4, 1.5, -59.5, 0.5, 1.0::real, 0.800000011920929::real, -8184087382596992751::bigint), 'hex'), '2077c60c040000000cfffffe24000000043f8000003f4ccccd8e6c47e2fd8cc111');
select t.eq('sound block.wood.place, blocks (vanilla, step "place minecraft:oak_planks")', encode(mc.pkt_sound('block.wood.place', 4, 2.5, -59.5, 0.5, 1.0::real, 0.800000011920929::real, 6252071910178047904::bigint), 'hex'), '2077c50e0400000014fffffe24000000043f8000003f4ccccd56c3d247045c47a0');
select t.eq('sound block.glass.place, blocks (vanilla, step "place minecraft:glass")', encode(mc.pkt_sound('block.glass.place', 4, 3.5, -59.5, 0.5, 1.0::real, 0.800000011920929::real, 5607136928475961630::bigint), 'hex'), '2077d805040000001cfffffe24000000043f8000003f4ccccd4dd08d541cc8d91e');
select t.eq('sound block.sand.place, blocks (vanilla, step "place minecraft:sand")', encode(mc.pkt_sound('block.sand.place', 4, 4.5, -59.5, 0.5, 1.0::real, 0.800000011920929::real, -1099101778678983914::bigint), 'hex'), '2077fc0a0400000024fffffe24000000043f8000003f4ccccdf0bf34c16dd6d316');
select t.eq('sound block.wool.place, blocks (vanilla, step "place minecraft:white_wool")', encode(mc.pkt_sound('block.wool.place', 4, 5.5, -59.5, 0.5, 1.0::real, 0.800000011920929::real, -7292221033938667335::bigint), 'hex'), '2077ca0e040000002cfffffe24000000043f8000003f4ccccd9accd39b007438b9');
select t.eq('sound block.gravel.place, blocks (vanilla, step "place minecraft:dirt")', encode(mc.pkt_sound('block.gravel.place', 4, 6.5, -59.5, 0.5, 1.0::real, 0.800000011920929::real, -3570820386344932148::bigint), 'hex'), '207780060400000034fffffe24000000043f8000003f4ccccdce71e5c7132feccc');
select t.eq('sound block.chest.open, blocks (vanilla, step "open chest")', encode(mc.pkt_sound('block.chest.open', 4, 1.5, -59.5, 0.5, 0.5::real, 0.9661787152290344::real, -1393786537547824319::bigint), 'hex'), '2077de02040000000cfffffe24000000043f0000003f77577deca8468758bd8341');
select t.eq('sound block.chest.close, blocks (vanilla, step "close chest")', encode(mc.pkt_sound('block.chest.close', 4, 1.5, -59.5, 0.5, 0.5::real, 0.9828824996948242::real, -1240385492556401927::bigint), 'hex'), '2077dc02040000000cfffffe24000000043f0000003f7b9e30eec943f763a0b2f9');
select t.eq('sound entity.player.death, players (vanilla)', encode(mc.pkt_sound('entity.player.death', 7, 0.5, -60.0, 0.5, 1.0::real, 1.0::real, -4336951941126137902::bigint), 'hex'), '2077a40a0700000004fffffe20000000043f8000003f800000c3d00d300d3c57d2');
select t.eq('sound entity.player.big_fall, players (vanilla, step "landed")', encode(mc.pkt_sound('entity.player.big_fall', 7, 0.5, -60.0, 0.5, 1.0::real, 1.0::real, 3997269848574747773::bigint), 'hex'), '2077a10a0700000004fffffe20000000043f8000003f800000377927bfb3ad647d');
select t.eq('sound block.grass.fall, players (vanilla, step "landed")', encode(mc.pkt_sound('block.grass.fall', 7, 0.5, -60.0, 0.5, 0.5::real, 0.75::real, -174391695222359462::bigint), 'hex'), '2077f9050700000004fffffe20000000043f0000003f400000fd946fad5a7e3a5a');
select t.eq('sound entity.player.hurt, players (vanilla, step "landed")', encode(mc.pkt_sound('entity.player.hurt', 7, 0.5, -60.0, 0.5, 1.0::real, 1.0::real, -8137687851926684256::bigint), 'hex'), '2077a50a0700000004fffffe20000000043f8000003f8000008f11200394e5fda0');
select t.eq('sound entity.generic.eat, neutral (vanilla, step "use apple")', encode(mc.pkt_sound('entity.generic.eat', 6, 0.5, -60.0, 0.5, 1.0::real, 0.8937678337097168::real, -8814323359816288231::bigint), 'hex'), '2077bf050600000004fffffe20000000043f8000003f64cdf885ad3b9ac2b8f819');
select t.eq('sound entity.player.burp, players (vanilla, step "use apple")', encode(mc.pkt_sound('entity.player.burp', 7, 0.5, -60.0, 0.5, 0.5::real, 0.9753419160842896::real, 2851484769801639765::bigint), 'hex'), '2077a30a0700000004fffffe20000000043f0000003f79b0022792824a52769755');

\if :have_types
select t.eq('block sound types: 130 types, a type for every block', array[(select count(*) from mc.sound_type)::text, (select count(*) from mc.block_sound)::text, (select count(*) from ref.block)::text], array['130', '1286', '1286']);
select t.eq('stone: block.stone.*, volume 1, pitch 1', (select place_snd || ' ' || volume || ' ' || pitch from mc.block_sound_type('minecraft:stone')), 'block.stone.place 1 1');
select t.eq('dirt sounds like gravel (the jar says so)', (select place_snd from mc.block_sound_type('minecraft:dirt')), 'block.gravel.place');
select t.eq('a state with properties: the block decides', (select place_snd from mc.block_sound_type('minecraft:oak_stairs[facing=north,half=bottom,shape=straight,waterlogged=false]')), 'block.wood.place');
select t.eq('grass block fall sound', (select fall_snd from mc.block_sound_type('minecraft:grass_block[snowy=false]')), 'block.grass.fall');

-- who hears a sound: everybody within range but the player who caused it, strictly less than the range
select mc.generate_flat('minecraft:overworld', x, z) from generate_series(-2, 2) x, generate_series(-2, 2) z;
delete from mc.player;
select mc.on_join(1, '00000000-0000-0000-0000-000000103001', 'Placer');
select mc.on_join(2, '00000000-0000-0000-0000-000000103002', 'Near');
select mc.on_join(3, '00000000-0000-0000-0000-000000103003', 'Edge');
select mc.on_join(4, '00000000-0000-0000-0000-000000103004', 'Far');
update mc.player set x = 0.5, y = -60, z = 0.5 where conn_id = 1;
update mc.player set x = 8.5, y = -60, z = 0.5 where conn_id = 2;
update mc.player set x = 16.5, y = -60, z = 0.5 where conn_id = 3;        -- exactly 16 blocks from the block's centre: NOT less than 16, does not hear it
update mc.player set x = 16.4, y = -60, z = 0.5 where conn_id = 4;        -- 15.9 away: hears it
select t.reset();
select mc.snd_place(1, 0, -60, 0, 'minecraft:stone');
select t.eq('a placed block: the others in range hear it (not the placer, not the player exactly 16 blocks away)', (select array_agg(conn_id order by conn_id) from mc.play_out), array[2, 4]);
select t.eq('   the packet is the recorded stone sound at the block centre (volume 1, pitch 0.8)', (select substring(data from 1 for 24) from mc.play_out where conn_id = 2),
  substring(mc.pkt_sound('block.stone.place', 4, 0.5, -59.5, 0.5, 1, 0.8, 0) from 1 for 24));
select t.reset();
select mc.snd_container('minecraft:chest', 0, -60, 0, null, null, null, true);
select t.eq('a chest lid: everybody in range hears it, the opener too', (select array_agg(conn_id order by conn_id) from mc.play_out), array[1, 2, 4]);
select t.eq('   a double chest sounds in the middle of the pair', (select (select mc.pkt_sound('block.chest.open', 4, 1.0, -59.5, 0.5, 0.5, 0.95, 0)) is not null), true);
select t.reset();
select mc.snd_hurt(array[(select entity_id from mc.player where conn_id = 1)], '{}', 'generic');
select t.eq('a hit: the others in range hear the hurt sound, the victim does not (vanilla)', (select array_agg(conn_id order by conn_id) from mc.play_out), array[2, 4]);
select t.reset();
select mc.snd_hurt(array[(select entity_id from mc.player where conn_id = 1)], array[(select entity_id from mc.player where conn_id = 1)], 'generic');
select t.eq('a death: entity.player.death instead (vanilla)', (select encode(substring(data from 3 for 2), 'hex') from mc.play_out where conn_id = 2), 'a40a');
select t.reset();
\else
\echo SKIP: no block sound data (tools/gen_sounds.sh): the block sound type checks are skipped
\endif
\else
\echo SKIP: no sound event registry
\endif
