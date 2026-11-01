# source me: points psql and the tools at the batch-experiment cluster
export DBCRAFT_PGDATA=${DBCRAFT_PGDATA:-/tmp/dbcraft-pg-batch} DBCRAFT_PGPORT=${DBCRAFT_PGPORT:-54422}
export PGHOST=/tmp PGPORT=$DBCRAFT_PGPORT PGUSER=postgres PGDATABASE=${PGDATABASE:-dbbench}
export DBCRAFT_CAPTURES=${DBCRAFT_CAPTURES:-/home/user/dbcraft/tests/fixtures/captured}
