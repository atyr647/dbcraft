-- dbcraft_zlib 1.0.  Every function is pure: same input, same output, no I/O, no state visible from SQL.
-- Inputs larger than 16 MiB are refused (ERRCODE_PROGRAM_LIMIT_EXCEEDED).  Levels are 0 (stored) to 9.
\echo Use "CREATE EXTENSION dbcraft_zlib" to load this file. \quit

-- A complete zlib stream (RFC 1950: 2-byte header, deflate data, big-endian Adler-32).  backend: 'auto' (libdeflate when built in, else zlib), 'zlib', 'libdeflate'.
CREATE FUNCTION dbcraft_zlib.deflate_zlib(data bytea, level int DEFAULT 6, backend text DEFAULT 'auto') RETURNS bytea
    AS 'MODULE_PATHNAME', 'dbz_deflate_zlib' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- A complete raw deflate stream (RFC 1951, one final block, no wrapper).
CREATE FUNCTION dbcraft_zlib.deflate_raw(data bytea, level int DEFAULT 6, backend text DEFAULT 'auto') RETURNS bytea
    AS 'MODULE_PATHNAME', 'dbz_deflate_raw' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- A raw deflate FRAGMENT compressed independently (empty dictionary).  final = false ends with a sync flush (empty stored block 00 00 ff ff), so the output is
-- byte aligned and fragments can simply be concatenated; the last fragment is made with final = true.  zlib only (libdeflate cannot sync-flush).
CREATE FUNCTION dbcraft_zlib.deflate_fragment(data bytea, level int DEFAULT 6, final boolean DEFAULT false) RETURNS bytea
    AS 'MODULE_PATHNAME', 'dbz_deflate_fragment' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- Checksums as unsigned 32-bit values in a bigint.
CREATE FUNCTION dbcraft_zlib.adler32(data bytea) RETURNS bigint
    AS 'MODULE_PATHNAME', 'dbz_adler32' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION dbcraft_zlib.adler32_combine(adler1 bigint, adler2 bigint, len2 bigint) RETURNS bigint
    AS 'MODULE_PATHNAME', 'dbz_adler32_combine' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION dbcraft_zlib.crc32(data bytea) RETURNS bigint
    AS 'MODULE_PATHNAME', 'dbz_crc32' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- What this build contains, e.g. 'zlib 1.3 + libdeflate'.
CREATE FUNCTION dbcraft_zlib.backend() RETURNS text
    AS 'MODULE_PATHNAME', 'dbz_backend' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
