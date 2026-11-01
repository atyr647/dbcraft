#!/usr/bin/env bash
# Build gwbench in several switch sets.  Output: bin/gwbench_<name>, objects in obj_<name>/ (gitignored).
set -euo pipefail
cd "$(dirname "$0")"; mkdir -p bin
declare -A SW=(
  [O2]="-O2"                       # default GNAT checks (range/index/etc.), no contracts
  [O2_nochecks]="-O2 -gnatp"       # all runtime checks suppressed
  [O2_gnata]="-O2 -gnata"          # assertions + Pre/Post contracts enabled (adacraft's switches, plus -O2)
  [adacraft_flags]="-gnata"        # exactly what adacraft's Makefile/gpr use: -gnata and NO optimisation
)
for k in "${!SW[@]}"; do
  mkdir -p "obj_$k"
  gnatmake -q -f -gnat2022 ${SW[$k]} -D "obj_$k" -Iadacraft -Isrc src/gwbench.adb -o "bin/gwbench_$k" 2> "obj_$k/build.log" \
    && echo "built $k (${SW[$k]})" || { echo "FAILED $k"; tail -20 "obj_$k/build.log"; }
done
