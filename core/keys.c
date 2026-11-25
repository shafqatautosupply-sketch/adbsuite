#include "adbi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <openssl/rsa.h>
#include <openssl/bn.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/err.h>

const char *adbi_home(void) {
    static char buf[512];
    const char *h = getenv("ADBI_HOME");
    if (h && *h) return h;
    h = getenv("HOME");
    snprintf(buf, sizeof buf, "%s/.adbi", h && *h ? h : "/var/mobile");
    return buf;
}

int adbi_path(char *out, size_t n, const char *name) {
    mkdir(adbi_home(), 0700);
    return snprintf(out, n, "%s/%s", adbi_home(), name) < (int)n ? 0 : -1;
}

/* Android RSAPublicKey blob: see libcrypto_utils/android_pubkey.c */
#define ANDROID_PUBKEY_MODULUS_BYTES 256
#define ANDROID_PUBKEY_ENCODED_SIZE 524

static int android_pubkey(RSA *rsa, uint8_t out[ANDROID_PUBKEY_ENCODED_SIZE]) {
    const BIGNUM *n, *e;
    BN_CTX *ctx = BN_CTX_new();
    BIGNUM *r32 = BN_new(), *n0 = BN_new(), *rr = BN_new(), *two = BN_new();
    int ok = 0;
    uint32_t n0inv, ex;
    RSA_get0_key(rsa, &n, &e, NULL);
    if (!ctx || !r32 || !n0 || !rr || !two || BN_num_bits(n) != 2048) goto end;
    /* n0inv = -1 / n[0] mod 2^32 */
    BN_set_bit(r32, 32);
    if (!BN_nnmod(n0, n, r32, ctx) || !BN_mod_inverse(n0, n0, r32, ctx) ||
        !BN_sub(n0, r32, n0)) goto end;
    BN_mask_bits(n0, 32);
    n0inv = (uint32_t)BN_get_word(n0);
    /* rr = 2^4096 mod n */
    BN_set_word(two, 2);
    BN_set_word(rr, 4096);
    if (!BN_mod_exp(rr, two, rr, n, ctx)) goto end;
    ex = (uint32_t)BN_get_word(e);
    memset(out, 0, ANDROID_PUBKEY_ENCODED_SIZE);
    put32le(out, ANDROID_PUBKEY_MODULUS_BYTES / 4);
    put32le(out + 4, n0inv);
    if (BN_bn2lebinpad(n, out + 8, 256) != 256) goto end;
    if (BN_bn2lebinpad(rr, out + 8 + 256, 256) != 256) goto end;
    put32le(out + 8 + 512, ex);
    ok = 1;
end:
    BN_free(r32); BN_free(n0); BN_free(rr); BN_free(two); BN_CTX_free(ctx);
    return ok;
}

static int make_publine(EVP_PKEY *pk, char *publine, size_t publen) {
    uint8_t blob[ANDROID_PUBKEY_ENCODED_SIZE];
    char b64[1024], host[128] = "localhost";
    const char *user = getenv("USER");
    RSA *rsa = EVP_PKEY_get1_RSA(pk);
    if (!rsa) return -1;
    int ok = android_pubkey(rsa, blob);
    RSA_free(rsa);
    if (!ok) return -1;
    EVP_EncodeBlock((unsigned char *)b64, blob, sizeof blob);
    gethostname(host, sizeof host - 1);
    snprintf(publine, publen, "%s %s@%s", b64, user && *user ? user : "adbi", host);
    return 0;
}

static int key_path(char *out, size_t n, int pub) {
    const char *k = getenv("ADBI_KEY");
    if (k && *k) {
        snprintf(out, n, "%s%s", k, pub ? ".pub" : "");
        return 0;
    }
    return adbi_path(out, n, pub ? "adbkey.pub" : "adbkey");
}

int keys_load(EVP_PKEY **pkey, char *publine, size_t publen) {
    char path[600], ppath[600];
    FILE *f;
    EVP_PKEY *pk = NULL;
    if (key_path(path, sizeof path, 0) || key_path(ppath, sizeof ppath, 1)) return -1;
    if ((f = fopen(path, "r"))) {
        pk = PEM_read_PrivateKey(f, NULL, NULL, NULL);
        fclose(f);
        if (!pk) { adbi_err("adbi: cannot parse %s\n", path); return -1; }
    } else {
        adbi_note("adbi: generating RSA-2048 key (can take a while on old CPUs)...\n");
        BIGNUM *e = BN_new();
        RSA *rsa = RSA_new();
        BN_set_word(e, RSA_F4);
        if (!RSA_generate_key_ex(rsa, 2048, e, NULL)) { BN_free(e); RSA_free(rsa); return -1; }
        BN_free(e);
        pk = EVP_PKEY_new();
        EVP_PKEY_assign_RSA(pk, rsa);
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        f = fd >= 0 ? fdopen(fd, "w") : NULL;
        if (!f) { adbi_err("adbi: cannot write %s: %s\n", path, strerror(errno)); return -1; }
        PEM_write_PrivateKey(f, pk, NULL, NULL, 0, NULL, NULL);
        fclose(f);
        chmod(path, 0600);
    }
    if (make_publine(pk, publine, publen)) { EVP_PKEY_free(pk); return -1; }
    if ((f = fopen(ppath, "w"))) { fprintf(f, "%s\n", publine); fclose(f); }
    *pkey = pk;
    return 0;
}

static int add_ext(X509 *cert, int nid, const char *value) {
    X509V3_CTX ctx;
    X509V3_set_ctx_nodb(&ctx);
    X509V3_set_ctx(&ctx, cert, cert, NULL, NULL, 0);
    X509_EXTENSION *ex = X509V3_EXT_conf_nid(NULL, &ctx, nid, (char *)value);
    if (!ex) return 0;
    X509_add_ext(cert, ex, -1);
    X509_EXTENSION_free(ex);
    return 1;
}

/* Same self-signed certificate shape that AOSP's GenerateX509Certificate makes */
X509 *keys_make_cert(EVP_PKEY *pk) {
    X509 *x = X509_new();
    if (!x) return NULL;
    X509_set_version(x, 2);
    ASN1_INTEGER_set(X509_get_serialNumber(x), 1);
    X509_gmtime_adj(X509_getm_notBefore(x), 0);
    X509_gmtime_adj(X509_getm_notAfter(x), 10L * 365 * 24 * 60 * 60);
    X509_set_pubkey(x, pk);
    X509_NAME *nm = X509_get_subject_name(x);
    X509_NAME_add_entry_by_txt(nm, "C", MBSTRING_ASC, (const unsigned char *)"US", -1, -1, 0);
    X509_NAME_add_entry_by_txt(nm, "O", MBSTRING_ASC, (const unsigned char *)"Android", -1, -1, 0);
    X509_NAME_add_entry_by_txt(nm, "CN", MBSTRING_ASC, (const unsigned char *)"Adb", -1, -1, 0);
    X509_set_issuer_name(x, nm);
    add_ext(x, NID_basic_constraints, "critical,CA:TRUE");
    add_ext(x, NID_key_usage, "critical,keyCertSign,cRLSign,digitalSignature");
    add_ext(x, NID_subject_key_identifier, "hash");
    if (X509_sign(x, pk, EVP_sha256()) <= 0) { X509_free(x); return NULL; }
    return x;
}
