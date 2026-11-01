/* dbcnative: the whole native core a Tcl gateway would need beyond Tcl itself (benchmark prototype, ~150 lines).
 *   dbc::cipher create key ?iv?      -> id   (AES-128-CFB8 encrypt+decrypt contexts, iv defaults to key as in Minecraft's login)
 *   dbc::cipher free id
 *   dbc::encrypt id bytes / dbc::decrypt id bytes   -> bytes (stateful, in-order stream)
 *   dbc::split bytes                 -> {consumed id1 body1 id2 body2 ...}   (whole frames only; a partial frame is left unconsumed)
 *   dbc::tick id inbound outbound    -> {consumed ciphertext id1 body1 ...}  (decrypt + split + encrypt in ONE call)
 *   dbc::nop                          -> (empty; measures the cost of calling a C command from Tcl)
 * No Minecraft knowledge beyond the VarInt length and id; the database decodes everything else. */
#include <tcl.h>
#include <string.h>
#include <openssl/evp.h>

#define MAXC 65536
static struct { EVP_CIPHER_CTX *enc, *dec; } ctab[MAXC];
static int cnext = 0;

static int newcipher(const unsigned char *key, const unsigned char *iv) {
    int id;
    for (id = 0; id < cnext && ctab[id].enc; id++) {}
    if (id >= MAXC) return -1;
    if (id == cnext) cnext++;
    ctab[id].enc = EVP_CIPHER_CTX_new(); ctab[id].dec = EVP_CIPHER_CTX_new();
    EVP_EncryptInit_ex(ctab[id].enc, EVP_aes_128_cfb8(), NULL, key, iv);
    EVP_DecryptInit_ex(ctab[id].dec, EVP_aes_128_cfb8(), NULL, key, iv);
    return id;
}

static int CipherCmd(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    if (objc >= 3 && !strcmp(Tcl_GetString(objv[1]), "create")) {
        int kl, il, id; const unsigned char *k = Tcl_GetByteArrayFromObj(objv[2], &kl), *iv = k;
        if (objc == 4) iv = Tcl_GetByteArrayFromObj(objv[3], &il); else il = kl;
        if (kl != 16 || il != 16) { Tcl_SetResult(ip, "key and iv must be 16 bytes", TCL_STATIC); return TCL_ERROR; }
        id = newcipher(k, iv);
        if (id < 0) { Tcl_SetResult(ip, "too many ciphers", TCL_STATIC); return TCL_ERROR; }
        Tcl_SetObjResult(ip, Tcl_NewIntObj(id)); return TCL_OK;
    }
    if (objc == 3 && !strcmp(Tcl_GetString(objv[1]), "free")) {
        int id; if (Tcl_GetIntFromObj(ip, objv[2], &id) != TCL_OK || id < 0 || id >= cnext || !ctab[id].enc) return TCL_ERROR;
        EVP_CIPHER_CTX_free(ctab[id].enc); EVP_CIPHER_CTX_free(ctab[id].dec); ctab[id].enc = ctab[id].dec = NULL; return TCL_OK;
    }
    Tcl_WrongNumArgs(ip, 1, objv, "create key ?iv? | free id"); return TCL_ERROR;
}

static Tcl_Obj *crypt1(int enc, int id, const unsigned char *in, int n) {
    Tcl_Obj *r = Tcl_NewObj(); int outl = 0;
    unsigned char *o = Tcl_SetByteArrayLength(r, n);
    if (enc) EVP_EncryptUpdate(ctab[id].enc, o, &outl, in, n); else EVP_DecryptUpdate(ctab[id].dec, o, &outl, in, n);
    return r;
}
static int CryptCmd(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    int id, n; const unsigned char *in;
    if (objc != 3) { Tcl_WrongNumArgs(ip, 1, objv, "id bytes"); return TCL_ERROR; }
    if (Tcl_GetIntFromObj(ip, objv[1], &id) != TCL_OK || id < 0 || id >= cnext || !ctab[id].enc) { Tcl_SetResult(ip, "bad cipher id", TCL_STATIC); return TCL_ERROR; }
    in = Tcl_GetByteArrayFromObj(objv[2], &n);
    Tcl_SetObjResult(ip, crypt1(cd != NULL, id, in, n)); return TCL_OK;
}

/* VarInt at p (limit e). Returns bytes used, 0 if incomplete, -1 if longer than 5 bytes. */
static int varint(const unsigned char *p, const unsigned char *e, unsigned *v) {
    unsigned r = 0; int i;
    for (i = 0; i < 5; i++) { if (p + i >= e) return 0; r |= (unsigned)(p[i] & 0x7f) << (7 * i); if (!(p[i] & 0x80)) { *v = r; return i + 1; } }
    return -1;
}
static int split1(Tcl_Interp *ip, const unsigned char *b, int n, Tcl_Obj *res) {
    const unsigned char *p = b, *e = b + n;
    for (;;) {
        unsigned len, id; int a, c;
        a = varint(p, e, &len); if (a < 0 || (a > 3)) goto bad; if (a == 0) break;
        if (len == 0 || len > 2097151) goto bad;
        if ((unsigned)(e - p - a) < len) break;
        c = varint(p + a, p + a + len, &id); if (c <= 0) goto bad;
        Tcl_ListObjAppendElement(ip, res, Tcl_NewIntObj((int) id));
        Tcl_ListObjAppendElement(ip, res, Tcl_NewByteArrayObj(p + a + c, (int) len - c));
        p += a + len;
    }
    return (int)(p - b);
bad:
    Tcl_SetResult(ip, "bad frame", TCL_STATIC); return -1;
}
static int SplitCmd(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    int n, used; const unsigned char *b; Tcl_Obj *res;
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(ip, 1, objv, "bytes"); return TCL_ERROR; }
    b = Tcl_GetByteArrayFromObj(objv[1], &n);
    res = Tcl_NewListObj(0, NULL); Tcl_ListObjAppendElement(ip, res, Tcl_NewIntObj(0));
    used = split1(ip, b, n, res); if (used < 0) { Tcl_DecrRefCount(res); return TCL_ERROR; }
    { Tcl_Obj *u = Tcl_NewIntObj(used); Tcl_ListObjReplace(ip, res, 0, 1, 1, &u); }
    Tcl_SetObjResult(ip, res); return TCL_OK;
}
static int TickCmd(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    int id, n, m, used; const unsigned char *in, *out; Tcl_Obj *res, *plain;
    (void) cd;
    if (objc != 4) { Tcl_WrongNumArgs(ip, 1, objv, "id inbound outbound"); return TCL_ERROR; }
    if (Tcl_GetIntFromObj(ip, objv[1], &id) != TCL_OK || id < 0 || id >= cnext || !ctab[id].enc) { Tcl_SetResult(ip, "bad cipher id", TCL_STATIC); return TCL_ERROR; }
    in = Tcl_GetByteArrayFromObj(objv[2], &n); out = Tcl_GetByteArrayFromObj(objv[3], &m);
    plain = crypt1(0, id, in, n);
    res = Tcl_NewListObj(0, NULL); Tcl_ListObjAppendElement(ip, res, Tcl_NewIntObj(0));
    Tcl_ListObjAppendElement(ip, res, crypt1(1, id, out, m));
    { int pn; const unsigned char *pb = Tcl_GetByteArrayFromObj(plain, &pn);
      used = split1(ip, pb, pn, res); Tcl_DecrRefCount(plain); }
    if (used < 0) { Tcl_DecrRefCount(res); return TCL_ERROR; }
    { Tcl_Obj *u = Tcl_NewIntObj(used); Tcl_ListObjReplace(ip, res, 0, 1, 1, &u); }
    Tcl_SetObjResult(ip, res); return TCL_OK;
}
static int NopCmd(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) { (void) cd; (void) ip; (void) objc; (void) objv; return TCL_OK; }


/* ---- AES-NI CFB8 with its own state: decrypt 8 positions at a time (ciphertext is known, so positions are independent), and
 * encrypt many connections' streams in lockstep (one stream is serial, several are independent).  Same wire result as the EVP ones above. */
#include <wmmintrin.h>
#include <smmintrin.h>
#include <stdlib.h>
typedef struct { __m128i rk[11]; unsigned char hist[16]; __m128i reg; int used; } Ni;
static Ni *nitab[MAXC];
static __m128i kexp(__m128i k, __m128i g) {
    g = _mm_shuffle_epi32(g, 0xff);
    k = _mm_xor_si128(k, _mm_slli_si128(k, 4)); k = _mm_xor_si128(k, _mm_slli_si128(k, 4)); k = _mm_xor_si128(k, _mm_slli_si128(k, 4));
    return _mm_xor_si128(k, g);
}
static void ni_init(Ni *n, const unsigned char *key, const unsigned char *iv) {
    __m128i k = _mm_loadu_si128((const __m128i *) key);
    n->rk[0] = k;
    n->rk[1] = k = kexp(k, _mm_aeskeygenassist_si128(k, 0x01)); n->rk[2] = k = kexp(k, _mm_aeskeygenassist_si128(k, 0x02));
    n->rk[3] = k = kexp(k, _mm_aeskeygenassist_si128(k, 0x04)); n->rk[4] = k = kexp(k, _mm_aeskeygenassist_si128(k, 0x08));
    n->rk[5] = k = kexp(k, _mm_aeskeygenassist_si128(k, 0x10)); n->rk[6] = k = kexp(k, _mm_aeskeygenassist_si128(k, 0x20));
    n->rk[7] = k = kexp(k, _mm_aeskeygenassist_si128(k, 0x40)); n->rk[8] = k = kexp(k, _mm_aeskeygenassist_si128(k, 0x80));
    n->rk[9] = k = kexp(k, _mm_aeskeygenassist_si128(k, 0x1b)); n->rk[10] = kexp(k, _mm_aeskeygenassist_si128(k, 0x36));
    memcpy(n->hist, iv, 16); n->reg = _mm_loadu_si128((const __m128i *) iv);
}
static inline unsigned char ni_ks1(const Ni *n, __m128i x) {
    int r; x = _mm_xor_si128(x, n->rk[0]);
    for (r = 1; r < 10; r++) x = _mm_aesenc_si128(x, n->rk[r]);
    return (unsigned char) _mm_cvtsi128_si32(_mm_aesenclast_si128(x, n->rk[10]));
}
static void ni_enc_serial(Ni *n, const unsigned char *in, unsigned char *out, int len) {
    int i; __m128i reg = n->reg;
    for (i = 0; i < len; i++) {
        unsigned char c = in[i] ^ ni_ks1(n, reg); out[i] = c;
        reg = _mm_insert_epi8(_mm_srli_si128(reg, 1), c, 15);
    }
    n->reg = reg;
}
static void ni_dec(Ni *n, const unsigned char *in, unsigned char *out, int len) {
    unsigned char stackbuf[2048 + 16], *buf = len <= 2048 ? stackbuf : malloc(len + 16);
    int i, j, r;
    memcpy(buf, n->hist, 16); memcpy(buf + 16, in, len);
    for (i = 0; i + 8 <= len; i += 8) {
        __m128i x[8];
        for (j = 0; j < 8; j++) x[j] = _mm_xor_si128(_mm_loadu_si128((const __m128i *)(buf + i + j)), n->rk[0]);
        for (r = 1; r < 10; r++) for (j = 0; j < 8; j++) x[j] = _mm_aesenc_si128(x[j], n->rk[r]);
        for (j = 0; j < 8; j++) out[i + j] = in[i + j] ^ (unsigned char) _mm_cvtsi128_si32(_mm_aesenclast_si128(x[j], n->rk[10]));
    }
    for (; i < len; i++) out[i] = in[i] ^ ni_ks1(n, _mm_loadu_si128((const __m128i *)(buf + i)));
    memcpy(n->hist, buf + len, 16);
    if (buf != stackbuf) free(buf);
}
/* up to 8 lanes in lockstep for the common length, then each lane's remainder serially */
static void ni_enc_lanes(Ni **ns, const unsigned char **in, unsigned char **out, const int *len, int k) {
    int i, j, r, L = len[0];
    __m128i reg[8], x[8];
    for (j = 0; j < k; j++) { reg[j] = ns[j]->reg; if (len[j] < L) L = len[j]; }
    for (i = 0; i < L; i++) {
        for (j = 0; j < k; j++) x[j] = _mm_xor_si128(reg[j], ns[j]->rk[0]);
        for (r = 1; r < 10; r++) for (j = 0; j < k; j++) x[j] = _mm_aesenc_si128(x[j], ns[j]->rk[r]);
        for (j = 0; j < k; j++) {
            unsigned char c = in[j][i] ^ (unsigned char) _mm_cvtsi128_si32(_mm_aesenclast_si128(x[j], ns[j]->rk[10]));
            out[j][i] = c; reg[j] = _mm_insert_epi8(_mm_srli_si128(reg[j], 1), c, 15);
        }
    }
    for (j = 0; j < k; j++) { ns[j]->reg = reg[j]; if (len[j] > L) ni_enc_serial(ns[j], in[j] + L, out[j] + L, len[j] - L); }
}
static int NiCmd(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {   /* cd: 0 create, 1 enc, 2 dec, 3 free */
    long op = (long) cd; int id, n; const unsigned char *in; Tcl_Obj *r; unsigned char *o;
    if (op == 0) {
        int kl, il; const unsigned char *k, *iv;
        if (objc < 2 || objc > 3) { Tcl_WrongNumArgs(ip, 1, objv, "key ?iv?"); return TCL_ERROR; }
        k = Tcl_GetByteArrayFromObj(objv[1], &kl); iv = k; il = kl; if (objc == 3) iv = Tcl_GetByteArrayFromObj(objv[2], &il);
        if (kl != 16 || il != 16) { Tcl_SetResult(ip, "key and iv must be 16 bytes", TCL_STATIC); return TCL_ERROR; }
        for (id = 0; id < MAXC && nitab[id]; id++) {}
        if (id >= MAXC) { Tcl_SetResult(ip, "too many ciphers", TCL_STATIC); return TCL_ERROR; }
        nitab[id] = aligned_alloc(16, (sizeof(Ni) + 15) & ~15UL); ni_init(nitab[id], k, iv);
        Tcl_SetObjResult(ip, Tcl_NewIntObj(id)); return TCL_OK;
    }
    if (op == 3) { if (objc != 2 || Tcl_GetIntFromObj(ip, objv[1], &id) != TCL_OK || id < 0 || id >= MAXC || !nitab[id]) return TCL_ERROR; free(nitab[id]); nitab[id] = NULL; return TCL_OK; }
    if (objc != 3 || Tcl_GetIntFromObj(ip, objv[1], &id) != TCL_OK || id < 0 || id >= MAXC || !nitab[id]) { Tcl_SetResult(ip, "bad cipher id", TCL_STATIC); return TCL_ERROR; }
    in = Tcl_GetByteArrayFromObj(objv[2], &n); r = Tcl_NewObj(); o = Tcl_SetByteArrayLength(r, n);
    if (op == 1) ni_enc_serial(nitab[id], in, o, n); else ni_dec(nitab[id], in, o, n);
    Tcl_SetObjResult(ip, r); return TCL_OK;
}
static int NiBatchCmd(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {   /* dbc::nienc_batch ids blobs -> list of ciphertexts */
    int cnt, bc, g, j; Tcl_Obj **ids, **blobs, *res; (void) cd;
    if (objc != 3) { Tcl_WrongNumArgs(ip, 1, objv, "ids blobs"); return TCL_ERROR; }
    if (Tcl_ListObjGetElements(ip, objv[1], &cnt, &ids) != TCL_OK || Tcl_ListObjGetElements(ip, objv[2], &bc, &blobs) != TCL_OK) return TCL_ERROR;
    if (cnt != bc) { Tcl_SetResult(ip, "ids and blobs differ in length", TCL_STATIC); return TCL_ERROR; }
    res = Tcl_NewListObj(0, NULL);
    for (g = 0; g < cnt; g += 8) {
        Ni *ns[8]; const unsigned char *in[8]; unsigned char *out[8]; int len[8], k = cnt - g < 8 ? cnt - g : 8; Tcl_Obj *ro[8];
        for (j = 0; j < k; j++) {
            int id; if (Tcl_GetIntFromObj(ip, ids[g + j], &id) != TCL_OK || id < 0 || id >= MAXC || !nitab[id]) { Tcl_SetResult(ip, "bad cipher id", TCL_STATIC); Tcl_DecrRefCount(res); return TCL_ERROR; }
            ns[j] = nitab[id]; in[j] = Tcl_GetByteArrayFromObj(blobs[g + j], &len[j]);
            ro[j] = Tcl_NewObj(); out[j] = Tcl_SetByteArrayLength(ro[j], len[j]);
        }
        ni_enc_lanes(ns, in, out, len, k);
        for (j = 0; j < k; j++) Tcl_ListObjAppendElement(ip, res, ro[j]);
    }
    Tcl_SetObjResult(ip, res); return TCL_OK;
}

int Dbcnative_Init(Tcl_Interp *ip) {
    Tcl_CreateObjCommand(ip, "dbc::nicipher", NiCmd, (ClientData) 0, NULL);
    Tcl_CreateObjCommand(ip, "dbc::nienc", NiCmd, (ClientData) 1, NULL);
    Tcl_CreateObjCommand(ip, "dbc::nidec", NiCmd, (ClientData) 2, NULL);
    Tcl_CreateObjCommand(ip, "dbc::nifree", NiCmd, (ClientData) 3, NULL);
    Tcl_CreateObjCommand(ip, "dbc::nienc_batch", NiBatchCmd, NULL, NULL);
    Tcl_CreateObjCommand(ip, "dbc::cipher", CipherCmd, NULL, NULL);
    Tcl_CreateObjCommand(ip, "dbc::encrypt", CryptCmd, (ClientData) 1, NULL);
    Tcl_CreateObjCommand(ip, "dbc::decrypt", CryptCmd, NULL, NULL);
    Tcl_CreateObjCommand(ip, "dbc::split", SplitCmd, NULL, NULL);
    Tcl_CreateObjCommand(ip, "dbc::tick", TickCmd, NULL, NULL);
    Tcl_CreateObjCommand(ip, "dbc::nop", NopCmd, NULL, NULL);
    return TCL_OK;
}
