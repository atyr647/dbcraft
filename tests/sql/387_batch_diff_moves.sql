-- Differential test, Part A: the batched movement phase (mc.moves_batched) against the baseline (mc.apply_player_moves) on random states and random traffic: kicks, NaN and
-- infinite values, jumps, confirmations, malformed packets, clamping, offline players.  From one random state and one script the two functions run in turn (the state is
-- restored in between, and which goes first alternates); the bytes written for every connection, the final state of every player, the kicks and the returned counts
-- must be identical.  See _batch_diff_helpers.sql.
\ir _net_helpers.sql
\ir ../../sql/400_integration.sql
\! python3 tools/load_datapack.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
\! python3 tools/load_static_packets.py "$(python3 tools/capture_to_tsv.py --path play_nocomp)"
\! python3 tools/load_world_ref.py
\ir _batch_diff_helpers.sql

select t.bfresh();
drop function if exists t.part_a(int);
create or replace function t.part_a(n_trials int) returns table(trials int, bad int, total_out_rows bigint, kicked_total int, corrected_total int) language plpgsql as $$
declare tr int; a text; b text; mva record; mvb record; bad_n int := 0; rows_n bigint := 0; k_tot int := 0; c_tot int := 0; first_batched boolean; sa text; sb text;
begin
    for tr in 1..n_trials loop
        perform setseed(tr / 10000.0);
        perform t.gen_state(40, false);
        perform t.gen_script(1, false);
        perform t.snap();
        first_batched := tr % 2 = 0;
        for i in 1..2 loop
            perform t.restore();
            insert into mc.play_in_work (seq, conn_id, packet_id, body)
            select row_number() over (order by conn_id, ord), conn_id::int, net.pid(payload), substring(payload from net.pid_len(payload) + 1) from t.script where tk = 1;
            if (i = 1) = first_batched then
                select * into mvb from mc.moves_batched(101);
                sb := t.cap_players() || E'\n#out\n' || t.cap_play_out() || E'\n#kick\n' || t.cap_kick() || E'\n#ret ' || mvb::text || E'\n#work ' || (select count(*) from mc.play_in_work);
            else
                select * into mva from mc.apply_player_moves(101);
                sa := t.cap_players() || E'\n#out\n' || t.cap_play_out() || E'\n#kick\n' || t.cap_kick() || E'\n#ret ' || mva::text || E'\n#work ' || (select count(*) from mc.play_in_work);
            end if;
        end loop;
        rows_n := rows_n + (select count(*) from mc.play_out);
        k_tot := k_tot + mva.kicked; c_tot := c_tot + mva.corrected;
        if sa is distinct from sb then
            bad_n := bad_n + 1;
            if bad_n <= 3 then raise notice 'Part A trial % differs: %', tr, t.first_diff(sa, sb); end if;
        end if;
    end loop;
    trials := n_trials; bad := bad_n; total_out_rows := rows_n; kicked_total := k_tot; corrected_total := c_tot; return next;
end $$;
create temp table _a as select * from t.part_a(300);
select t.eq('Part A: the batched movement phase equals the baseline on 300 random trials (bytes out, players, kicks, counts)', (select bad from _a), 0);
select t.is_true('Part A: the trials covered kicks and corrections (' || (select kicked_total from _a) || ' kicks, ' || (select corrected_total from _a) || ' corrections)', (select kicked_total > 100 and corrected_total > 100 from _a));

