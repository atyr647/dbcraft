/*
 * dbcraft_set: the iteration order of fastutil's ShortOpenHashSet (8.5.18) in C, and the packet templates built from it.
 *
 * An OPTIONAL accelerator (docs/PERF-WORLD2.md "Cold fills"): sql/850's mc.shortset_order is a PL/pgSQL simulation of the class (about 1.5 us a position, 6 ms for a whole
 * section); the first fill of a new shape pays it.  This is the same simulation in C, line by line (key 0 in its own flag and first, table of 32 slots, HashCommon.mix =
 * h ^ (h >>> 16) of k * 0x9E3779B9, linear probing, rehash to twice the size when the size before an insertion has reached maxFill = 3/4 of the table, the old table
 * re-inserted from its last slot down, iteration from the last slot to the first) and tests/sql/962 requires it to give exactly the SQL result on random sequences.
 *
 *   shortset_order(int4[])     the keys in iteration order (keys 0 .. 65535; duplicates ignored as add() ignores them)
 *   fill_tpl(bytea)            the template (5 characters per entry) of a 'cells' bit map of 512 bytes: see sql/960 mc.sbu_build
 *   fill_tpl0(bytea)           the finished entries for the air state
 * Pure functions: no state, no I/O.
 */
#include "postgres.h"
#if __has_include("varatt.h")
#include "varatt.h"
#endif
#include "fmgr.h"
#include "utils/array.h"
#include "catalog/pg_type.h"
#include "utils/builtins.h"

#include <string.h>
#include <stdint.h>

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(dbs_shortset_order);
PG_FUNCTION_INFO_V1(dbs_fill_tpl);
PG_FUNCTION_INFO_V1(dbs_fill_tpl0);

static inline uint32_t
mix(uint32_t k)
{
    uint32_t h = k * 0x9E3779B9u;
    return h ^ (h >> 16);
}

/* the set: returns the number of keys written to out (capacity: n) */
static int
set_order(const int32 *keys, int n, int32 *out)
{
    uint32_t cap = 32, mask = 31, size = 0, maxfill = 24;
    int has_null = 0, c = 0;
    int32 *tab = palloc0(sizeof(int32) * cap);
    int i;

    for (i = 0; i < n; i++)
    {
        int32 k = keys[i];

        if (k == 0)
        {
            if (has_null)
                continue;
            has_null = 1;
        }
        else
        {
            uint32_t p = mix((uint32_t) k) & mask;
            int dup = 0;

            while (tab[p] != 0)
            {
                if (tab[p] == k + 1) { dup = 1; break; }
                p = (p + 1) & mask;
            }
            if (dup)
                continue;
            tab[p] = k + 1;
        }
        size++;
        if (size - 1 >= maxfill)                         /* add(): if (size++ >= maxFill) rehash(...) */
        {
            uint32_t ncap = cap * 2, nmask = ncap - 1, j;
            int32 *nt = palloc0(sizeof(int32) * ncap);

            for (j = cap; j > 0; j--)
            {
                int32 v = tab[j - 1];
                uint32_t p;

                if (v == 0)
                    continue;
                p = mix((uint32_t) (v - 1)) & nmask;
                while (nt[p] != 0)
                    p = (p + 1) & nmask;
                nt[p] = v;
            }
            pfree(tab);
            tab = nt; cap = ncap; mask = nmask; maxfill = ncap * 3 / 4;
        }
    }
    if (has_null)
        out[c++] = 0;
    for (i = (int) cap; i > 0; i--)
        if (tab[i - 1] != 0)
            out[c++] = tab[i - 1] - 1;
    pfree(tab);
    return c;
}

Datum
dbs_shortset_order(PG_FUNCTION_ARGS)
{
    ArrayType *a = PG_GETARG_ARRAYTYPE_P(0);
    int n, c;
    int32 *out;
    ArrayType *res;
    Datum *d;
    int i;

    if (ARR_NDIM(a) > 1 || ARR_HASNULL(a) || ARR_ELEMTYPE(a) != INT4OID)
        ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("shortset_order: a one-dimensional int4[] without nulls is required")));
    n = ARR_NDIM(a) == 0 ? 0 : ARR_DIMS(a)[0];
    for (i = 0; i < n; i++)
        if (((int32 *) ARR_DATA_PTR(a))[i] < 0 || ((int32 *) ARR_DATA_PTR(a))[i] > 65535)
            ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("shortset_order: keys must be in 0 .. 65535")));
    out = palloc(sizeof(int32) * (n + 1));
    c = n == 0 ? 0 : set_order((int32 *) ARR_DATA_PTR(a), n, out);
    d = palloc(sizeof(Datum) * (c + 1));
    for (i = 0; i < c; i++)
        d[i] = Int32GetDatum(out[i]);
    res = construct_array_builtin(d, c, INT4OID);
    PG_RETURN_ARRAYTYPE_P(res);
}

/* the positions of a 512-byte cells map in the order a /fill visits them (z, then y, then x), as vanilla indexes them: x << 8 | z << 4 | y */
static int
cells_positions(const uint8 *cells, int32 *pos)
{
    int n = 0, y, z, x;

    for (z = 0; z < 16; z++)
        for (y = 0; y < 16; y++)
            for (x = 0; x < 16; x++)
            {
                int bit = (y << 8) | (z << 4) | x;

                if ((cells[bit >> 3] >> (bit & 7)) & 1)
                    pos[n++] = (x << 8) | (z << 4) | y;
            }
    return n;
}

static text *
fill_tpl_common(bytea *cells, int air)
{
    static const char hx[] = "0123456789abcdef";
    int32 *pos = palloc(sizeof(int32) * 4096), *ord = palloc(sizeof(int32) * 4096);
    int n, c, i;
    char *buf, *w;
    text *res;

    if (VARSIZE_ANY_EXHDR(cells) != 512)
        ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("a cells bit map is 512 bytes")));
    n = cells_positions((const uint8 *) VARDATA_ANY(cells), pos);
    c = n == 0 ? 0 : set_order(pos, n, ord);
    buf = palloc(c * 5 + 1);
    w = buf;
    for (i = 0; i < c; i++)
    {
        int p = ord[i];

        if (air)
        {
            if (p < 128) { *w++ = hx[(p >> 4) & 15]; *w++ = hx[p & 15]; }
            else
            {
                int hi = p >> 7;
                *w++ = hx[8 + ((p >> 4) & 7)]; *w++ = hx[p & 15]; *w++ = hx[(hi >> 4) & 15]; *w++ = hx[hi & 15];
            }
        }
        else
        {
            *w++ = hx[8 + ((p >> 4) & 7)]; *w++ = hx[p & 15];
            *w++ = ((p >> 11) & 1) == 0 ? 'g' : 'h';
            *w++ = hx[(p >> 7) & 15];
            *w++ = 'z';
        }
    }
    res = cstring_to_text_with_len(buf, (int) (w - buf));
    pfree(buf); pfree(pos); pfree(ord);
    return res;
}

Datum
dbs_fill_tpl(PG_FUNCTION_ARGS)
{
    PG_RETURN_TEXT_P(fill_tpl_common(PG_GETARG_BYTEA_PP(0), 0));
}

Datum
dbs_fill_tpl0(PG_FUNCTION_ARGS)
{
    PG_RETURN_TEXT_P(fill_tpl_common(PG_GETARG_BYTEA_PP(0), 1));
}
