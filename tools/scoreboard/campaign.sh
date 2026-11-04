#!/usr/bin/env bash
# The final scoreboard campaign (docs/SCOREBOARD.md "Method").  Every cell: vanilla and dbcraft alternate (V D V D V D, run.py's --reps loop), and before every run the
# runner waits for the 1-minute load average to be at most 1.5 (--load-max) and records it.  Results are appended to $SCORE_OUT/results.jsonl.
#   usage: tools/scoreboard/cenv tools/scoreboard/campaign.sh PHASE...        PHASE = idle | walk | storm | misc | crowd | soak
# Needs: the cluster of tools/scoreboard/dbcraft.sh setup-db (cenv's ports), the gateway built, the vanilla jar.  SCORE_XMS/SCORE_XMX are vanilla's heap (this campaign: 1G / 2G).
set -u
cd "$(dirname "$0")/../.."
export SCORE_XMS=${SCORE_XMS:-1G} SCORE_XMX=${SCORE_XMX:-2G}
R="python3 tools/scoreboard/run.py"
G="--load-max 1.5 --quiet-wait 0 --reps ${REPS:-3} --hold ${HOLD:-60}"
log() { echo "$(date +%H:%M:%S) $*" | tee -a $SCORE_OUT/campaign.log; }
for phase in "$@"; do
  log "=== phase $phase"
  case $phase in
    idle)
      $R idle0 --n 0 $G --tag idle
      $R pop --n 50 --moving 0 $G --tag idle
      $R pop --n 200 --moving 0 $G --tag idle ;;
    walk)
      $R pop --n 50 --moving 1.0 --bound 500 $G --tag walk
      $R pop --n 200 --moving 1.0 --bound 500 $G --tag walk
      $R pop --n 200 --moving 0.2 --bound 500 $G --tag walk ;;
    storm)
      $R storm2 --n 50 --reps 3 --load-max 1.5 --quiet-wait 0 --tag storm
      $R storm2 --n 200 --reps 3 --load-max 1.5 --quiet-wait 0 --tag storm ;;
    misc)
      $R chunkload --vd 10 --reps 3 --load-max 1.5 --quiet-wait 0 --tag chunkload
      $R edit --n 0 --reps 3 --load-max 1.5 --quiet-wait 0 --tag edit
      $R edit --n 1 --reps 3 --load-max 1.5 --quiet-wait 0 --tag edit
      $R blocks --reps 3 --load-max 1.5 --quiet-wait 0 --tag blocks
      $R world10k --reps 3 --load-max 1.5 --quiet-wait 0 --tag world10k ;;
    crowd)
      $R pop --n 500 --moving 1.0 --spread 240 --bound 230 $G --ready-timeout 400 --tag crowd
      $R pop --n 500 --moving 1.0 --spread 800 --bound 780 $G --ready-timeout 400 --servers dbcraft --tag sparse
      $R pop --n 500 --moving 0.2 --spread 800 --bound 780 $G --ready-timeout 400 --servers dbcraft --tag sparse ;;
    soak)
      $R pop --n 200 --moving 1.0 --bound 500 --reps ${SOAK_REPS:-1} --hold 600 --load-max 1.5 --quiet-wait 0 --ready-timeout 300 --tag soak ;;
  esac
done
log "=== done $*"
