#!/usr/bin/env bash
# Commit docs/final-campaign (the raw results of the running campaign) every few minutes, so that a container restart loses at most one cell.   usage: tools/scoreboard/checkpoint.sh [SECONDS=300] &
cd "$(dirname "$0")/../.."
while true; do
  sleep "${1:-300}"
  git add docs/final-campaign > /dev/null 2>&1
  if ! git diff --cached --quiet -- docs/final-campaign; then
    git commit -q -m $'Scoreboard campaign checkpoint: raw results so far\n\nCo-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01CKDduJaYNVZ3se3jM8Jr2F' -- docs/final-campaign > /dev/null 2>&1
  fi
done
