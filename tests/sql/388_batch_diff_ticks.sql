-- this test pins the classic (simplified) player broadcast of sql/430-468; the vanilla tracker of sql/900-910 has its own test (900_vis.sql)
update mc.server_property set value = 'false' where key = 'dbcraft.vanilla-tracker';
-- Differential test, Part B: whole ticks, mc.server_tick_batched() against mc.server_tick(), several consecutive ticks per random trial, including cold-path frames
-- (unknown ids, chunk_batch_received, keep-alive answers), chunk-border crossings (chunk streaming), visibility changes and connections closing.  Output of the
-- gateway's drain is compared per connection both in order and as an unordered set: several connections closing in the same tick are processed in physical row order by
-- the baseline (an unordered loop), which it does not define, so order is only required on trials where at most one connection closes per tick.
\ir _net_helpers.sql
\ir ../../sql/400_integration.sql
\! python3 tools/load_datapack.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
\! python3 tools/load_static_packets.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
\! python3 tools/load_world_ref.py
\ir _batch_diff_helpers.sql
\ir ../../sql/optional/batch_grid_vis.sql          -- the opt-in grid neighbour search (flag grid) is tested here too

select t.bfresh();
drop function if exists t.part_b(int, int, boolean);
drop function if exists t.part_b(int, int, boolean, boolean);
drop function if exists t.part_b(int, int, boolean, text);
-- p_strict: scripts with at most one misbehaving connection per tick; compared byte for byte in order.  Otherwise (several connections may close in one tick) only what the
-- baseline defines is compared: the frames of the connections that stay, as unordered sets, which connections close, and the state of players, visibility and connections.
create or replace function t.part_b(n_trials int, n_ticks int, p_strict boolean, p_flags text default 'all') returns table(trials int, bad int, close_total int, multi_trials int) language plpgsql as $$
declare tr int; i int; tick_no int; sa text; sb text; cur text; bad_n int := 0; first_batched boolean; errs int; dr record; closes int := 0; multi int := 0; has_multi boolean; st text;
begin
    -- p_flags: the component flags of the batched side (mc.batch_flags); with `ref` it is drained with net.drain_outbox_ref(), as a gateway would
    perform set_config('mc.batch_flags', p_flags, false);
    for tr in 1..n_trials loop
        perform setseed(tr / 7919.0);
        perform t.gen_state(14, true);
        perform t.gen_script(n_ticks, true, p_strict);
        perform t.snap();
        first_batched := tr % 2 = 0; has_multi := false;
        for i in 1..2 loop
            perform t.restore();
            cur := '';
            for tick_no in 1..n_ticks loop
                insert into net.inbox (conn_id, payload) select conn_id, payload from t.script where t.script.tk = tick_no order by ord, conn_id;
                if (i = 1) = first_batched then perform mc.server_tick_batched(); else perform mc.server_tick(); end if;
                select * into dr from t.cap_drain(p_flags like '%ref%' and (i = 1) = first_batched);
                if (i = 1) <> first_batched then closes := closes + dr.n_close; if dr.n_close >= 2 then has_multi := true; end if; end if;
                st := E'\n#players\n' || t.cap_players() || E'\n#visible\n' || t.cap_visible() || E'\n#conn\n' || t.cap_conn();
                cur := cur || E'\n#tick ' || tick_no || E'\n'
                       || case when p_strict then dr.seq_txt else dr.surv_txt || E'\n#closing ' || dr.closes_txt end || st;
            end loop;
            select count(*) into errs from mc.error_log;
            cur := cur || E'\n#errors ' || errs;
            if (i = 1) = first_batched then sb := cur; else sa := cur; end if;
        end loop;
        if has_multi then multi := multi + 1; end if;
        if sa is distinct from sb then
            bad_n := bad_n + 1;
            if bad_n <= 3 then raise notice 'Part B/C/D/E (flags=%, strict=%) trial % differs: %', p_flags, p_strict, tr, t.first_diff(sa, sb); end if;
        end if;
    end loop;
    perform set_config('mc.batch_flags', 'all', false);
    trials := n_trials; bad := bad_n; close_total := closes; multi_trials := multi; return next;
end $$;
create temp table _b as select * from t.part_b(120, 4, true);
select t.eq('Part B: whole batched ticks equal whole baseline ticks, byte for byte and in order, on 120 random 4-tick trials with at most one misbehaving connection per tick (drain bytes, players, visibility, connections, errors)', (select bad from _b), 0);
select t.is_true('Part B: the trials had connections closing (' || (select close_total from _b) || ' closes) and no tick with several', (select close_total > 40 and multi_trials = 0 from _b));
create temp table _c as select * from t.part_b(120, 4, false);
select t.eq('Part C: with several connections closing in one tick, the surviving connections get the same frames (unordered), the same connections close, and players, visibility and connections end identical, on 120 random trials', (select bad from _c), 0);
select t.is_true('Part C: the trials had ticks with several closing connections (' || (select multi_trials from _c) || ' trials)', (select multi_trials > 10 from _c));

-- the reference outbox (flag ref, sql/383): chunk packets queued as references and expanded by net.drain_outbox_ref() must give the same bytes
create temp table _d as select * from t.part_b(80, 4, true, 'all,ref');
select t.eq('Part D: with the reference outbox (flag ref + net.drain_outbox_ref) whole ticks still equal the baseline, byte for byte and in order, on 80 random trials', (select bad from _d), 0);
create temp table _e as select * from t.part_b(80, 4, false, 'all,ref');
select t.eq('Part D: ... and with several connections closing in one tick (survivors, closes and state)', (select bad from _e), 0);

-- the grid neighbour search (flag grid, sql/optional/batch_grid_vis.sql): the same pairs and packets as the default visibility refresh
create temp table _f as select * from t.part_b(60, 4, true, 'all,grid');
select t.eq('Part E: with the grid neighbour search (flag grid) whole ticks equal the baseline, byte for byte and in order, on 60 random trials', (select bad from _f), 0);

-- the single-statement drain (flag out, opt-in): one outbox row per connection must still give the same bytes
create temp table _g as select * from t.part_b(60, 4, true, 'all,out');
select t.eq('Part F: with the one-row-per-connection drain (flag out) whole ticks equal the baseline, byte for byte and in order, on 60 random trials', (select bad from _g), 0);
