#!/usr/bin/env bash
# The order of the cells of docs/PERF-STORM-MEASURED.md (alternating before / after, resumable: a cell already in the results file is skipped).
cd "$(dirname "$0")/../.."
S=tools/scoreboard/storm_measured.sh
$S setup
$S cell before 50 0; $S cell after 50 0; $S cell before 50 1; $S cell after 50 1
$S cell before 200 0; $S cell after 200 0; $S cell before 200 1; $S cell after 200 1
echo CHAIN DONE
