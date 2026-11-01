-- Block activity on top of the tuning trial's bots (WORKLOAD=blocks of tests/bench/tick/run.sh and churn.sh): every tick three blocks change somewhere in the walk area and five
-- connections have a block-change acknowledgement pending, as if a few players were building.  This puts mc.broadcast_block_events (block updates, break effects, chunk
-- re-sends for the changed chunks, acknowledgements) on the path of every tick.  Needs tests/bench/tuning/steady.sql (tune.gen) and tests/bench/tick/cpu.sql (schema tickbench).
create or replace function tickbench.gen_blocks(p_frac float8) returns void language plpgsql as $$
declare i int;
begin
  perform tune.gen(p_frac);
  for i in 1 .. 3 loop
    perform mc.set_block('minecraft:overworld', (random() * 1500)::int, -61 + (random() * 3)::int, (random() * 1500)::int,
                         (array['minecraft:stone', 'minecraft:air', 'minecraft:dirt'])[1 + (random() * 2.99)::int]);
  end loop;
  insert into mc.pending_ack (conn_id, sequence) select conn_id, (random() * 1000)::int from mc.player where conn_id is not null order by random() limit 5;
end $$;
