#include "adbi.h"
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <pthread.h>
#include <openssl/err.h>

int adbi_quiet = 0;
static char g_err[2048], g_info[512];
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

static void append(char *buf, size_t cap, const char *s) {
    size_t l = strlen(buf);
    if (l + 1 < cap) { strncat(buf, s, cap - l - 1); }
}
void adbi_err(const char *fmt, ...) {
    char tmp[600]; va_list ap;
    va_start(ap, fmt); vsnprintf(tmp, sizeof tmp, fmt, ap); va_end(ap);
    if (!adbi_quiet) fputs(tmp, stderr);
    pthread_mutex_lock(&g_mu); append(g_err, sizeof g_err, tmp); pthread_mutex_unlock(&g_mu);
}
void adbi_err_ssl(void) {
    unsigned long e; char b[256];
    while ((e = ERR_get_error())) { ERR_error_string_n(e, b, sizeof b); strncat(b, "\n", sizeof b - strlen(b) - 1); adbi_err("%s", b); }
}
void adbi_info(const char *fmt, ...) {
    char tmp[400]; va_list ap;
    va_start(ap, fmt); vsnprintf(tmp, sizeof tmp, fmt, ap); va_end(ap);
    if (!adbi_quiet) { fputs(tmp, stdout); fputc('\n', stdout); }
    pthread_mutex_lock(&g_mu); g_info[0] = 0; append(g_info, sizeof g_info, tmp); pthread_mutex_unlock(&g_mu);
}
void adbi_note(const char *fmt, ...) {
    char tmp[400]; va_list ap;
    va_start(ap, fmt); vsnprintf(tmp, sizeof tmp, fmt, ap); va_end(ap);
    if (!adbi_quiet) fputs(tmp, stderr);
}
void adbi_clear(void) { pthread_mutex_lock(&g_mu); g_err[0] = 0; g_info[0] = 0; pthread_mutex_unlock(&g_mu); }
void adbi_get_error(char *out, size_t n) {
    pthread_mutex_lock(&g_mu); snprintf(out, n, "%s", g_err); pthread_mutex_unlock(&g_mu);
    size_t l = strlen(out); while (l && (out[l-1] == '\n' || out[l-1] == ' ')) out[--l] = 0;
}
void adbi_get_info(char *out, size_t n) {
    pthread_mutex_lock(&g_mu); snprintf(out, n, "%s", g_info); pthread_mutex_unlock(&g_mu);
}
