#!/usr/bin/env bash
# The whole final campaign in one go (docs/SCOREBOARD.md), most valuable rows first.  Resumable: every runner skips the cells already in $SCORE_RESULTS
# (docs/final-campaign/results.jsonl, set by resume.sh).   usage: tools/scoreboard/resume.sh
cd "$(dirname "$0")/../.."
export SCORE_XMS=1G SCORE_XMX=2G
mkdir -p $SCORE_OUT
tools/scoreboard/campaign.sh idle walk storm misc
tools/scoreboard/mobs.sh docs/final-campaign/mobs 3
tools/scoreboard/campaign.sh crowd
python3 tools/scoreboard/terrain.py --size 64 --reps 3
SOAK_REPS=2 tools/scoreboard/campaign.sh soak
tools/scoreboard/diag.sh
echo "chain done" >> $SCORE_OUT/campaign.log
