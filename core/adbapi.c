#include "adbapi.h"
#include "adbi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <openssl/err.h>

void adbapi_init(const char *home) {
    static int done;
    if (done) return;
    done = 1;
    if (home && *home) setenv("ADBI_HOME", home, 1);
    adbi_quiet = 1;
    signal(SIGPIPE, SIG_IGN);
    SSL_library_init(); SSL_load_error_strings(); OpenSSL_add_all_algorithms();
}
void adbapi_last_error(char *out, size_t n) { adbi_get_error(out, n); }
void adbapi_last_info(char *out, size_t n) { adbi_get_info(out, n); }

int adbapi_pubkey(char *out, size_t n) {
    EVP_PKEY *pk = NULL; char line[1024];
    adbi_clear();
    if (keys_load(&pk, line, sizeof line)) return -1;
    EVP_PKEY_free(pk);
    snprintf(out, n, "%s", line);
    return 0;
}

int adbapi_pair(const char *host, int port, const char *code) {
    adbi_clear();
    return adbi_pair(host, port, code);
}

int adbapi_probe(const char *host, int port, char *banner, size_t n) {
    adb_conn c;
    adbi_clear();
    if (adb_connect(&c, host, port)) return -1;
    if (banner) snprintf(banner, n, "%s", c.banner);
    adb_close(&c);
    return 0;
}

typedef struct { adbapi_found_cb cb; void *user; int kind; } disc_t;
static void disc_cb(const char *name, const char *host, int port, void *u) {
    disc_t *d = u; d->cb(d->kind, name, host, port, d->user);
}
int adbapi_discover(int timeout_ms, adbapi_found_cb cb, void *user) {
    disc_t d1 = {cb, user, 1}, d0 = {cb, user, 0};
    int a = mdns_browse(MDNS_PAIRING, timeout_ms / 2, disc_cb, &d1);
    int b = mdns_browse(MDNS_CONNECT, timeout_ms / 2, disc_cb, &d0);
    if (a < 0 && b < 0) { adbi_err("mDNS is not available on this device\n"); return -1; }
    return (a > 0 ? a : 0) + (b > 0 ? b : 0);
}
int adbapi_find_port(const char *host, int timeout_ms) {
    char h[128]; int p = 0;
    return mdns_find(MDNS_CONNECT, host, timeout_ms, 0, h, sizeof h, &p) == 1 ? p : 0;
}

/* ---- shared v2 frame draining ---- */
static void put_v2(adb_conn *c, int id, const void *d, size_t n) {
    uint8_t *b = malloc(n + 5);
    if (!b) return;
    b[0] = (uint8_t)id; put32le(b + 1, (uint32_t)n); if (n) memcpy(b + 5, d, n);
    stream_write(c, b, n + 5);
    free(b);
}

static void drain(adb_conn *c, int framed, adbapi_data_cb cb, void *user, int *exit_code) {
    while (rb_avail(c)) {
        if (!framed) { cb(1, rb_ptr(c), rb_avail(c), user); rb_consume(c, rb_avail(c)); return; }
        if (rb_avail(c) < 5) return;
        uint8_t *p = rb_ptr(c); uint32_t len = get32le(p + 1);
        if (rb_avail(c) < 5 + (size_t)len) return;
        if (p[0] == 1 || p[0] == 2) cb(p[0], p + 5, len, user);
        else if (p[0] == 3 && len >= 1) { if (exit_code) *exit_code = p[5]; cb(3, p + 5, len, user); }
        rb_consume(c, 5 + (size_t)len);
    }
}

typedef struct { uint8_t *buf; size_t len, cap; } collect_t;
static void collect_cb(int kind, const uint8_t *d, size_t n, void *u) {
    collect_t *c = u;
    if (kind == 3) return;
    if (c->len + n + 1 > c->cap) {
        size_t nc = (c->len + n + 1) * 2;
        uint8_t *nb = realloc(c->buf, nc);
        if (!nb) return;
        c->buf = nb; c->cap = nc;
    }
    memcpy(c->buf + c->len, d, n); c->len += n; c->buf[c->len] = 0;
}

static int run_collect(adb_conn *c, const char *svc, int framed, collect_t *col, int *code) {
    int ec = 0;
    if (stream_open(c, svc)) { adbi_err("Device refused service '%s'\n", svc); return -1; }
    if (framed) put_v2(c, 3, NULL, 0);          /* no stdin */
    for (;;) {
        drain(c, framed, collect_cb, col, &ec);
        if (c->closed) break;
        if (adb_wait(c, -1, NULL) < 0) break;
    }
    drain(c, framed, collect_cb, col, &ec);
    if (code) *code = ec;
    return 0;
}

int adbapi_shell(const char *host, int port, const char *cmd, char **out, size_t *outlen, int *exit_code) {
    adb_conn c; collect_t col = {0}; char svc[8192]; int rc;
    adbi_clear();
    *out = NULL; if (outlen) *outlen = 0; if (exit_code) *exit_code = 0;
    if (adb_connect(&c, host, port)) return -1;
    if (c.shell_v2) snprintf(svc, sizeof svc, "shell,v2,raw:%s", cmd);
    else snprintf(svc, sizeof svc, "shell:%s", cmd);
    rc = run_collect(&c, svc, c.shell_v2, &col, exit_code);
    adb_close(&c);
    if (!col.buf) { col.buf = calloc(1, 1); }
    *out = (char *)col.buf; if (outlen) *outlen = col.len;
    return rc;
}

int adbapi_service(const char *host, int port, const char *service, uint8_t **out, size_t *outlen) {
    adb_conn c; collect_t col = {0}; int rc;
    adbi_clear();
    *out = NULL; *outlen = 0;
    if (adb_connect(&c, host, port)) return -1;
    rc = run_collect(&c, service, 0, &col, NULL);
    adb_close(&c);
    if (!col.buf) col.buf = calloc(1, 1);
    *out = col.buf; *outlen = col.len;
    return rc;
}

/* ---- streaming session ---- */
struct adbapi_stream {
    char host[256]; int port; char service[2048]; int framed;
    adbapi_data_cb cb; void *user;
    pthread_mutex_t mu;
    uint8_t *q; size_t qlen, qcap;
    int stop, wake[2];
};

adbapi_stream *adbapi_stream_new(const char *host, int port, const char *service, int framed,
                                 adbapi_data_cb cb, void *user) {
    adbapi_stream *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    snprintf(s->host, sizeof s->host, "%s", host);
    snprintf(s->service, sizeof s->service, "%s", service);
    s->port = port; s->framed = framed; s->cb = cb; s->user = user;
    pthread_mutex_init(&s->mu, NULL);
    if (pipe(s->wake)) { free(s); return NULL; }
    fcntl(s->wake[0], F_SETFL, O_NONBLOCK);
    fcntl(s->wake[1], F_SETFL, O_NONBLOCK);
    return s;
}

static void wake(adbapi_stream *s) { char x = 'x'; (void)!write(s->wake[1], &x, 1); }

void adbapi_stream_send(adbapi_stream *s, const void *d, size_t n) {
    pthread_mutex_lock(&s->mu);
    if (s->qlen + n > s->qcap) {
        size_t nc = (s->qlen + n) * 2 + 64;
        uint8_t *nb = realloc(s->q, nc);
        if (!nb) { pthread_mutex_unlock(&s->mu); return; }
        s->q = nb; s->qcap = nc;
    }
    memcpy(s->q + s->qlen, d, n); s->qlen += n;
    pthread_mutex_unlock(&s->mu);
    wake(s);
}
void adbapi_stream_stop(adbapi_stream *s) {
    pthread_mutex_lock(&s->mu); s->stop = 1; pthread_mutex_unlock(&s->mu);
    wake(s);
}
void adbapi_stream_free(adbapi_stream *s) {
    if (!s) return;
    close(s->wake[0]); close(s->wake[1]);
    free(s->q); pthread_mutex_destroy(&s->mu); free(s);
}

int adbapi_stream_run(adbapi_stream *s) {
    adb_conn c; int ec = 0, ready, framed = s->framed;
    char svc[2048];
    adbi_clear();
    if (adb_connect(&c, s->host, s->port)) return -1;
    snprintf(svc, sizeof svc, "%s", s->service);
    if (framed && !c.shell_v2) {              /* old device: fall back to legacy shell */
        const char *colon = strchr(s->service, ':');
        snprintf(svc, sizeof svc, "shell:%s", colon ? colon + 1 : "");
        framed = 0;
    }
    if (stream_open(&c, svc)) { adbi_err("Device refused service '%s'\n", svc); adb_close(&c); return -1; }
    for (;;) {
        drain(&c, framed, s->cb, s->user, &ec);
        if (c.closed) break;
        pthread_mutex_lock(&s->mu); int stop = s->stop; pthread_mutex_unlock(&s->mu);
        if (stop) break;
        if (adb_wait(&c, s->wake[0], &ready) < 0) break;
        if (ready) {
            char junk[64];
            while (read(s->wake[0], junk, sizeof junk) > 0) {}
            pthread_mutex_lock(&s->mu);
            uint8_t *out = s->q; size_t n = s->qlen;
            s->q = NULL; s->qlen = s->qcap = 0;
            pthread_mutex_unlock(&s->mu);
            if (out && n) {
                if (framed) put_v2(&c, 0, out, n); else stream_write(&c, out, n);
            }
            free(out);
        }
    }
    drain(&c, framed, s->cb, s->user, &ec);
    stream_close(&c);
    adb_close(&c);
    return ec;
}

/* ---- sync push / pull ---- */
int adbapi_push(const char *host, int port, const char *local, const char *remote,
                adbapi_progress_cb cb, void *user) {
    adb_conn c; int rc = -1; struct stat st; uint8_t h[8], *buf = NULL;
    FILE *f = fopen(local, "rb");
    adbi_clear();
    if (!f || fstat(fileno(f), &st)) { adbi_err("Cannot open %s\n", local); if (f) fclose(f); return -1; }
    if (adb_connect(&c, host, port)) { fclose(f); return -1; }
    if (stream_open(&c, "sync:")) { adbi_err("Device refused sync service\n"); goto out; }
    {
        char spec[1400]; size_t total = 0, got;
        int n = snprintf(spec, sizeof spec, "%s,%d", remote, (int)(st.st_mode & 0777) | 0100000);
        uint8_t *b = malloc(8 + n);
        memcpy(b, "SEND", 4); put32le(b + 4, n); memcpy(b + 8, spec, n);
        int r = stream_write(&c, b, 8 + n); free(b);
        if (r) goto out;
        buf = malloc(8 + 65536);
        memcpy(buf, "DATA", 4);
        while ((got = fread(buf + 8, 1, 65536, f)) > 0) {
            put32le(buf + 4, (uint32_t)got);
            if (stream_write(&c, buf, 8 + got)) { adbi_err("Connection lost during upload\n"); goto out; }
            total += got;
            if (cb) cb(total, (uint64_t)st.st_size, user);
        }
        memcpy(h, "DONE", 4); put32le(h + 4, (uint32_t)st.st_mtime);
        if (stream_write(&c, h, 8) || stream_read_exact(&c, h, 8)) { adbi_err("No reply from device\n"); goto out; }
        if (!memcmp(h, "OKAY", 4)) rc = 0;
        else if (!memcmp(h, "FAIL", 4)) {
            uint32_t m = get32le(h + 4); char msg[300] = "";
            if (m > sizeof msg - 1) m = sizeof msg - 1;
            stream_read_exact(&c, msg, m); msg[m] = 0;
            adbi_err("Device error: %s\n", msg);
        }
    }
out:
    free(buf); fclose(f); adb_close(&c);
    return rc;
}

int adbapi_pull(const char *host, int port, const char *remote, const char *local,
                uint64_t total_hint, adbapi_progress_cb cb, void *user) {
    adb_conn c; int rc = -1; FILE *f = NULL; uint8_t h[8]; uint64_t total = 0;
    adbi_clear();
    if (adb_connect(&c, host, port)) return -1;
    if (stream_open(&c, "sync:")) { adbi_err("Device refused sync service\n"); goto out; }
    {
        size_t n = strlen(remote); uint8_t *b = malloc(8 + n);
        memcpy(b, "RECV", 4); put32le(b + 4, (uint32_t)n); memcpy(b + 8, remote, n);
        int r = stream_write(&c, b, 8 + n); free(b);
        if (r) goto out;
    }
    for (;;) {
        if (stream_read_exact(&c, h, 8)) { adbi_err("Connection lost during download\n"); goto out; }
        if (!memcmp(h, "DATA", 4)) {
            uint32_t n = get32le(h + 4); uint8_t *b;
            if (n > 65536) goto out;
            b = malloc(n ? n : 1);
            if (stream_read_exact(&c, b, n)) { free(b); goto out; }
            if (!f && !(f = fopen(local, "wb"))) { adbi_err("Cannot write %s\n", local); free(b); goto out; }
            fwrite(b, 1, n, f); free(b); total += n;
            if (cb) cb(total, total_hint, user);
        } else if (!memcmp(h, "DONE", 4)) { rc = 0; break; }
        else if (!memcmp(h, "FAIL", 4)) {
            uint32_t m = get32le(h + 4); char msg[300] = "";
            if (m > sizeof msg - 1) m = sizeof msg - 1;
            stream_read_exact(&c, msg, m); msg[m] = 0;
            adbi_err("Device error: %s\n", msg);
            goto out;
        } else goto out;
    }
    if (!f) f = fopen(local, "wb");
out:
    if (f) fclose(f);
    adb_close(&c);
    return rc;
}

/* ---- port forwarding ---- */
struct adbapi_fwd {
    char host[256]; int port; char service[256];
    int lsock; volatile int stop; pthread_t th;
};
typedef struct { char host[256]; int port; char service[256]; int fd; } fwd_client;

static void *fwd_client_main(void *arg) {
    fwd_client *fc = arg; adb_conn c; int ready; uint8_t buf[16384];
    if (adb_connect(&c, fc->host, fc->port)) goto done;
    if (stream_open(&c, fc->service)) { adb_close(&c); goto done; }
    for (;;) {
        while (rb_avail(&c)) {
            ssize_t w = write(fc->fd, rb_ptr(&c), rb_avail(&c));
            if (w <= 0) goto end;
            rb_consume(&c, (size_t)w);
        }
        if (c.closed) break;
        if (adb_wait(&c, fc->fd, &ready) < 0) break;
        if (ready) {
            ssize_t n = read(fc->fd, buf, sizeof buf);
            if (n <= 0) break;
            if (stream_write(&c, buf, (size_t)n)) break;
        }
    }
end:
    stream_close(&c);
    adb_close(&c);
done:
    close(fc->fd); free(fc);
    return NULL;
}

static void *fwd_accept_main(void *arg) {
    adbapi_fwd *f = arg;
    while (!f->stop) {
        fd_set r; struct timeval tv = {0, 400000};
        FD_ZERO(&r); FD_SET(f->lsock, &r);
        if (select(f->lsock + 1, &r, NULL, NULL, &tv) <= 0) continue;
        int fd = accept(f->lsock, NULL, NULL);
        if (fd < 0) continue;
        fwd_client *fc = calloc(1, sizeof *fc);
        memcpy(fc->host, f->host, sizeof fc->host); fc->port = f->port;
        memcpy(fc->service, f->service, sizeof fc->service); fc->fd = fd;
        pthread_t t; pthread_attr_t at;
        pthread_attr_init(&at); pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&t, &at, fwd_client_main, fc)) { close(fd); free(fc); }
        pthread_attr_destroy(&at);
    }
    close(f->lsock);
    return NULL;
}

adbapi_fwd *adbapi_forward_start(const char *host, int port, int local_port, const char *service, int bind_all) {
    struct sockaddr_in a; int o = 1;
    adbapi_fwd *f = calloc(1, sizeof *f);
    adbi_clear();
    if (!f) return NULL;
    snprintf(f->host, sizeof f->host, "%s", host); f->port = port;
    snprintf(f->service, sizeof f->service, "%s", service);
    f->lsock = socket(AF_INET, SOCK_STREAM, 0);
    setsockopt(f->lsock, SOL_SOCKET, SO_REUSEADDR, &o, sizeof o);
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons((uint16_t)local_port);
    a.sin_addr.s_addr = htonl(bind_all ? INADDR_ANY : INADDR_LOOPBACK);
    if (bind(f->lsock, (struct sockaddr *)&a, sizeof a) || listen(f->lsock, 8)) {
        adbi_err("Cannot listen on port %d: %s\n", local_port, strerror(errno));
        close(f->lsock); free(f); return NULL;
    }
    if (pthread_create(&f->th, NULL, fwd_accept_main, f)) { close(f->lsock); free(f); return NULL; }
    return f;
}
void adbapi_forward_stop(adbapi_fwd *f) {
    if (!f) return;
    f->stop = 1;
    pthread_join(f->th, NULL);
    free(f);
}
