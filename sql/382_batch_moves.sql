-- Batched pipeline, part 3: movement (flag `mv`).  First version: delegates to the baseline so the other components can be verified and measured alone.
create or replace function mc.moves_batched(cur_tick bigint) returns table(moved int, corrected int, kicked int) language sql as $$
    select * from mc.apply_player_moves(cur_tick) $$;
