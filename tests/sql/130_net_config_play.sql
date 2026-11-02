-- Replay a captured vanilla 26.3 session (offline login -> configuration -> play entry) through net.process() and compare every clientbound
-- packet, in order, with what the real server sent.  Needs the captures and a vanilla datapack capture (skipped with a notice otherwise).
\ir _net_helpers.sql

create table t.cap (idx int, dir text, state text, pid int, name text, len int, hex text);
\copy t.cap from program 'python3 tools/capture_to_tsv.py play_nocomp'
select coalesce(bool_or(name = 'minecraft:login' and dir = 'clientbound' and md5(hex) = '9fe6e9034c2f33d669b23b371c36ce58'), false) as have, count(*) > 0 as have_any from t.cap \gset
\if :have
    \! python3 tools/load_datapack.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
    \! python3 tools/load_static_packets.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"

    -- the world as that server had it: settings, and the join record it used (a test-only override of the hook)
    update net.setting set value = 'vanilla'         where key = 'brand';
    update net.setting set value = 'vanilla-oracle'  where key = 'motd';
    update net.setting set value = '5'               where key = 'max_players';
    update net.setting set value = '2'               where key = 'view_distance';
    update net.setting set value = '2'               where key = 'simulation_distance';
    create or replace function net.hook_join_info(p_conn bigint) returns net.join_info language plpgsql stable as $f$
    declare j net.join_info := net.default_join_info(p_conn, 1);
    begin
        j.entity_id := 20; j.seed := x'aa7208e3219d34cc'::bigint; j.is_flat := true; j.sea_level := -63; j.difficulty := 0;
        j.x := -6.5; j.y := -60; j.z := -5.5; j.motd := 'vanilla-oracle';
        j.game_time := 2984; j.clocks := '[{"id":1,"ticks":2984,"partial":0,"rate":1.0},{"id":0,"ticks":2984,"partial":0,"rate":1.0}]';
        j.spawn_y := -60; j.chunk_x := -1; j.chunk_z := -1; j.saturation := 13;
        return j;
    end $f$;

    select net.on_connect(1);
    select t.feed(1, hex) from t.cap where dir = 'serverbound' and state in ('handshake', 'login', 'configuration') order by idx;
    select net.process();
    create table t.ours as select idx, encode(frame, 'hex') as hex from t.frames(t.take(1));
    create table t.theirs as select row_number() over (order by idx) - 1 as idx, name, hex
        from t.cap where dir = 'clientbound' and idx <= (select idx from t.cap where name = 'minecraft:set_experience' and state = 'play' order by idx limit 1);

    select t.eq('same number of clientbound packets, login_finished through set_experience', (select count(*) from t.ours)::int, (select count(*) from t.theirs)::int);
    select t.eq('connection reached play', (select state from net.conn where conn_id = 1), 'play');
    select t.eq(lpad(o.idx::text, 2, '0') || ' ' || h.name || ' byte-exact',
                case when h.name = 'minecraft:login_finished' then left(o.hex, -32) else o.hex end,
                case when h.name = 'minecraft:login_finished' then left(h.hex, -32) else h.hex end)      -- login_finished ends in a random session id
    from t.ours o join t.theirs h using (idx) order by o.idx;
\else
    select t.skip(case when :'have_any'::boolean then 'the capture is not the reference session this test replays (it needs that one run of the vanilla server: entity id 20, hashed seed aa7208e3219d34cc, spawn -6.5 -60 -5.5, game time 2984); a capture recorded by tools/bootstrap.sh is a different run, so this byte-for-byte replay is SKIPPED' else 'no vanilla capture (tools/bootstrap.sh records one; or tools/capture_vanilla.py)' end);
\endif
