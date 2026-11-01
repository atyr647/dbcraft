/*
 * dbcraft_zlib: pure deflate / Adler-32 / CRC-32 functions for dbcraft.
 *
 * No state visible from SQL, no I/O, no logic: compressors are cached per backend only to avoid re-initialising ~300 KB of tables on every call, and every
 * call starts from a reset compressor, so the output depends on the input and the arguments alone.
 *
 * Limits: input at most DBZ_MAX_INPUT bytes; the output buffer is derived from the library's own worst-case bound and checked against the palloc limit.
 * zlib work is done in DBZ_SLICE slices with CHECK_FOR_INTERRUPTS() between them, so a cancel or statement_timeout is honoured within a few milliseconds.
 * libdeflate compresses in one call (it has no streaming API): a cancel is honoured after it returns (<= 16 MiB, i.e. at most a few hundred milliseconds).
 */
#include "postgres.h"
#if __has_include("varatt.h")
#include "varatt.h"                 /* PostgreSQL 16 moved the varlena macros here */
#endif
#include "fmgr.h"
#include "miscadmin.h"
#include "utils/builtins.h"
#include "utils/memutils.h"

#include <string.h>
#include <zlib.h>
#ifdef DBZ_HAVE_LIBDEFLATE
#include <libdeflate.h>
#endif

PG_MODULE_MAGIC;

#define DBZ_MAX_INPUT   ((size_t) 16 * 1024 * 1024)
#define DBZ_SLICE       ((size_t) 64 * 1024)
#define DBZ_CSUM_SLICE  ((size_t) 1024 * 1024)
#define DBZ_SLACK       64          /* room for the sync-flush marker, header, trailer */

enum { DBZ_ZLIB = 1, DBZ_LIBDEFLATE = 2 };

PG_FUNCTION_INFO_V1(dbz_deflate_zlib);
PG_FUNCTION_INFO_V1(dbz_deflate_raw);
PG_FUNCTION_INFO_V1(dbz_deflate_fragment);
PG_FUNCTION_INFO_V1(dbz_adler32);
PG_FUNCTION_INFO_V1(dbz_adler32_combine);
PG_FUNCTION_INFO_V1(dbz_crc32);
PG_FUNCTION_INFO_V1(dbz_backend);

/* ------------------------------------------------------------------------------------------ argument checks */

static int
check_level(int32 level)
{
    if (level < 0 || level > 9)
        ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                        errmsg("compression level must be between 0 and 9, got %d", level)));
    return (int) level;
}

static void
check_size(size_t n)
{
    if (n > DBZ_MAX_INPUT)
        ereport(ERROR, (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
                        errmsg("input of %zu bytes exceeds the dbcraft_zlib limit of %zu bytes", n, DBZ_MAX_INPUT)));
}

static int
parse_backend(text *t)
{
    char   *s = text_to_cstring(t);
    int     r = DBZ_ZLIB;

    if (strcmp(s, "auto") == 0)
    {
#ifdef DBZ_HAVE_LIBDEFLATE
        r = DBZ_LIBDEFLATE;
#endif
    }
    else if (strcmp(s, "zlib") == 0)
        r = DBZ_ZLIB;
    else if (strcmp(s, "libdeflate") == 0)
    {
#ifdef DBZ_HAVE_LIBDEFLATE
        r = DBZ_LIBDEFLATE;
#else
        ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                        errmsg("this build of dbcraft_zlib does not include libdeflate")));
#endif
    }
    else
        ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                        errmsg("unknown backend \"%s\" (use auto, zlib or libdeflate)", s)));
    pfree(s);
    return r;
}

static bytea *
alloc_result(size_t cap)
{
    if (cap > (size_t) (MaxAllocSize - VARHDRSZ))
        ereport(ERROR, (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED), errmsg("compressed output would be too large")));
    return (bytea *) palloc(VARHDRSZ + cap);
}

static bytea *
finish_result(bytea *res, size_t cap, size_t used)
{
    SET_VARSIZE(res, VARHDRSZ + used);
    if (cap - used > 65536)
        res = (bytea *) repalloc(res, VARHDRSZ + used);
    return res;
}

/* ------------------------------------------------------------------------------------------ zlib (cached, reset per call) */

typedef struct { z_stream strm; bool ready; } ZCache;
static ZCache zcache[2][10];                /* [raw][level] */

static z_stream *
zlib_stream(bool raw, int level)
{
    ZCache *c = &zcache[raw ? 1 : 0][level];
    int     rc;

    if (!c->ready)
    {
        memset(&c->strm, 0, sizeof(c->strm));
        rc = deflateInit2(&c->strm, level, Z_DEFLATED, raw ? -15 : 15, 8, Z_DEFAULT_STRATEGY);
        if (rc == Z_MEM_ERROR)
            ereport(ERROR, (errcode(ERRCODE_OUT_OF_MEMORY), errmsg("out of memory initialising zlib")));
        if (rc != Z_OK)
            ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("deflateInit2 failed: %d", rc)));
        c->ready = true;
    }
    else if (deflateReset(&c->strm) != Z_OK)
        ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("deflateReset failed")));
    return &c->strm;
}

/* Compress n bytes.  flush = Z_FINISH (a complete stream) or Z_SYNC_FLUSH (a byte-aligned fragment).  An empty input still makes one deflate() call. */
static bytea *
zlib_compress(const unsigned char *in, size_t n, int level, bool raw, int flush)
{
    z_stream   *s = zlib_stream(raw, level);
    size_t      cap = (size_t) deflateBound(s, (uLong) n) + DBZ_SLACK;
    bytea      *res = alloc_result(cap);
    size_t      done = 0;

    s->next_out = (Bytef *) VARDATA(res);
    s->avail_out = (uInt) cap;
    do
    {
        size_t  take = n - done < DBZ_SLICE ? n - done : DBZ_SLICE;
        bool    last = (done + take == n);
        int     rc;

        CHECK_FOR_INTERRUPTS();
        s->next_in = (Bytef *) (in + done);
        s->avail_in = (uInt) take;
        rc = deflate(s, last ? flush : Z_NO_FLUSH);
        if (rc == Z_STREAM_ERROR || (last && flush == Z_FINISH && rc != Z_STREAM_END) ||
            (last && flush != Z_FINISH && rc != Z_OK) || s->avail_in != 0)
            ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("deflate failed (%d)", rc)));
        done += take;
    } while (done < n);
    return finish_result(res, cap, cap - s->avail_out);
}

/* ------------------------------------------------------------------------------------------ libdeflate (cached compressors) */

#ifdef DBZ_HAVE_LIBDEFLATE
static struct libdeflate_compressor *ldcache[10];

static struct libdeflate_compressor *
ld_compressor(int level)
{
    if (ldcache[level] == NULL)
    {
        ldcache[level] = libdeflate_alloc_compressor(level);
        if (ldcache[level] == NULL)
            ereport(ERROR, (errcode(ERRCODE_OUT_OF_MEMORY), errmsg("out of memory initialising libdeflate")));
    }
    return ldcache[level];
}

static bytea *
ld_compress(const unsigned char *in, size_t n, int level, bool raw)
{
    struct libdeflate_compressor *c = ld_compressor(level);
    size_t  cap = raw ? libdeflate_deflate_compress_bound(c, n) : libdeflate_zlib_compress_bound(c, n);
    bytea  *res = alloc_result(cap);
    size_t  used;

    CHECK_FOR_INTERRUPTS();
    used = raw ? libdeflate_deflate_compress(c, in, n, VARDATA(res), cap)
               : libdeflate_zlib_compress(c, in, n, VARDATA(res), cap);
    if (used == 0)
        ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR), errmsg("libdeflate output exceeded its own bound")));
    return finish_result(res, cap, used);
}
#endif

/* ------------------------------------------------------------------------------------------ SQL functions */

static Datum
deflate_common(FunctionCallInfo fcinfo, bool raw)
{
    bytea  *data = PG_GETARG_BYTEA_PP(0);
    int     level = check_level(PG_GETARG_INT32(1));
    int     backend = parse_backend(PG_GETARG_TEXT_PP(2));
    size_t  n = VARSIZE_ANY_EXHDR(data);

    check_size(n);
#ifdef DBZ_HAVE_LIBDEFLATE
    if (backend == DBZ_LIBDEFLATE)
        PG_RETURN_BYTEA_P(ld_compress((const unsigned char *) VARDATA_ANY(data), n, level, raw));
#endif
    (void) backend;
    PG_RETURN_BYTEA_P(zlib_compress((const unsigned char *) VARDATA_ANY(data), n, level, raw, Z_FINISH));
}

Datum dbz_deflate_zlib(PG_FUNCTION_ARGS) { return deflate_common(fcinfo, false); }
Datum dbz_deflate_raw(PG_FUNCTION_ARGS)  { return deflate_common(fcinfo, true); }

Datum
dbz_deflate_fragment(PG_FUNCTION_ARGS)
{
    bytea  *data = PG_GETARG_BYTEA_PP(0);
    int     level = check_level(PG_GETARG_INT32(1));
    bool    final = PG_GETARG_BOOL(2);
    size_t  n = VARSIZE_ANY_EXHDR(data);

    check_size(n);
    PG_RETURN_BYTEA_P(zlib_compress((const unsigned char *) VARDATA_ANY(data), n, level, true, final ? Z_FINISH : Z_SYNC_FLUSH));
}

static uint32
adler_of(const unsigned char *p, size_t n)
{
    size_t  off = 0;
#ifdef DBZ_HAVE_LIBDEFLATE
    uint32  a = 1;
#else
    uLong   a = adler32(0L, Z_NULL, 0);
#endif

    while (off < n)
    {
        size_t take = n - off < DBZ_CSUM_SLICE ? n - off : DBZ_CSUM_SLICE;

        CHECK_FOR_INTERRUPTS();
#ifdef DBZ_HAVE_LIBDEFLATE
        a = libdeflate_adler32(a, p + off, take);
#else
        a = adler32_z(a, p + off, take);
#endif
        off += take;
    }
    return (uint32) a;
}

Datum
dbz_adler32(PG_FUNCTION_ARGS)
{
    bytea *data = PG_GETARG_BYTEA_PP(0);

    PG_RETURN_INT64((int64) adler_of((const unsigned char *) VARDATA_ANY(data), VARSIZE_ANY_EXHDR(data)));
}

Datum
dbz_crc32(PG_FUNCTION_ARGS)
{
    bytea          *data = PG_GETARG_BYTEA_PP(0);
    const unsigned char *p = (const unsigned char *) VARDATA_ANY(data);
    size_t          n = VARSIZE_ANY_EXHDR(data), off = 0;
    uLong           c = crc32(0L, Z_NULL, 0);

    while (off < n)
    {
        size_t take = n - off < DBZ_CSUM_SLICE ? n - off : DBZ_CSUM_SLICE;

        CHECK_FOR_INTERRUPTS();
        c = crc32_z(c, p + off, take);
        off += take;
    }
    PG_RETURN_INT64((int64) (uint32) c);
}

Datum
dbz_adler32_combine(PG_FUNCTION_ARGS)
{
    int64   a1 = PG_GETARG_INT64(0), a2 = PG_GETARG_INT64(1), len2 = PG_GETARG_INT64(2);

    if (a1 < 0 || a1 > 0xFFFFFFFFLL || a2 < 0 || a2 > 0xFFFFFFFFLL)
        ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE), errmsg("an Adler-32 value must be between 0 and 4294967295")));
    if (len2 < 0)
        ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("length must not be negative")));
    PG_RETURN_INT64((int64) (uint32) adler32_combine((uLong) a1, (uLong) a2, (z_off_t) len2));
}

Datum
dbz_backend(PG_FUNCTION_ARGS)
{
    char buf[128];

#ifdef DBZ_HAVE_LIBDEFLATE
    snprintf(buf, sizeof(buf), "zlib %s + libdeflate", zlibVersion());
#else
    snprintf(buf, sizeof(buf), "zlib %s", zlibVersion());
#endif
    PG_RETURN_TEXT_P(cstring_to_text(buf));
}
