-- Network compression: the part SQL can do (the login_compression packet and below-threshold frames) against a vanilla capture made with
-- network-compression-threshold=256.  Frames at or above the threshold need zlib deflate, which SQL lacks: they raise until a native
-- net.deflate_frame is installed (docs/COMPRESSION.md, docs/NET.md).
-- p_compressed: the frame was sent after compression started, so it has a data length after the packet length (0 = not compressed);
-- the gateway strips it (and inflates when it is not 0) before handing the payload over.
\ir _net_helpers.sql

-- framing rules, no capture needed
select t.eq('threshold off', encode(net.frame(-1, 2, '\xaabb'), 'hex'), '0302aabb');
select t.eq('below threshold: data length 0', encode(net.frame(256, 2, '\xaabb'), 'hex'), '040002aabb');
select t.eq('one below the threshold is still small', encode(net.frame(10, 2, decode(repeat('ab', 8), 'hex')), 'hex'), '0a0002' || repeat('ab', 8));
select t.raises('at the threshold deflate is needed', $$select net.frame(10, 2, decode(repeat('ab', 9), 'hex'))$$);

create table t.cap (idx int, dir text, state text, pid int, name text, len int, hex text);
\copy t.cap from program 'python3 tools/capture_to_tsv.py play_comp256'
select count(*) > 0 as have from t.cap \gset
\if :have
    \! python3 tools/load_datapack.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
    update net.setting set value = '256' where key = 'compression_threshold';
    update net.setting set value = 'vanilla' where key = 'brand';
    select net.on_connect(1);
    select t.feed(1, hex) from t.cap where dir = 'serverbound' and state in ('handshake', 'login') and name <> 'minecraft:login_acknowledged' order by idx;
    select net.process();
    create table t.ours as select idx, encode(frame, 'hex') as hex from t.frames(t.take(1));
    create table t.theirs as select row_number() over (order by idx) - 1 as idx, name, hex from t.cap
        where dir = 'clientbound' and state = 'login' order by idx;
    select t.eq('login_compression and login_finished queued', (select count(*) from t.ours)::int, 2);
    select t.eq('login_compression equals vanilla', (select hex from t.ours where idx = 0), (select hex from t.theirs where name = 'minecraft:login_compression'));
    select t.eq('login_finished (below threshold) equals vanilla, session id masked', (select left(hex, -32) from t.ours where idx = 1),
                (select left(hex, -32) from t.theirs where name = 'minecraft:login_finished'));
    select t.eq('connection now compresses at 256', (select compression from net.conn where conn_id = 1), 256);

    -- configuration start: three small packets, still byte-exact in their compressed-framing form
    select t.feed_c(1, hex) from t.cap where name = 'minecraft:login_acknowledged' and dir = 'serverbound';
    select net.process();
    create table t.cfg as select idx, encode(frame, 'hex') as hex from t.frames(t.take(1));
    select t.eq('config start: three packets', (select count(*) from t.cfg)::int, 3);
    select t.eq('config start packet ' || n.name || ' equals vanilla', c.hex, n.hex)
    from t.cfg c join (select row_number() over (order by idx) - 1 as i, name, hex from t.cap where state = 'configuration' and dir = 'clientbound' order by idx limit 3) n on n.i = c.idx;

    -- registry data is far above 256 bytes: needs deflate, which is not installed -> the connection is dropped with a clear reason, nothing half-sent
    select t.feed_c(1, hex) from t.cap where name = 'minecraft:select_known_packs' and dir = 'serverbound';
    select net.process();
    select t.is_true('without deflate the oversized packet closes the connection', (select closing from net.conn where conn_id = 1));
    select t.is_true('no registry data was left half-queued', (select count(*) from net.outbox where conn_id = 1) = 1);     -- only the disconnect
    select t.is_true('the reason names deflate', position('deflate' in encode(t.take(1), 'escape')) > 0);
\else
    select t.skip('no compressed capture (start a vanilla server with network-compression-threshold=256, then tools/capture_vanilla.py --port N --out tests/fixtures/captured/play_comp256.jsonl)');
\endif
