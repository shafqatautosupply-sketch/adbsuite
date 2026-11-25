#include "spake2.h"
#include <stdlib.h>
#include <string.h>
#include <openssl/bn.h>
#include <openssl/evp.h>
#include <openssl/rand.h>

/* ---- edwards25519 arithmetic (extended coordinates, a = -1) ------------- */
typedef struct { BIGNUM *X, *Y, *Z, *T; } pt;

static BIGNUM *g_p, *g_d, *g_d2, *g_l;
static pt g_B, g_M, g_N;
static int g_init;

static const uint8_t k_base[32] = {0x58,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,
  0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66,0x66};
/* BoringSSL's SPAKE2 points (crypto/curve25519/spake25519.cc) */
static const uint8_t k_M[32] = {0x5a,0xda,0x7e,0x4b,0xf6,0xdd,0xd9,0xad,0xb6,0x62,0x6d,0x32,0x13,0x1c,0x6b,0x5c,
  0x51,0xa1,0xe3,0x47,0xa3,0x47,0x8f,0x53,0xcf,0xcf,0x44,0x1b,0x88,0xee,0xd1,0x2e};
static const uint8_t k_N[32] = {0x10,0xe3,0xdf,0x0a,0xe3,0x7d,0x8e,0x7a,0x99,0xb5,0xfe,0x74,0xb4,0x46,0x72,0x10,
  0x3d,0xbd,0xdc,0xbd,0x06,0xaf,0x68,0x0d,0x71,0x32,0x9a,0x11,0x69,0x3b,0xc7,0x78};

static int pt_alloc(pt *p) {
    p->X = BN_new(); p->Y = BN_new(); p->Z = BN_new(); p->T = BN_new();
    return p->X && p->Y && p->Z && p->T;
}
static void pt_free(pt *p) { BN_free(p->X); BN_free(p->Y); BN_free(p->Z); BN_free(p->T); }
static void pt_identity(pt *p) { BN_zero(p->X); BN_one(p->Y); BN_one(p->Z); BN_zero(p->T); }
static int pt_copy(pt *r, const pt *a) {
    return BN_copy(r->X, a->X) && BN_copy(r->Y, a->Y) && BN_copy(r->Z, a->Z) && BN_copy(r->T, a->T);
}

static int pt_add(pt *r, const pt *a, const pt *b, BN_CTX *c) {
    int ok = 0;
    BN_CTX_start(c);
    BIGNUM *A = BN_CTX_get(c), *B = BN_CTX_get(c), *C = BN_CTX_get(c), *D = BN_CTX_get(c),
           *E = BN_CTX_get(c), *F = BN_CTX_get(c), *G = BN_CTX_get(c), *H = BN_CTX_get(c),
           *t1 = BN_CTX_get(c), *t2 = BN_CTX_get(c);
    if (!t2) goto end;
    if (!BN_mod_sub(t1, a->Y, a->X, g_p, c) || !BN_mod_sub(t2, b->Y, b->X, g_p, c) ||
        !BN_mod_mul(A, t1, t2, g_p, c)) goto end;
    if (!BN_mod_add(t1, a->Y, a->X, g_p, c) || !BN_mod_add(t2, b->Y, b->X, g_p, c) ||
        !BN_mod_mul(B, t1, t2, g_p, c)) goto end;
    if (!BN_mod_mul(t1, a->T, b->T, g_p, c) || !BN_mod_mul(C, t1, g_d2, g_p, c)) goto end;
    if (!BN_mod_mul(t1, a->Z, b->Z, g_p, c) || !BN_mod_add(D, t1, t1, g_p, c)) goto end;
    if (!BN_mod_sub(E, B, A, g_p, c) || !BN_mod_sub(F, D, C, g_p, c) ||
        !BN_mod_add(G, D, C, g_p, c) || !BN_mod_add(H, B, A, g_p, c)) goto end;
    if (!BN_mod_mul(r->X, E, F, g_p, c) || !BN_mod_mul(r->Y, G, H, g_p, c) ||
        !BN_mod_mul(r->T, E, H, g_p, c) || !BN_mod_mul(r->Z, F, G, g_p, c)) goto end;
    ok = 1;
end:
    BN_CTX_end(c);
    return ok;
}

static int pt_neg(pt *r, const pt *a, BN_CTX *c) {
    if (!pt_copy(r, a)) return 0;
    if (!BN_is_zero(r->X) && !BN_mod_sub(r->X, g_p, r->X, g_p, c)) return 0;
    if (!BN_is_zero(r->T) && !BN_mod_sub(r->T, g_p, r->T, g_p, c)) return 0;
    return 1;
}

/* r = k * a, k is a non-negative integer (not reduced) */
static int pt_mul(pt *r, const BIGNUM *k, const pt *a, BN_CTX *c) {
    pt acc, base;
    int ok = 0, i;
    if (!pt_alloc(&acc) || !pt_alloc(&base)) goto end;
    pt_identity(&acc);
    if (!pt_copy(&base, a)) goto end;
    for (i = BN_num_bits(k) - 1; i >= 0; i--) {
        if (!pt_add(&acc, &acc, &acc, c)) goto end;
        if (BN_is_bit_set(k, i) && !pt_add(&acc, &acc, &base, c)) goto end;
    }
    ok = pt_copy(r, &acc);
end:
    pt_free(&acc); pt_free(&base);
    return ok;
}

static int pt_encode(uint8_t out[32], const pt *a, BN_CTX *c) {
    int ok = 0;
    BN_CTX_start(c);
    BIGNUM *zi = BN_CTX_get(c), *x = BN_CTX_get(c), *y = BN_CTX_get(c);
    if (!y || !BN_mod_inverse(zi, a->Z, g_p, c)) goto end;
    if (!BN_mod_mul(x, a->X, zi, g_p, c) || !BN_mod_mul(y, a->Y, zi, g_p, c)) goto end;
    if (BN_bn2lebinpad(y, out, 32) != 32) goto end;
    if (BN_is_odd(x)) out[31] |= 0x80;
    ok = 1;
end:
    BN_CTX_end(c);
    return ok;
}

static int pt_decode(pt *r, const uint8_t in[32], BN_CTX *c) {
    int ok = 0, sign = in[31] >> 7;
    uint8_t buf[32];
    BN_CTX_start(c);
    BIGNUM *y = BN_CTX_get(c), *u = BN_CTX_get(c), *v = BN_CTX_get(c), *x = BN_CTX_get(c),
           *t = BN_CTX_get(c), *one = BN_CTX_get(c);
    if (!one) goto end;
    memcpy(buf, in, 32); buf[31] &= 0x7f;
    if (!BN_lebin2bn(buf, 32, y) || BN_cmp(y, g_p) >= 0) goto end;
    BN_one(one);
    /* x^2 = (y^2-1)/(d*y^2+1) */
    if (!BN_mod_sqr(t, y, g_p, c) || !BN_mod_sub(u, t, one, g_p, c) ||
        !BN_mod_mul(v, t, g_d, g_p, c) || !BN_mod_add(v, v, one, g_p, c) ||
        !BN_mod_inverse(v, v, g_p, c) || !BN_mod_mul(t, u, v, g_p, c)) goto end;
    if (BN_is_zero(t)) { BN_zero(x); if (sign) goto end; }
    else if (!BN_mod_sqrt(x, t, g_p, c)) { goto end; }
    if (BN_is_odd(x) != sign && !BN_is_zero(x) && !BN_mod_sub(x, g_p, x, g_p, c)) goto end;
    BN_copy(r->X, x); BN_copy(r->Y, y); BN_one(r->Z);
    if (!BN_mod_mul(r->T, x, y, g_p, c)) goto end;
    ok = 1;
end:
    BN_CTX_end(c);
    return ok;
}

static int g_setup(BN_CTX *c) {
    if (g_init) return 1;
    BIGNUM *t = BN_new(), *n = BN_new(), *dd = BN_new();
    int ok = 0;
    g_p = BN_new(); g_d = BN_new(); g_d2 = BN_new(); g_l = NULL;
    if (!t || !n || !dd || !g_p || !g_d || !g_d2) goto end;
    BN_one(g_p); BN_lshift(g_p, g_p, 255); BN_sub_word(g_p, 19);
    /* d = -121665 / 121666 */
    BN_set_word(n, 121665); BN_set_word(dd, 121666);
    if (!BN_mod_inverse(dd, dd, g_p, c) || !BN_mod_mul(t, n, dd, g_p, c) ||
        !BN_mod_sub(g_d, g_p, t, g_p, c) || !BN_mod_add(g_d2, g_d, g_d, g_p, c)) goto end;
    if (!BN_hex2bn(&g_l, "1000000000000000000000000000000014DEF9DEA2F79CD65812631A5CF5D3ED")) goto end;
    if (!pt_alloc(&g_B) || !pt_alloc(&g_M) || !pt_alloc(&g_N)) goto end;
    if (!pt_decode(&g_B, k_base, c) || !pt_decode(&g_M, k_M, c) || !pt_decode(&g_N, k_N, c)) goto end;
    g_init = ok = 1;
end:
    BN_free(t); BN_free(n); BN_free(dd);
    return ok;
}

/* ---- SPAKE2 ------------------------------------------------------------- */
struct spake2_ctx {
    spake2_role role;
    uint8_t *my_name, *their_name;
    size_t my_len, their_len;
    BIGNUM *priv, *pw_scalar;
    uint8_t my_msg[32];
    uint8_t pw_hash[64];
    int state; /* 0 init, 1 generated */
    BN_CTX *bc;
};

spake2_ctx *spake2_new(spake2_role role, const uint8_t *mn, size_t ml, const uint8_t *tn, size_t tl) {
    spake2_ctx *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->bc = BN_CTX_new();
    c->role = role;
    c->my_name = malloc(ml ? ml : 1); c->their_name = malloc(tl ? tl : 1);
    if (!c->bc || !c->my_name || !c->their_name || !g_setup(c->bc)) { spake2_free(c); return NULL; }
    memcpy(c->my_name, mn, ml); memcpy(c->their_name, tn, tl);
    c->my_len = ml; c->their_len = tl;
    return c;
}

void spake2_free(spake2_ctx *c) {
    if (!c) return;
    BN_clear_free(c->priv); BN_clear_free(c->pw_scalar);
    free(c->my_name); free(c->their_name);
    BN_CTX_free(c->bc);
    OPENSSL_cleanse(c->pw_hash, sizeof(c->pw_hash));
    free(c);
}

static int sha512_multi(uint8_t out[64], const uint8_t *data, size_t len) {
    unsigned int n = 64;
    return EVP_Digest(data, len, out, &n, EVP_sha512(), NULL);
}

int spake2_generate(spake2_ctx *c, uint8_t out[32], const uint8_t *pw, size_t pwlen) {
    int ok = 0, i;
    uint8_t rnd[64];
    BIGNUM *x = NULL, *w = NULL, *t = NULL;
    pt P, mask;
    if (c->state != 0) return 0;
    if (!pt_alloc(&P) || !pt_alloc(&mask)) goto end;
    x = BN_new(); w = BN_new(); t = BN_new();
    if (!x || !w || !t) goto end;
    /* private = (random mod l) * 8 */
    if (RAND_bytes(rnd, 64) != 1 || !BN_lebin2bn(rnd, 64, x) || !BN_nnmod(x, x, g_l, c->bc) ||
        !BN_lshift(x, x, 3)) goto end;
    c->priv = BN_dup(x);
    if (!pt_mul(&P, x, &g_B, c->bc)) goto end;
    /* password scalar */
    if (!sha512_multi(c->pw_hash, pw, pwlen)) goto end;
    if (!BN_lebin2bn(c->pw_hash, 64, w) || !BN_nnmod(w, w, g_l, c->bc)) goto end;
    /* BoringSSL "password scalar hack": make the scalar a multiple of 8 */
    for (i = 0; i < 3; i++) {
        if (BN_is_bit_set(w, i)) {
            if (!BN_copy(t, g_l) || !BN_lshift(t, t, i) || !BN_add(w, w, t)) goto end;
        }
    }
    c->pw_scalar = BN_dup(w);
    if (!pt_mul(&mask, w, c->role == SPAKE2_ALICE ? &g_M : &g_N, c->bc)) goto end;
    if (!pt_add(&P, &P, &mask, c->bc) || !pt_encode(c->my_msg, &P, c->bc)) goto end;
    memcpy(out, c->my_msg, 32);
    c->state = 1;
    ok = 1;
end:
    pt_free(&P); pt_free(&mask);
    BN_clear_free(x); BN_clear_free(w); BN_free(t);
    OPENSSL_cleanse(rnd, sizeof(rnd));
    return ok;
}

static int upd_len(EVP_MD_CTX *m, const uint8_t *d, size_t len) {
    uint8_t le[8]; int i; size_t l = len;
    for (i = 0; i < 8; i++) { le[i] = l & 0xff; l >>= 8; }
    return EVP_DigestUpdate(m, le, 8) && EVP_DigestUpdate(m, d, len);
}

int spake2_process(spake2_ctx *c, uint8_t key[64], const uint8_t *their, size_t tlen) {
    int ok = 0;
    pt Q, mask, dh;
    uint8_t dhenc[32];
    unsigned int kl = 64;
    EVP_MD_CTX *m = NULL;
    if (c->state != 1 || tlen != 32) return 0;
    if (!pt_alloc(&Q) || !pt_alloc(&mask) || !pt_alloc(&dh)) goto end;
    if (!pt_decode(&Q, their, c->bc)) goto end;
    if (!pt_mul(&mask, c->pw_scalar, c->role == SPAKE2_ALICE ? &g_N : &g_M, c->bc) ||
        !pt_neg(&mask, &mask, c->bc) || !pt_add(&Q, &Q, &mask, c->bc)) goto end;
    if (!pt_mul(&dh, c->priv, &Q, c->bc) || !pt_encode(dhenc, &dh, c->bc)) goto end;
    m = EVP_MD_CTX_new();
    if (!m || !EVP_DigestInit_ex(m, EVP_sha512(), NULL)) goto end;
    if (c->role == SPAKE2_ALICE) {
        if (!upd_len(m, c->my_name, c->my_len) || !upd_len(m, c->their_name, c->their_len) ||
            !upd_len(m, c->my_msg, 32) || !upd_len(m, their, 32)) goto end;
    } else {
        if (!upd_len(m, c->their_name, c->their_len) || !upd_len(m, c->my_name, c->my_len) ||
            !upd_len(m, their, 32) || !upd_len(m, c->my_msg, 32)) goto end;
    }
    if (!upd_len(m, dhenc, 32) || !upd_len(m, c->pw_hash, 64)) goto end;
    if (!EVP_DigestFinal_ex(m, key, &kl)) goto end;
    ok = 1;
end:
    EVP_MD_CTX_free(m);
    pt_free(&Q); pt_free(&mask); pt_free(&dh);
    return ok;
}
