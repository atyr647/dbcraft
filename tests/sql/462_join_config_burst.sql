-- sql/462: a joiner's configuration data is ONE cached, pre-framed row.  The bytes must equal what framing the packets of net.config_cache one by one produced (the
-- original did exactly that per joiner), for every compression threshold; the cache must empty whenever its source changes; and it must never serve frames made by
-- a different deflate implementation.
\ir _net_helpers.sql
\ir ../../sql/460_join_codec.sql
\ir ../../sql/462_join_config_burst.sql
\! python3 tools/load_datapack.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"

-- the original, per packet: frame every cached packet for this connection's threshold, in order
create or replace function t.expected_burst(p_variant text, p_threshold int) returns bytea language sql as $$
    select string_agg(net.frame(p_threshold, pk.protocol_id, k.body), ''::bytea order by k.seq)
    from net.config_cache k join ref.packet pk on pk.state = 'configuration' and pk.direction = 'clientbound' and pk.name = k.packet
    where k.variant = p_variant $$;

select net.on_connect(1, null);
select net.on_connect(2, null);
update net.conn set compression = 256 where conn_id = 2;

select net.send_config_data(1, '{}'::text[]);
select t.is_true('the cache was built on first use', (select count(*) from net.config_cache where variant = '') > 30);
select t.eq('one row in the outbox instead of 33', (select count(*)::int from net.outbox where conn_id = 1), 1);
select t.eq('threshold off: the row is the per-packet framing, byte for byte', t.take(1), t.expected_burst('', -1));
select t.is_true('...and it is big (the registry packets are about 200 KB)', length(t.expected_burst('', -1)) > 100000);

select net.send_config_data(2, '{}'::text[]);
select t.eq('threshold 256: the row is the per-packet framing (small packets uncompressed, large ones deflated), byte for byte', t.take(2), t.expected_burst('', 256));
select t.is_true('...which is much smaller than uncompressed', length(t.expected_burst('', 256)) < length(t.expected_burst('', -1)) / 2);
select t.eq('two cache rows now: threshold -1 and 256 (same variant, same implementation)', (select count(*)::int from net.config_burst where variant = ''), 2);

-- a second joiner is served from the cache: the burst is not rebuilt (the stored value is the same row)
create table t.before_second as select md5(burst) m, threshold from net.config_burst;
select net.send_config_data(1, '{}'::text[]);
select t.eq('the second joiner gets the same bytes', t.take(1), t.expected_burst('', -1));
select t.eq('...from the same cached rows', (select count(*)::int from (select md5(burst) m, threshold from net.config_burst except select * from t.before_second) x), 0);

-- a connection that is gone gets nothing
select net.send_config_data(404, '{}'::text[]);
select t.eq('a missing connection: no row', (select count(*)::int from net.outbox where conn_id = 404), 0);

-- invalidation: whatever empties net.config_cache empties the bursts
delete from net.config_cache;
select t.eq('delete from net.config_cache empties net.config_burst', (select count(*)::int from net.config_burst), 0);
select net.send_config_data(1, '{}'::text[]);
select t.eq('...and the next joiner rebuilds identical bytes', t.take(1), t.expected_burst('', -1));
select t.is_true('...into a fresh cache row', (select count(*) from net.config_burst) = 1);
truncate net.config_cache;
select t.eq('truncate net.config_cache empties net.config_burst too', (select count(*)::int from net.config_burst), 0);
select net.send_config_data(1, '{}'::text[]);
select t.take(1);
-- editing the data itself: the existing triggers on ref.dp_* empty net.config_cache, which empties the bursts
select t.is_true('a burst exists before the edit', (select count(*) from net.config_burst) = 1);
update ref.dp_tag_registry set seq = seq where seq = (select min(seq) from ref.dp_tag_registry);
select t.eq('editing ref.dp_* data empties net.config_burst (through net.config_cache)', (select count(*)::int from net.config_burst), 0);

-- the known-packs variant is part of the key: a client that knows the core pack gets a different (smaller) burst
select t.is_true('the data comes from at least one pack, so variants differ', (select count(distinct from_pack) from ref.dp_entry where from_pack is not null) >= 1);
select net.send_config_data(1, array['minecraft:core:' || net.setting('version_name')]);
select t.eq('a client that knows the core pack: the row is the per-packet framing of that variant', t.take(1), t.expected_burst(net.known_variant(array['minecraft:core:' || net.setting('version_name')]), -1));
select t.is_true('...and a cache row exists for that variant', (select count(*) from net.config_burst where variant = net.known_variant(array['minecraft:core:' || net.setting('version_name')])) = 1);

-- the deflate implementation is part of the key
select t.eq('the cache key uses the active implementation', (select count(distinct impl)::int from net.config_burst), 1);
do $$
begin
    if mc.native_deflate_available() then
        delete from net.config_burst;
        perform net.send_config_data(2, '{}'::text[]); perform t.take(2);
        perform mc.select_deflate('sql');
        perform net.send_config_data(2, '{}'::text[]);
        perform t.eq('switching the deflate implementation adds a separate cache row (frames of the other implementation are never served)',
                     (select count(distinct impl)::int from net.config_burst where threshold = 256), 2);
        perform t.eq('...and what is sent matches the active implementation', t.take(2), t.expected_burst('', 256));
        perform mc.select_deflate('native');
    else
        raise notice 'ok   (skipped: dbcraft_zlib is not installed, one implementation only)';
    end if;
end $$;
