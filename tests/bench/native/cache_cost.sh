#!/usr/bin/env bash
# Resident memory a backend gains the first time it uses one compressor (backend, level, mode); each case runs in a fresh session.
#   PGHOST=/tmp PGPORT=54433 PGUSER=postgres PGDATABASE=dbcraft_zlib tests/bench/native/cache_cost.sh
set -euo pipefail
rss() { echo "(regexp_match(pg_read_file('/proc/self/status'), 'VmRSS:\s+(\d+)'))[1]::int"; }
run() {   # label, expression using the 51 KB payload p
  psql -X -q -At -c "do \$\$ declare p bytea; a int; b int; begin select payload into p from bench.real_pk where id = 1; select $(rss) into a; perform octet_length($2); select $(rss) into b; raise notice '%', rpad('$1', 34) || (b - a) || ' kB'; end \$\$" 2>&1 | sed 's/^psql:.*NOTICE:  //; s/^NOTICE:  //'
}
run "zlib L1 (zlib wrapper)"        "dbcraft_zlib.deflate_zlib(p, 1, 'zlib')"
run "zlib L6 (zlib wrapper)"        "dbcraft_zlib.deflate_zlib(p, 6, 'zlib')"
run "zlib L9 (zlib wrapper)"        "dbcraft_zlib.deflate_zlib(p, 9, 'zlib')"
run "zlib L6 raw / fragment"        "dbcraft_zlib.deflate_fragment(p, 6, false)"
run "libdeflate L1"                 "dbcraft_zlib.deflate_zlib(p, 1, 'libdeflate')"
run "libdeflate L6"                 "dbcraft_zlib.deflate_zlib(p, 6, 'libdeflate')"
run "libdeflate L9"                 "dbcraft_zlib.deflate_zlib(p, 9, 'libdeflate')"
run "adler32 (no cache; library load)" "int8send(dbcraft_zlib.adler32(p))"
