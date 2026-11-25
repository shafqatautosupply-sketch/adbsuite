/* mDNS discovery of ADB wireless-debugging services via dns_sd.h */
#include "adbi.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <sys/select.h>
#include <sys/time.h>

#ifndef HAVE_DNSSD
int mdns_find(const char *type, const char *want_host, int timeout_ms, int list,
              char *host, size_t hlen, int *port) {
    (void)type; (void)want_host; (void)timeout_ms; (void)list; (void)host; (void)hlen; (void)port;
    return -1;
}
int mdns_browse(const char *type, int timeout_ms, mdns_cb cb, void *user) {
    (void)type; (void)timeout_ms; (void)cb; (void)user; return -1;
}
#else
#include <dns_sd.h>

typedef struct {
    const char *type, *want_host; int list; int found;
    char *host; size_t hlen; int *port;
    char rhost[256]; int rport; int resolved;
    DNSServiceRef browse;
    mdns_cb cb; void *cbu; int count;
} mctx;

static void resolve_cb(DNSServiceRef r, DNSServiceFlags f, uint32_t ifi, DNSServiceErrorType e,
                       const char *fullname, const char *target, uint16_t port, uint16_t txtlen,
                       const unsigned char *txt, void *ctx) {
    mctx *m = ctx; (void)r; (void)f; (void)ifi; (void)fullname; (void)txtlen; (void)txt;
    if (e) return;
    snprintf(m->rhost, sizeof m->rhost, "%s", target);
    m->rport = ntohs(port);
    m->resolved = 1;
}

static int to_ip(const char *name, char *out, size_t n) {
    struct addrinfo hints, *res;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(name, NULL, &hints, &res)) return -1;
    inet_ntop(AF_INET, &((struct sockaddr_in *)res->ai_addr)->sin_addr, out, n);
    freeaddrinfo(res);
    return 0;
}

static void browse_cb(DNSServiceRef b, DNSServiceFlags f, uint32_t ifi, DNSServiceErrorType e,
                      const char *name, const char *regtype, const char *domain, void *ctx) {
    mctx *m = ctx; DNSServiceRef rr = NULL; (void)b;
    if (e || !(f & kDNSServiceFlagsAdd) || m->found) return;
    m->resolved = 0;
    if (DNSServiceResolve(&rr, 0, ifi, name, regtype, domain, resolve_cb, m) != kDNSServiceErr_NoError) return;
    int fd = DNSServiceRefSockFD(rr);
    struct timeval tv = {2, 0}; fd_set s;
    while (!m->resolved) {
        FD_ZERO(&s); FD_SET(fd, &s);
        if (select(fd + 1, &s, NULL, NULL, &tv) <= 0) break;
        if (DNSServiceProcessResult(rr) != kDNSServiceErr_NoError) break;
    }
    DNSServiceRefDeallocate(rr);
    if (!m->resolved) return;
    char ip[64];
    if (to_ip(m->rhost, ip, sizeof ip)) snprintf(ip, sizeof ip, "%s", m->rhost);
    if (m->cb) { m->cb(name, ip, m->rport, m->cbu); m->count++; }
    if (m->list) printf("%-40s %s:%d  (%s)\n", name, ip, m->rport, m->type);
    if (m->want_host && strcmp(m->want_host, ip) && strcmp(m->want_host, m->rhost)) return;
    if (!m->list && m->host) {
        snprintf(m->host, m->hlen, "%s", ip); *m->port = m->rport; m->found = 1;
    }
}

int mdns_find(const char *type, const char *want_host, int timeout_ms, int list,
              char *host, size_t hlen, int *port) {
    mctx m; memset(&m, 0, sizeof m);
    m.type = type; m.want_host = want_host; m.list = list; m.host = host; m.hlen = hlen; m.port = port;
    if (DNSServiceBrowse(&m.browse, 0, 0, type, NULL, browse_cb, &m) != kDNSServiceErr_NoError) return -1;
    int fd = DNSServiceRefSockFD(m.browse);
    struct timeval end, now; gettimeofday(&end, NULL);
    end.tv_sec += timeout_ms / 1000; end.tv_usec += (timeout_ms % 1000) * 1000;
    if (end.tv_usec >= 1000000) { end.tv_sec++; end.tv_usec -= 1000000; }
    while (!m.found) {
        gettimeofday(&now, NULL);
        long left = (end.tv_sec - now.tv_sec) * 1000000L + (end.tv_usec - now.tv_usec);
        if (left <= 0) break;
        struct timeval tv = {left / 1000000, left % 1000000}; fd_set s;
        FD_ZERO(&s); FD_SET(fd, &s);
        if (select(fd + 1, &s, NULL, NULL, &tv) <= 0) continue;
        if (DNSServiceProcessResult(m.browse) != kDNSServiceErr_NoError) break;
    }
    DNSServiceRefDeallocate(m.browse);
    return m.found;
}

int mdns_browse(const char *type, int timeout_ms, mdns_cb cb, void *user) {
    char h[8]; int p = 0;
    mctx m; memset(&m, 0, sizeof m);
    m.type = type; m.cb = cb; m.cbu = user; m.host = NULL; m.hlen = 0; m.port = &p;
    if (DNSServiceBrowse(&m.browse, 0, 0, type, NULL, browse_cb, &m) != kDNSServiceErr_NoError) return -1;
    (void)h;
    int fd = DNSServiceRefSockFD(m.browse);
    struct timeval end, now; gettimeofday(&end, NULL);
    end.tv_sec += timeout_ms / 1000; end.tv_usec += (timeout_ms % 1000) * 1000;
    if (end.tv_usec >= 1000000) { end.tv_sec++; end.tv_usec -= 1000000; }
    for (;;) {
        gettimeofday(&now, NULL);
        long left = (end.tv_sec - now.tv_sec) * 1000000L + (end.tv_usec - now.tv_usec);
        if (left <= 0) break;
        struct timeval tv = {left / 1000000, left % 1000000}; fd_set s;
        FD_ZERO(&s); FD_SET(fd, &s);
        if (select(fd + 1, &s, NULL, NULL, &tv) <= 0) continue;
        if (DNSServiceProcessResult(m.browse) != kDNSServiceErr_NoError) break;
    }
    DNSServiceRefDeallocate(m.browse);
    return m.count;
}
#endif
