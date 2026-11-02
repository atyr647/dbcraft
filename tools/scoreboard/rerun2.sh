#!/usr/bin/env bash
# The 10-minute steady-state tail with walkers bounded inside the pre-generated area (both servers), then dbcraft under exploration (walkers leave the explored
# area) with each tick mode.
cd "$(dirname "$0")/../.."
Q="--quiet-wait 60"
python3 tools/scoreboard/run.py pop --n 200 --moving 1.0 --bound 500 --reps 1 --hold 600 --tag tail2 --join-spread 20 --ready-timeout 300 --dbmode batched $Q
python3 tools/scoreboard/run.py pop --n 200 --moving 1.0 --reps 1 --hold 300 --servers dbcraft --tag explore-default --join-spread 20 --ready-timeout 300 --dbmode default $Q
python3 tools/scoreboard/run.py pop --n 200 --moving 1.0 --reps 1 --hold 300 --servers dbcraft --tag explore-batched --join-spread 20 --ready-timeout 300 --dbmode batched $Q
