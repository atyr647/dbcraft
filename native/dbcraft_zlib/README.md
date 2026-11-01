# dbcraft_zlib

An **optional** PostgreSQL extension for dbcraft: pure deflate / Adler-32 / CRC-32 functions on `bytea`, using zlib and (when available) libdeflate.
The server works without it (compression then runs in SQL, about 30x slower with less than half the ratio). Evaluation, numbers and the adopt-or-skip criteria:
[`docs/NATIVE-DEFLATE.md`](../../docs/NATIVE-DEFLATE.md).

```
sudo apt install postgresql-server-dev-16 zlib1g-dev libdeflate-dev     # libdeflate is optional
make && sudo make install                                               # make WITH_LIBDEFLATE=no  for zlib only
tools/migrate.sh                                                        # sql/441_deflate_native.sql loads the extension and switches the chunk path to it
```

`CREATE EXTENSION dbcraft_zlib` needs a superuser. To go back to the SQL implementation: `select mc.select_deflate('sql');` (before `DROP EXTENSION`).
Functions are in schema `dbcraft_zlib`; see `dbcraft_zlib--1.0.sql` for the signatures. Input is capped at 16 MiB.
