/* adbapi - thread-safe C API used by the ADB Suite GUI.  All calls block; run them off the main thread. */
#ifndef ADBAPI_H
#define ADBAPI_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

void adbapi_init(const char *home_dir);
void adbapi_last_error(char *out, size_t n);
void adbapi_last_info(char *out, size_t n);
int  adbapi_pubkey(char *out, size_t n);            /* 0 ok; generates key on first use */

int  adbapi_pair(const char *host, int port, const char *code);
int  adbapi_probe(const char *host, int port, char *banner, size_t n);   /* 0 = connected */

/* kind: 0 = connect service, 1 = pairing service */
typedef void (*adbapi_found_cb)(int kind, const char *name, const char *host, int port, void *user);
int  adbapi_discover(int timeout_ms, adbapi_found_cb cb, void *user);
int  adbapi_find_port(const char *host, int timeout_ms);                 /* 0 if not found */

/* one-shot: output buffers are malloc'd (NUL terminated), free() them */
int  adbapi_shell(const char *host, int port, const char *cmd, char **out, size_t *outlen, int *exit_code);
int  adbapi_service(const char *host, int port, const char *service, uint8_t **out, size_t *outlen);

/* streaming session (terminal, logcat, ...).  kind: 1 stdout, 2 stderr, 3 exit (data[0]=code) */
typedef struct adbapi_stream adbapi_stream;
typedef void (*adbapi_data_cb)(int kind, const uint8_t *data, size_t len, void *user);
adbapi_stream *adbapi_stream_new(const char *host, int port, const char *service, int framed,
                                 adbapi_data_cb cb, void *user);
int  adbapi_stream_run(adbapi_stream *s);                 /* blocks; returns exit code or -1 */
void adbapi_stream_send(adbapi_stream *s, const void *data, size_t len);   /* any thread */
void adbapi_stream_stop(adbapi_stream *s);                                  /* any thread */
void adbapi_stream_free(adbapi_stream *s);                /* only after run() returned */

typedef void (*adbapi_progress_cb)(uint64_t done, uint64_t total, void *user);
int  adbapi_push(const char *host, int port, const char *local, const char *remote,
                 adbapi_progress_cb cb, void *user);
int  adbapi_pull(const char *host, int port, const char *remote, const char *local,
                 uint64_t total_hint, adbapi_progress_cb cb, void *user);

/* TCP port forward: 127.0.0.1:local_port -> device "tcp:N" (or any service string) */
typedef struct adbapi_fwd adbapi_fwd;
adbapi_fwd *adbapi_forward_start(const char *host, int port, int local_port, const char *remote_service,
                                 int bind_all);
void adbapi_forward_stop(adbapi_fwd *f);

#ifdef __cplusplus
}
#endif
#endif
