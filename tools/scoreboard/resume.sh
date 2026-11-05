#!/usr/bin/env bash
# Start (or resume after a container restart) the final campaign.  Raw results go to docs/final-campaign/ (on disk, committed by checkpoint.sh); every runner skips the cells that are
# already in them.  Recreates the /dev/shm cluster and the gateway when they are gone.   usage: tools/scoreboard/resume.sh
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
mkdir -p /dev/shm/sb docs/final-campaign
chmod 755 /dev/shm/sb
[ -x gateway/target/dbcraft-gateway ] || gateway/build.sh
if [ ! -d /dev/shm/sb/pg/base ]; then tools/scoreboard/cenv tools/scoreboard/dbcraft.sh setup-db; fi
pkill -f checkpoint.sh
nohup tools/scoreboard/checkpoint.sh 60 > /dev/null 2>&1 &
export SCORE_RESULTS=$ROOT/docs/final-campaign/results.jsonl
exec tools/scoreboard/cenv tools/scoreboard/final_chain.sh
