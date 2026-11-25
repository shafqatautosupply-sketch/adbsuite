/* ADB wireless-debugging pairing client (Android 11+ "Pair device with
 * pairing code").  TLS 1.3 + SPAKE2 + AES-128-GCM, as in AOSP
 * pairing_connection.cpp / pairing_auth.cpp. */
#include "adbi.h"
#include "spake2.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <openssl/hmac.h>
#include <openssl/err.h>
#include <openssl/rand.h>

#define PKT_SPAKE2_MSG 0
#define PKT_PEER_INFO 1
#define PEER_INFO_SIZE 8192
#define MAX_PAYLOAD (PEER_INFO_SIZE * 2)

typedef struct { uint8_t key[16]; uint64_t enc_seq, dec_seq; } gcm_t;

static void hkdf16(const uint8_t *ikm, size_t ilen, uint8_t out[16]) {
    static const char info[] = "adb pairing_auth aes-128-gcm key";
    uint8_t zero[32] = {0}, prk[32], t[EVP_MAX_MD_SIZE];
    unsigned int n = 0;
    HMAC(EVP_sha256(), zero, 32, ikm, ilen, prk, &n);           /* extract, empty salt */
    uint8_t buf[sizeof(info)]; memcpy(buf, info, sizeof(info) - 1); buf[sizeof(info) - 1] = 1;
    HMAC(EVP_sha256(), prk, 32, buf, sizeof(info), t, &n);       /* expand, T(1) */
    memcpy(out, t, 16);
}

static void nonce_of(uint64_t seq, uint8_t iv[12]) {
    int i; memset(iv, 0, 12);
    for (i = 0; i < 8; i++) iv[i] = (seq >> (8 * i)) & 0xff;
}

static int gcm_seal(gcm_t *g, const uint8_t *in, size_t n, uint8_t *out) {
    uint8_t iv[12]; int l = 0, ok = 0; EVP_CIPHER_CTX *c = EVP_CIPHER_CTX_new();
    nonce_of(g->enc_seq, iv);
    if (c && EVP_EncryptInit_ex(c, EVP_aes_128_gcm(), NULL, g->key, iv) &&
        EVP_EncryptUpdate(c, out, &l, in, (int)n) && EVP_EncryptFinal_ex(c, out + l, &l) &&
        EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_GCM_GET_TAG, 16, out + n)) ok = 1;
    EVP_CIPHER_CTX_free(c);
    if (ok) g->enc_seq++;
    return ok;
}

static int gcm_open(gcm_t *g, const uint8_t *in, size_t n, uint8_t *out) {
    uint8_t iv[12]; int l = 0, ok = 0; EVP_CIPHER_CTX *c;
    if (n < 16) return 0;
    c = EVP_CIPHER_CTX_new(); nonce_of(g->dec_seq, iv);
    if (c && EVP_DecryptInit_ex(c, EVP_aes_128_gcm(), NULL, g->key, iv) &&
        EVP_DecryptUpdate(c, out, &l, in, (int)(n - 16)) &&
        EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_GCM_SET_TAG, 16, (void *)(in + n - 16)) &&
        EVP_DecryptFinal_ex(c, out + l, &l)) ok = 1;
    EVP_CIPHER_CTX_free(c);
    if (ok) g->dec_seq++;
    return ok;
}

static int ssl_write_all(SSL *s, const void *b, size_t n) {
    const uint8_t *p = b;
    while (n) { int r = SSL_write(s, p, (int)n); if (r <= 0) return 0; p += r; n -= r; }
    return 1;
}
static int ssl_read_all(SSL *s, void *b, size_t n) {
    uint8_t *p = b;
    while (n) { int r = SSL_read(s, p, (int)n); if (r <= 0) return 0; p += r; n -= r; }
    return 1;
}

static int send_pkt(SSL *s, int type, const uint8_t *data, size_t n) {
    uint8_t h[6] = {1, (uint8_t)type, (uint8_t)(n >> 24), (uint8_t)(n >> 16), (uint8_t)(n >> 8), (uint8_t)n};
    return ssl_write_all(s, h, 6) && ssl_write_all(s, data, n);
}

/* returns payload length (malloc'd into *out) or -1 */
static long recv_pkt(SSL *s, int want_type, uint8_t **out) {
    uint8_t h[6];
    if (!ssl_read_all(s, h, 6)) return -1;
    uint32_t n = ((uint32_t)h[2] << 24) | (h[3] << 16) | (h[4] << 8) | h[5];
    if (h[0] != 1 || h[1] != want_type || n == 0 || n > MAX_PAYLOAD) {
        adbi_err("adbi: bad pairing packet (ver=%d type=%d len=%u)\n", h[0], h[1], n);
        return -1;
    }
    *out = malloc(n);
    if (!*out || !ssl_read_all(s, *out, n)) { free(*out); *out = NULL; return -1; }
    return (long)n;
}

int adbi_pair(const char *host, int port, const char *code) {
    int rc = 1, fd = -1;
    EVP_PKEY *pk = NULL; X509 *cert = NULL;
    SSL_CTX *ctx = NULL; SSL *ssl = NULL;
    char publine[1024];
    uint8_t exported[64], *pw = NULL, msg[SPAKE2_MSG_SIZE], key[SPAKE2_KEY_SIZE];
    uint8_t *their = NULL, *peer_ct = NULL, *plain = NULL, *info = NULL, *ct = NULL;
    spake2_ctx *sp = NULL; gcm_t g;
    size_t pwlen, cl = strlen(code);

    if (keys_load(&pk, publine, sizeof publine)) return 1;
    if (!(cert = keys_make_cert(pk))) { adbi_err("adbi: cannot create certificate\n"); goto end; }
    fd = tcp_connect(host, port, 10000);
    if (fd < 0) { adbi_err("adbi: cannot connect to %s:%d\n", host, port); goto end; }

    ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx || !SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION) ||
        !SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION)) {
        adbi_err("adbi: this OpenSSL build has no TLS 1.3 support\n"); goto end;
    }
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
    if (SSL_CTX_use_certificate(ctx, cert) != 1 || SSL_CTX_use_PrivateKey(ctx, pk) != 1) goto end;
    ssl = SSL_new(ctx);
    SSL_set_fd(ssl, fd);
    if (SSL_connect(ssl) != 1) {
        adbi_err("adbi: TLS handshake failed: ");
        adbi_err_ssl();
        goto end;
    }
    /* label is "adb-label" including the terminating NUL (sizeof in AOSP) */
    if (SSL_export_keying_material(ssl, exported, 64, "adb-label", 10, NULL, 0, 0) != 1) {
        adbi_err("adbi: key export failed\n"); goto end;
    }
    pwlen = cl + 64;
    pw = malloc(pwlen);
    memcpy(pw, code, cl); memcpy(pw + cl, exported, 64);

    sp = spake2_new(SPAKE2_ALICE, (const uint8_t *)"adb pair client", 16,
                    (const uint8_t *)"adb pair server", 16);
    if (!sp || !spake2_generate(sp, msg, pw, pwlen)) { adbi_err("adbi: spake2 failed\n"); goto end; }
    if (!send_pkt(ssl, PKT_SPAKE2_MSG, msg, sizeof msg)) { adbi_err("adbi: send failed\n"); goto end; }
    long tl = recv_pkt(ssl, PKT_SPAKE2_MSG, &their);
    if (tl < 0) { adbi_err("adbi: no SPAKE2 reply from device\n"); goto end; }
    if (!spake2_process(sp, key, their, (size_t)tl)) { adbi_err("adbi: SPAKE2 key agreement failed\n"); goto end; }

    memset(&g, 0, sizeof g);
    hkdf16(key, sizeof key, g.key);

    info = calloc(1, PEER_INFO_SIZE);
    info[0] = 0; /* ADB_RSA_PUB_KEY */
    size_t pl = strlen(publine);
    if (pl > PEER_INFO_SIZE - 2) goto end;
    memcpy(info + 1, publine, pl);
    ct = malloc(PEER_INFO_SIZE + 16);
    if (!gcm_seal(&g, info, PEER_INFO_SIZE, ct) || !send_pkt(ssl, PKT_PEER_INFO, ct, PEER_INFO_SIZE + 16)) goto end;

    long cl2 = recv_pkt(ssl, PKT_PEER_INFO, &peer_ct);
    if (cl2 < 0) {
        adbi_err("adbi: pairing rejected (wrong pairing code, or the code/dialog expired)\n"); goto end;
    }
    plain = malloc((size_t)cl2);
    if (!gcm_open(&g, peer_ct, (size_t)cl2, plain) || (size_t)cl2 - 16 != PEER_INFO_SIZE) {
        adbi_err("adbi: pairing failed (could not decrypt device info - wrong code?)\n"); goto end;
    }
    if (plain[0] == 1) {
        plain[PEER_INFO_SIZE - 1] = 0;
        adbi_info("Successfully paired [guid=%s]", (char *)plain + 1);
    } else {
        adbi_info("Successfully paired (device info type %d)", plain[0]);
    }
    rc = 0;
end:
    if (ssl) SSL_free(ssl);
    if (ctx) SSL_CTX_free(ctx);
    if (fd >= 0) close(fd);
    spake2_free(sp);
    free(pw); free(their); free(peer_ct); free(plain); free(info); free(ct);
    X509_free(cert); EVP_PKEY_free(pk);
    return rc;
}
