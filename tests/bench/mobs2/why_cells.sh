#!/usr/bin/env bash
# the cells of docs/WHY-MOBS-COST.md, one after the other, appended to docs/why-mobs-results.txt     usage: tests/bench/mobs2/why_cells.sh [CELL...]    env: PGHOST PGPORT PGUSER PGDATABASE
cd "$(dirname "$0")/../../.."
O=${OUT:-docs/why-mobs-results.txt}
W=tests/bench/mobs2/why.sh
cells=${*:-1 2 3}
for c in $cells; do
  case $c in
    1) $W "1-flat-view-2000" $O -v mobs=2000 -v where=view -v reset=1 ;;
    2) $W "2-flat-ring-2000" $O -v mobs=2000 -v where=ring -v reset=1 ;;
    3) $W "3-scatter2000-view-2000" $O -v mobs=2000 -v where=view -v reset=1 -v scatter=2000 ;;
    3a) $W "3a-scatter200-view-2000" $O -v mobs=2000 -v where=view -v reset=1 -v scatter=200 ;;
    3b) $W "3b-scatter20-view-2000" $O -v mobs=2000 -v where=view -v reset=1 -v scatter=20 ;;
    3c) $W "3c-scatter2000-ring-2000" $O -v mobs=2000 -v where=ring -v reset=1 -v scatter=2000 ;;
  esac
done
echo "DONE $cells" >> $O
