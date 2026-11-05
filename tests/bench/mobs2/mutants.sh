#!/usr/bin/env bash
# the mutation checks of the vanilla AI and the lane-retry tests (docs/WHY-MOBS-COST.md section 10): every mutant must be killed.   env: PGHOST PGPORT PGUSER PGDATABASE (a database with the tree applied)
cd "$(dirname "$0")/../../.."
M=tests/bench/mobs2/mutate.sh
echo "== 1011 vanilla AI"
$M sql/942_entity_vanilla_ai.sql 'a\.decide and not exists \(select 1 from mc\.entity_viewer_cell v where abs\(v\.cx - p_cx\) <= p_near and abs\(v\.cz - p_cz\) <= p_near\) as dorm' 'false as dorm' tests/sql/1011_entity_vanilla_ai.sql
$M sql/942_entity_vanilla_ai.sql '\^ 2 < 1024\) as inside' '^ 2 < 1000000000) as inside' tests/sql/1011_entity_vanilla_ai.sql
$M sql/942_entity_vanilla_ai.sql 'and pl\.gamemode <> 3' 'and true' tests/sql/1011_entity_vanilla_ai.sql
$M sql/942_entity_vanilla_ai.sql 'ln\(59\.0 / 60\)' 'ln(119.0 / 120)' tests/sql/1011_entity_vanilla_ai.sql
$M sql/942_entity_vanilla_ai.sql '\(\(\(p_born - p_id - \(p_tick \+ 1\)\) % 2\) \+ 2\) % 2' '0' tests/sql/1011_entity_vanilla_ai.sql
$M sql/541_entity_lanes.sql 'update mc\.entity_lane l set dormant = false, lazy = false, goal_until = w\.td, gend = w\.td' 'update mc.entity_lane l set lazy = false' tests/sql/1011_entity_vanilla_ai.sql 'sql/550_entity_split.sql sql/551_entity_fanout.sql sql/940_entity_auto_lanes.sql sql/942_entity_vanilla_ai.sql'
echo "== 1012 lane retry"
$M sql/940_entity_auto_lanes.sql 'p_tick \+ rt where e\.id = any\(fails\)' 'p_tick + rt + 5 where e.id = any(fails)' tests/sql/1012_entity_lane_retry.sql
echo "done"
