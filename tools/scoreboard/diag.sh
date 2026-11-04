#!/usr/bin/env bash
# Where does dbcraft's idle / edit cost come from?  The same cells as the headline table (dbcraft only, 2 repetitions) with dbcraft.dynamics = off.  A DIAGNOSIS: the headline table
# runs with dynamics on, the supported default.   usage: tools/scoreboard/cenv tools/scoreboard/diag.sh
cd "$(dirname "$0")/../.."
export SCORE_XMS=1G SCORE_XMX=2G
R="python3 tools/scoreboard/run.py"
G="--load-max 1.5 --quiet-wait 0 --reps 2 --hold 60 --servers dbcraft"
P="psql -X -q -h /tmp -p $SCORE_PGPORT -U postgres dbcraft -c"
$P "update mc.server_property set value = 'off' where key = 'dbcraft.dynamics'"
$R pop --n 50 --moving 0 $G --tag diag-nodyn
$R pop --n 200 --moving 0 $G --tag diag-nodyn
$R pop --n 200 --moving 1.0 --bound 500 $G --tag diag-nodyn
$R edit --n 1 --reps 2 --load-max 1.5 --quiet-wait 0 --servers dbcraft --tag diag-nodyn
$P "update mc.server_property set value = 'on' where key = 'dbcraft.dynamics'"
echo "diag done"
