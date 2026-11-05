-- The plans (auto_explain, with timing) of the statements of one visibility refresh >= 1 ms, on the state a walk.sh run left behind.  A fraction of the players is moved a few blocks first; rolled back.
--   psql -v fn=mc.refresh_visibility_vis -v frac=0.27 -v step=4.6 -f tests/bench/game/vis_plan.sql   (the plans go to the server log: client_min_messages = log shows them here)
load 'auto_explain';
set auto_explain.log_min_duration = 1; set auto_explain.log_analyze = on; set auto_explain.log_buffers = on; set auto_explain.log_nested_statements = on; set auto_explain.log_timing = off;
set client_min_messages = log;
begin;
update mc.player set x = x - sin(radians(yaw)) * :step, z = z + cos(radians(yaw)) * :step, chunk_x = floor((x - sin(radians(yaw)) * :step) / 16)::int, chunk_z = floor((z + cos(radians(yaw)) * :step) / 16)::int, vis_dirty = true
 where conn_id is not null and random() < :frac;
select * from :fn();
rollback;
