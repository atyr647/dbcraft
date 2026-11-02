#!/usr/bin/env bash
# psql against the join-budget worker's own cluster (port 54755, database dbcraft unless JB_DB is set)
exec psql -X -h /tmp -p "${JB_PORT:-54755}" -U postgres "${JB_DB:-dbcraft}" "$@"
