-- Registry data and tags: rows loaded from a vanilla capture, re-encoded in SQL, compared byte for byte with what the server sent.
create table t.cap_play (idx int, dir text, state text, pid int, name text, len int, hex text);
\copy t.cap_play from program 'python3 tools/capture_to_tsv.py play_nocomp'
select count(*) > 0 as have from t.cap_play \gset
\if :have
    \! python3 tools/load_datapack.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"

    select t.eq('registries loaded', (select count(*) from ref.dp_registry)::int, 32);
    select t.eq('every registry_data packet is stored', (select count(*) from ref.dp_registry)::int,
                (select count(*) from t.cap_play where state = 'configuration' and name = 'minecraft:registry_data')::int);
    select t.is_true('node types are readable', (select count(distinct type) >= 8 from ref.dp_node));

    -- every registry_data packet, in order, byte for byte
    select t.eq('registry_data #' || c.k || ' ' || r.registry,
                encode(proto.frame(net.pkt('configuration', 'clientbound', 'minecraft:registry_data'), net.registry_data_body(r.registry)), 'hex'), c.hex)
    from (select row_number() over (order by idx) as k, hex from t.cap_play where state = 'configuration' and name = 'minecraft:registry_data') c
    join (select row_number() over (order by seq) as k, registry from ref.dp_registry) r using (k);

    select t.eq('update_tags equals vanilla',
                encode(proto.frame(net.pkt('configuration', 'clientbound', 'minecraft:update_tags'), net.update_tags_body()), 'hex'),
                (select hex from t.cap_play where state = 'configuration' and name = 'minecraft:update_tags'));

    -- the rows are editable and the packet follows
    select net.rebuild_config_cache();
    select t.eq('cache holds 32 registries + tags', (select count(*) from net.config_cache)::int, 33);
    select t.eq('cached registry_data equals the direct build', (select body from net.config_cache where seq = 1), net.registry_data_body((select registry from ref.dp_registry where seq = 0)));
    update ref.dp_node set f = f + 0.25 where registry = 'minecraft:worldgen/biome' and entry = 'minecraft:plains' and key = 'temperature';
    select t.eq('editing a row empties the cache', (select count(*) from net.config_cache)::int, 0);
    select t.is_true('the edit changes the packet',
                     encode(proto.frame(net.pkt('configuration', 'clientbound', 'minecraft:registry_data'), net.registry_data_body('minecraft:worldgen/biome')), 'hex')
                     <> (select hex from t.cap_play where state = 'configuration' and name = 'minecraft:registry_data' order by idx limit 1));
\else
    select t.skip('no vanilla capture (tools/capture_vanilla.py --out tests/fixtures/captured/play_nocomp.jsonl)');
\endif
