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

int Dbcnative_Init(Tcl_Interp *ip) {
    Tcl_CreateObjCommand(ip, "dbc::cipher", CipherCmd, NULL, NULL);
    Tcl_CreateObjCommand(ip, "dbc::encrypt", CryptCmd, (ClientData) 1, NULL);
    Tcl_CreateObjCommand(ip, "dbc::decrypt", CryptCmd, NULL, NULL);
    Tcl_CreateObjCommand(ip, "dbc::split", SplitCmd, NULL, NULL);
    Tcl_CreateObjCommand(ip, "dbc::tick", TickCmd, NULL, NULL);
    Tcl_CreateObjCommand(ip, "dbc::nop", NopCmd, NULL, NULL);
    return TCL_OK;
}
