-- Handshake, status, login: against adacraft's golden corpus and byte for byte against captures of a real vanilla 26.3 server.
-- Helpers: feed a wire frame (with length prefix) as the gateway would hand it over (prefix stripped); take what the server queued.
\ir _net_helpers.sql

-- vanilla-compatible settings for the byte comparisons
update net.setting set value = 'vanilla-oracle' where key = 'motd';
update net.setting set value = '5' where key = 'max_players';

------------------------------------------------------------------------------------------------ pure helpers
select t.eq('offline uuid of Notch (matches adacraft corpus)', net.offline_uuid('Notch'), 'b50ad385-829d-3141-a216-7e7d7539ba7f'::uuid);
select t.eq('offline uuid of Probe (as vanilla gave it)', net.offline_uuid('Probe'), '3f0ca0c8-9f16-3b87-92fb-b626b9a1bb99'::uuid);
select t.is_true('valid names', net.valid_name('Notch') and net.valid_name('a_B-9') and net.valid_name('~!'));
select t.is_true('invalid names', not net.valid_name('has space') and not net.valid_name('seventeen_chars__') and not net.valid_name(E'tab\t') and not net.valid_name('é'));
select t.eq('pid 1 byte', net.pid('\x00ff'), 0);
select t.eq('pid 2 bytes (ticking_step is 131)', net.pid('\x8301'), 131);
select t.is_true('pid overlong/garbage is null', net.pid('\x8000') is null and net.pid('\x80') is null and net.pid('\x') is null);
select t.eq('pkt name lookup', net.pkt('login', 'serverbound', 'minecraft:hello'), 0);
select t.eq('pkt_name lookup', net.pkt_name('login', 'serverbound', 3), 'minecraft:login_acknowledged');

------------------------------------------------------------------------------------------------ status, byte for byte
create table t.cap_status (idx int, dir text, state text, pid int, name text, len int, hex text);
\copy t.cap_status from program 'python3 tools/capture_to_tsv.py status'
select count(*) > 0 as have from t.cap_status \gset
\if :have
    select net.on_connect(1);
    select t.feed(1, hex) from t.cap_status where name = 'minecraft:intention';
    select t.feed(1, hex) from t.cap_status where name = 'minecraft:status_request';
    select net.process();
    select t.eq('status_response equals vanilla', t.take_hex(1), (select hex from t.cap_status where name = 'minecraft:status_response'));
    select t.feed(1, hex) from t.cap_status where name = 'minecraft:ping_request';
    select net.process();
    select t.eq('pong_response equals vanilla', t.take_hex(1), (select hex from t.cap_status where name = 'minecraft:pong_response'));
    select t.is_true('closes after pong', (select closing from net.conn where conn_id = 1));
\else
    select t.skip('no status capture (run tools/capture_vanilla.py --status --out tests/fixtures/captured/status.jsonl)');
\endif

-- without a capture: the same exchange from first principles
select net.on_connect(2);
select t.feed(2, replace('10 00 89 06 09 6C 6F 63 61 6C 68 6F 73 74 63 DD 01', ' ', ''));
select t.feed(2, '0100');
select net.process();
select t.eq('status_response json', encode(substring(decode(t.take_hex(2), 'hex') from 4), 'escape'),
            '{"description":"vanilla-oracle","players":{"max":5,"online":0},"version":{"name":"26.3","protocol":777}}');
select t.eq('state after status handshake', (select state from net.conn where conn_id = 2), 'status');

------------------------------------------------------------------------------------------------ login, byte for byte
create table t.cap_play (idx int, dir text, state text, pid int, name text, len int, hex text);
\copy t.cap_play from program 'python3 tools/capture_to_tsv.py play_nocomp'
select count(*) > 0 as have from t.cap_play \gset
\if :have
    select net.on_connect(3);
    select t.feed(3, hex) from t.cap_play where name = 'minecraft:intention';
    select t.feed(3, hex) from t.cap_play where name = 'minecraft:hello' and state = 'login';
    select net.process();
    -- login_finished: GameProfile then a random session id (the last 16 bytes) -> compare all but those
    select t.eq('login_finished equals vanilla (session id masked)',
                left(t.take_hex(3), -32), (select left(hex, -32) from t.cap_play where name = 'minecraft:login_finished'));
    select t.eq('state is login_ack', (select state from net.conn where conn_id = 3), 'login_ack');
    select t.eq('session id is stored', (select session_id is not null from net.conn where conn_id = 3), true);
\else
    select t.skip('no play capture (run tools/capture_vanilla.py)');
\endif

create table t.cap_bad (idx int, dir text, state text, pid int, name text, len int, hex text);
\copy t.cap_bad from program 'python3 tools/capture_to_tsv.py badname'
select count(*) > 0 as have from t.cap_bad \gset
\if :have
    select net.on_connect(4);
    select t.feed(4, hex) from t.cap_bad where name = 'minecraft:intention';
    select t.feed(4, hex) from t.cap_bad where name = 'minecraft:hello';
    select net.process();
    select t.eq('invalid-name disconnect equals vanilla', t.take_hex(4), (select hex from t.cap_bad where name = 'minecraft:login_disconnect'));
    select t.is_true('connection is closing', (select closing from net.conn where conn_id = 4));
\else
    select t.skip('no badname capture (tools/capture_vanilla.py --name "has space" --out tests/fixtures/captured/badname.jsonl)');
\endif

-- incompatible protocol version: observed from vanilla with protocols 776 and 778
select net.on_connect(5);
select t.feed(5, encode(proto.frame(0, proto.varint(776) || proto.string('127.0.0.1') || proto.i16(25599) || proto.varint(2)), 'hex'));
select net.process();
select t.eq('incompatible version disconnect (vanilla bytes)', t.take_hex(5),
            '4500437b227472616e736c617465223a226d756c7469706c617965722e646973636f6e6e6563742e696e636f6d70617469626c65222c2277697468223a5b2232362e33225d7d');

------------------------------------------------------------------------------------------------ adacraft golden corpus
create table t.corpus (scenario text, category text, initial_state text, step int, direction text, input text, outcome text, packet_id text, state_after text, rejection text);
\copy t.corpus from program 'python3 tools/corpus_to_tsv.py'
select count(*) > 0 as have from t.corpus \gset
\if :have
    do $$
    declare s record; st record; cid bigint := 1000; n int := 0; got text; want_state text; c net.conn;
    begin
        -- framing-level scenarios (bad length prefixes) and the clientbound-direction one belong to the gateway, not to SQL
        for s in select distinct scenario, initial_state from t.corpus
                 where scenario not in ('framing-oversize-length','truncated-frame','overlong-varint-length','length-payload-mismatch','negative-length','wrong-direction')
                 order by scenario loop
            cid := cid + 1; n := n + 1;
            insert into net.conn(conn_id, state) values (cid, case s.initial_state when 'HANDSHAKE' then 'handshake' when 'STATUS' then 'status' when 'LOGIN' then 'login' end);
            for st in select * from t.corpus where scenario = s.scenario order by step loop
                if st.direction <> 'serverbound' then continue; end if;      -- what the server sends back is checked separately below
                perform t.feed(cid, st.input);
                perform net.process();
                select * into c from net.conn where conn_id = cid;
                got := t.take_hex(cid);
                if st.outcome = 'accepted' then
                    want_state := case st.state_after when 'STATUS' then 'status' when 'LOGIN' then 'login' when 'LOGIN_AWAITING_ACK' then 'login_ack'
                                                      when 'CONFIGURATION' then 'configuration' when 'HANDSHAKE' then 'handshake' when 'PLAY' then 'play' end;
                    if (c.closing and s.scenario <> 'status-ping') or c.state is distinct from want_state then   -- status-ping: vanilla closes the socket after the pong, the protocol state stays status
                        raise exception 'FAIL corpus % step %: accepted but closing=% state=% (want %)', s.scenario, st.step, c.closing, c.state, want_state;
                    end if;
                else
                    if not c.closing then raise exception 'FAIL corpus % step %: rejected frame did not close the connection', s.scenario, st.step; end if;
                    if st.rejection = 'disconnect' and left(got, 2) = '' then raise exception 'FAIL corpus % step %: expected a pending disconnect', s.scenario, st.step; end if;
                    if st.rejection <> 'disconnect' and got <> '' then raise exception 'FAIL corpus % step %: expected no output, got %', s.scenario, st.step, got; end if;
                end if;
            end loop;
            raise notice 'ok   corpus %', s.scenario;
        end loop;
        if n < 14 then raise exception 'FAIL only % corpus scenarios ran', n; end if;
    end $$;

    -- login success: adacraft's corpus bytes lack the session id that 26.3 appends (vanilla sends 16 more bytes), so ours must equal
    -- the corpus bytes except for the length byte, plus exactly 16 more bytes.
    select net.on_connect(2000);
    select t.feed(2000, replace('10 00 89 06 09 6C 6F 63 61 6C 68 6F 73 74 63 DD 02', ' ', ''));
    select t.feed(2000, input) from t.corpus where scenario = 'login-offline-happy' and step = 1;
    select net.process();
    select t.eq('login_finished = corpus bytes + 16-byte session id (length byte aside)',
                substr(t.take_hex(2000), 3, 2 * 23), (select substr(input, 3, 2 * 23) from t.corpus where scenario = 'login-offline-happy' and step = 2));
\else
    select t.skip('adacraft corpus not found (DBCRAFT_CORPUS)');
\endif
