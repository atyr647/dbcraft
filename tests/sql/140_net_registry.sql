-- Registry data and tags: rows loaded from a vanilla capture, re-encoded in SQL, compared byte for byte with what the server sent.
\ir _net_helpers.sql

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

    -- the same rows for a client that already knows the core pack: vanilla sends the names without data
    create table t.cap_known (idx int, dir text, state text, pid int, name text, len int, hex text);
    \copy t.cap_known from program 'python3 tools/capture_to_tsv.py play_known'
    select count(*) > 0 as have_known from t.cap_known \gset
    \if :have_known
        select t.eq('pack the entries came from', (select string_agg(distinct from_pack, ',') from ref.dp_entry), 'minecraft:core:26.3');
        select t.eq('known-core registry_data #' || c.k || ' ' || r.registry,
                    encode(proto.frame(net.pkt('configuration', 'clientbound', 'minecraft:registry_data'), net.registry_data_body(r.registry, array['minecraft:core:26.3'])), 'hex'), c.hex)
        from (select row_number() over (order by idx) as k, hex from t.cap_known where state = 'configuration' and name = 'minecraft:registry_data') c
        join (select row_number() over (order by seq) as k, registry from ref.dp_registry) r using (k);
        select t.eq('update_tags is the same for a known-core client', (select hex from t.cap_known where name = 'minecraft:update_tags'),
                    (select hex from t.cap_play where state = 'configuration' and name = 'minecraft:update_tags'));
    \else
        select t.skip('no play_known capture (tools/capture_vanilla.py --known-core --out tests/fixtures/captured/play_known.jsonl)');
    \endif

    -- cache: one build per combination of known packs, framed per connection
    select t.eq('known variant key', net.known_variant(array['minecraft:core:26.3', 'other:pack:1']), 'minecraft:core:26.3');
    select t.eq('unknown pack gives the full variant', net.known_variant(array['other:pack:1']), '');
    select net.on_connect(1);
    select net.send_config_data(1, '{}');
    -- sql/462: the packets are one pre-framed outbox row (the drain concatenates a connection's rows, so the wire bytes are unchanged): count the frames in it
    select t.eq('full variant: 33 packets queued', (select count(*) from t.frames((select string_agg(data, ''::bytea order by seq) from net.outbox where conn_id = 1)))::int, 33);
    select t.eq('cache has one variant', (select count(distinct variant) from net.config_cache)::int, 1);
    select net.send_config_data(1, array['minecraft:core:26.3']);
    select t.eq('second variant built on demand', (select count(distinct variant) from net.config_cache)::int, 2);
    select t.is_true('known variant is much smaller', (select sum(length(body)) from net.config_cache where variant = 'minecraft:core:26.3' and packet = 'minecraft:registry_data')
                                                       < (select sum(length(body)) from net.config_cache where variant = '' and packet = 'minecraft:registry_data') / 10);

    -- the rows are editable and the packets follow
    update ref.dp_node set f = f + 0.25 where registry = 'minecraft:worldgen/biome' and entry = 'minecraft:plains' and key = 'temperature';
    select t.eq('editing a row empties the cache', (select count(*) from net.config_cache)::int, 0);
    select t.is_true('the edited entry no longer counts as unchanged from the pack',
                     (select from_pack is null from ref.dp_entry where registry = 'minecraft:worldgen/biome' and name = 'minecraft:plains'));
    select t.is_true('the edit changes the full packet',
                     encode(proto.frame(net.pkt('configuration', 'clientbound', 'minecraft:registry_data'), net.registry_data_body('minecraft:worldgen/biome')), 'hex')
                     <> (select hex from t.cap_play where state = 'configuration' and name = 'minecraft:registry_data' order by idx limit 1));
    select t.is_true('a known-core client now gets data for the edited entry only',
                     length(net.registry_data_body('minecraft:worldgen/biome', array['minecraft:core:26.3']))
                     > length(net.registry_data_body('minecraft:chat_type', array['minecraft:core:26.3'])) + 100
                     and (select count(*) from ref.dp_entry where registry = 'minecraft:worldgen/biome' and from_pack is null) = 1);
\else
    select t.skip('no vanilla capture (tools/capture_vanilla.py --out tests/fixtures/captured/play_nocomp.jsonl)');
\endif
