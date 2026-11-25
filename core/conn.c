/* ADB transport: TCP + (STLS upgrade | legacy AUTH) + single-stream mux */
#include "adbi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <openssl/err.h>
#include <openssl/rsa.h>
#include <openssl/obj_mac.h>

#define A_SYNC 0x434e5953
#define A_CNXN 0x4e584e43
#define A_AUTH 0x48545541
#define A_OPEN 0x4e45504f
#define A_OKAY 0x59414b4f
#define A_CLSE 0x45534c43
#define A_WRTE 0x45545257
#define A_STLS 0x534c5453
#define A_VERSION 0x01000001
#define A_STLS_VERSION 0x01000000
#define OUR_MAXDATA (256 * 1024)
#define CHUNK_MAX 65536

void put32le(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
uint32_t get32le(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }

int tcp_connect(const char *host, int port, int timeout_ms) {
    struct addrinfo hints, *res, *ai;
    char ps[16]; int fd = -1;
    memset(&hints, 0, sizeof hints);
    hints.ai_socktype = SOCK_STREAM;
    snprintf(ps, sizeof ps, "%d", port);
    if (getaddrinfo(host, ps, &hints, &res)) return -1;
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        int fl = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, fl | O_NONBLOCK);
        int r = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (r < 0 && errno == EINPROGRESS) {
            fd_set w; struct timeval tv = {timeout_ms / 1000, (timeout_ms % 1000) * 1000};
            FD_ZERO(&w); FD_SET(fd, &w);
            if (select(fd + 1, NULL, &w, NULL, &tv) > 0) {
                int err = 0; socklen_t el = sizeof err;
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
                r = err ? -1 : 0;
            } else r = -1;
        }
        if (r == 0) {
            int one = 1;
            fcntl(fd, F_SETFL, fl);
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
#ifdef SO_NOSIGPIPE
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
            struct timeval tv = {15, 0};   /* handshake timeout, cleared later */
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
            break;
        }
        close(fd); fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

/* ---- raw IO (plain or TLS) ---- */
static int io_write(adb_conn *c, const void *b, size_t n) {
    const uint8_t *p = b;
    while (n) {
        int r = c->ssl ? SSL_write(c->ssl, p, (int)n) : (int)write(c->fd, p, n);
        if (r <= 0) { if (!c->ssl && r < 0 && errno == EINTR) continue; return -1; }
        p += r; n -= r;
    }
    return 0;
}
static int io_read(adb_conn *c, void *b, size_t n) {
    uint8_t *p = b;
    while (n) {
        int r = c->ssl ? SSL_read(c->ssl, p, (int)n) : (int)read(c->fd, p, n);
        if (r <= 0) { if (!c->ssl && r < 0 && errno == EINTR) continue; return -1; }
        p += r; n -= r;
    }
    return 0;
}

static uint32_t checksum(const uint8_t *d, size_t n) {
    uint32_t s = 0; while (n--) s += *d++; return s;
}

static int adb_send(adb_conn *c, uint32_t cmd, uint32_t a0, uint32_t a1, const void *data, size_t len) {
    uint8_t h[24];
    put32le(h, cmd); put32le(h + 4, a0); put32le(h + 8, a1);
    put32le(h + 12, (uint32_t)len); put32le(h + 16, checksum(data, len)); put32le(h + 20, cmd ^ 0xffffffffu);
    if (io_write(c, h, 24)) return -1;
    return len ? io_write(c, data, len) : 0;
}

typedef struct { uint32_t cmd, a0, a1, len; } hdr_t;

/* payload goes into c->pkt (OUR_MAXDATA+1 bytes) */
static int adb_recv(adb_conn *c, hdr_t *h) {
    uint8_t b[24];
    if (io_read(c, b, 24)) return -1;
    h->cmd = get32le(b); h->a0 = get32le(b + 4); h->a1 = get32le(b + 8); h->len = get32le(b + 12);
    if (get32le(b + 20) != (h->cmd ^ 0xffffffffu) || h->len > OUR_MAXDATA * 4) return -1;
    if (h->len > OUR_MAXDATA) {
        /* larger than we advertised: refuse */
        return -1;
    }
    if (h->len && io_read(c, c->pkt, h->len)) return -1;
    c->pkt[h->len] = 0;
    return 0;
}

static void rb_push(adb_conn *c, const uint8_t *d, size_t n) {
    if (c->roff && c->roff == c->rlen) c->roff = c->rlen = 0;
    if (c->rlen + n > c->rcap) {
        if (c->roff) { memmove(c->rb, c->rb + c->roff, c->rlen - c->roff); c->rlen -= c->roff; c->roff = 0; }
        if (c->rlen + n > c->rcap) {
            c->rcap = (c->rlen + n) * 2;
            c->rb = realloc(c->rb, c->rcap);
            if (!c->rb) { adbi_err("adbi: out of memory\n"); exit(1); }
        }
    }
    memcpy(c->rb + c->rlen, d, n); c->rlen += n;
}
size_t rb_avail(adb_conn *c) { return c->rlen - c->roff; }
uint8_t *rb_ptr(adb_conn *c) { return c->rb + c->roff; }
void rb_consume(adb_conn *c, size_t n) { c->roff += n; if (c->roff == c->rlen) c->roff = c->rlen = 0; }

static int handle_pkt(adb_conn *c, hdr_t *h) {
    switch (h->cmd) {
    case A_WRTE:
        if (h->a1 != c->local) return 0;
        rb_push(c, c->pkt, h->len);
        return adb_send(c, A_OKAY, c->local, c->remote, NULL, 0);
    case A_OKAY:
        if (!c->opened) { c->remote = h->a0; c->opened = 1; }
        else c->ok_pending = 0;
        return 0;
    case A_CLSE:
        if (!c->closed) {
            c->closed = 1;
            if (c->opened) adb_send(c, A_CLSE, c->local, c->remote, NULL, 0);
        }
        return 0;
    default:
        return 0;
    }
}

int adb_wait(adb_conn *c, int extra_fd, int *extra_ready) {
    fd_set r; int mx = c->fd;
    if (extra_ready) *extra_ready = 0;
    if (c->closed) return -1;
    if (!(c->ssl && SSL_pending(c->ssl))) {
        FD_ZERO(&r); FD_SET(c->fd, &r);
        if (extra_fd >= 0) { FD_SET(extra_fd, &r); if (extra_fd > mx) mx = extra_fd; }
        int n = select(mx + 1, &r, NULL, NULL, NULL);
        if (n < 0) return errno == EINTR ? 0 : -1;
        if (extra_fd >= 0 && FD_ISSET(extra_fd, &r) && extra_ready) *extra_ready = 1;
        if (!FD_ISSET(c->fd, &r)) return 0;
    }
    hdr_t h;
    if (adb_recv(c, &h)) { c->closed = 1; return -1; }
    return handle_pkt(c, &h);
}

int stream_open(adb_conn *c, const char *service) {
    c->local = 1; c->remote = 0; c->opened = 0; c->closed = 0; c->ok_pending = 0;
    if (adb_send(c, A_OPEN, c->local, 0, service, strlen(service) + 1)) return -1;
    while (!c->opened && !c->closed) if (adb_wait(c, -1, NULL) < 0) return -1;
    return c->opened ? 0 : -1;
}

int stream_write(adb_conn *c, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len) {
        size_t n = len > c->maxdata ? c->maxdata : len;
        if (adb_send(c, A_WRTE, c->local, c->remote, p, n)) return -1;
        c->ok_pending = 1;
        while (c->ok_pending && !c->closed) if (adb_wait(c, -1, NULL) < 0) return -1;
        if (c->closed) return -1;
        p += n; len -= n;
    }
    return 0;
}

int stream_read_exact(adb_conn *c, void *buf, size_t n) {
    while (rb_avail(c) < n) {
        if (c->closed) return -1;
        if (adb_wait(c, -1, NULL) < 0 && rb_avail(c) < n) return -1;
    }
    memcpy(buf, rb_ptr(c), n); rb_consume(c, n);
    return 0;
}

void stream_close(adb_conn *c) {
    if (c->opened && !c->closed) { adb_send(c, A_CLSE, c->local, c->remote, NULL, 0); c->closed = 1; }
}

/* ---- legacy AUTH (adb over plain TCP such as tcpip 5555) ---- */
static int legacy_auth(adb_conn *c, hdr_t *h, EVP_PKEY *pk, const char *publine) {
    int tries = 0;
    RSA *rsa = EVP_PKEY_get1_RSA(pk);
    while (h->cmd == A_AUTH && tries < 3) {
        if (h->a0 == 1 && h->len == 20) {
            uint8_t sig[512]; unsigned int sl = sizeof sig;
            if (tries == 0 && RSA_sign(NID_sha1, c->pkt, 20, sig, &sl, rsa) == 1) {
                adb_send(c, A_AUTH, 2, 0, sig, sl);
            } else {
                adbi_err("adbi: device is asking you to allow this key - check the screen...\n");
                adb_send(c, A_AUTH, 3, 0, publine, strlen(publine) + 1);
            }
            tries++;
            struct timeval tv = {60, 0};
            setsockopt(c->fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        }
        if (adb_recv(c, h)) { RSA_free(rsa); return -1; }
    }
    RSA_free(rsa);
    return h->cmd == A_CNXN ? 0 : -1;
}

int adb_connect(adb_conn *c, const char *host, int port) {
    EVP_PKEY *pk = NULL; X509 *cert = NULL; char publine[1024];
    static const char banner[] = "host::features=shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir";
    hdr_t h;
    memset(c, 0, sizeof *c);
    c->fd = -1;
    c->pkt = malloc(OUR_MAXDATA + 1);
    if (!c->pkt) return -1;
    if (keys_load(&pk, publine, sizeof publine)) return -1;
    c->fd = tcp_connect(host, port, 8000);
    if (c->fd < 0) { adbi_err("adbi: cannot connect to %s:%d (%s)\n", host, port, strerror(errno)); goto fail; }
    if (adb_send(c, A_CNXN, A_VERSION, OUR_MAXDATA, banner, sizeof banner)) goto fail;
    if (adb_recv(c, &h)) { adbi_err("adbi: no response from device\n"); goto fail; }

    if (h.cmd == A_STLS) {
        if (adb_send(c, A_STLS, A_STLS_VERSION, 0, NULL, 0)) goto fail;
        c->ctx = SSL_CTX_new(TLS_client_method());
        if (!c->ctx || !SSL_CTX_set_min_proto_version(c->ctx, TLS1_3_VERSION) ||
            !SSL_CTX_set_max_proto_version(c->ctx, TLS1_3_VERSION)) {
            adbi_err("adbi: this OpenSSL build has no TLS 1.3 support\n"); goto fail;
        }
        SSL_CTX_set_verify(c->ctx, SSL_VERIFY_NONE, NULL);
        cert = keys_make_cert(pk);
        if (!cert || SSL_CTX_use_certificate(c->ctx, cert) != 1 || SSL_CTX_use_PrivateKey(c->ctx, pk) != 1) goto fail;
        c->ssl = SSL_new(c->ctx);
        SSL_set_fd(c->ssl, c->fd);
        if (SSL_connect(c->ssl) != 1) {
            adbi_err("adbi: TLS handshake failed: "); adbi_err_ssl(); goto fail;
        }
        c->use_tls = 1;
        if (adb_recv(c, &h)) {
            adbi_err("adbi: device closed the connection after TLS handshake.\n"
                            "      This key is probably not paired - run: adbi pair HOST:PAIRPORT CODE\n");
            goto fail;
        }
    } else if (h.cmd == A_AUTH) {
        if (legacy_auth(c, &h, pk, publine)) { adbi_err("adbi: authentication failed\n"); goto fail; }
    }
    if (h.cmd != A_CNXN) { adbi_err("adbi: unexpected reply 0x%08x\n", h.cmd); goto fail; }

    strncpy(c->banner, (char *)c->pkt, sizeof c->banner - 1);
    c->maxdata = h.a1 < CHUNK_MAX ? h.a1 : CHUNK_MAX;
    if (c->maxdata < 4096) c->maxdata = 4096;
    c->shell_v2 = strstr(c->banner, "shell_v2") != NULL;
    { struct timeval tv = {0, 0};
      setsockopt(c->fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
      setsockopt(c->fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv); }
    X509_free(cert); EVP_PKEY_free(pk);
    return 0;
fail:
    X509_free(cert); EVP_PKEY_free(pk);
    adb_close(c);
    return -1;
}

void adb_close(adb_conn *c) {
    if (c->ssl) { SSL_shutdown(c->ssl); SSL_free(c->ssl); c->ssl = NULL; }
    if (c->ctx) { SSL_CTX_free(c->ctx); c->ctx = NULL; }
    if (c->fd >= 0) { close(c->fd); c->fd = -1; }
    free(c->rb); c->rb = NULL; free(c->pkt); c->pkt = NULL;
}
