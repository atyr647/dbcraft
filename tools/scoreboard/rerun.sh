#!/usr/bin/env bash
# Re-run the scenarios that failed for harness reasons: block edits (verified responses), the 10,000-chunk world (crash recovery) and the 10-minute tail.
cd "$(dirname "$0")/../.."
M=$(cat /tmp/scoreboard/dbmode)
Q="--quiet-wait 60 --dbmode $M"
python3 tools/scoreboard/run.py blocks --reps 2 --tag misc2 $Q
python3 tools/scoreboard/run.py world10k --reps 1 --tag misc2 $Q
python3 tools/scoreboard/run.py pop --n 200 --moving 1.0 --reps 1 --hold 600 --tag tail --join-spread 20 --ready-timeout 300 $Q
