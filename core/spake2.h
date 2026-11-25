/* SPAKE2 (edwards25519) compatible with BoringSSL's implementation as used by
 * the Android ADB wireless pairing protocol.  Pure OpenSSL BIGNUM arithmetic,
 * so the only dependency is libcrypto (>= 1.1.0). */
#ifndef ADBI_SPAKE2_H
#define ADBI_SPAKE2_H
#include <stddef.h>
#include <stdint.h>

#define SPAKE2_MSG_SIZE 32
#define SPAKE2_KEY_SIZE 64

typedef enum { SPAKE2_ALICE = 0, SPAKE2_BOB = 1 } spake2_role;
typedef struct spake2_ctx spake2_ctx;

spake2_ctx *spake2_new(spake2_role role, const uint8_t *my_name, size_t my_len,
                       const uint8_t *their_name, size_t their_len);
/* Returns 1 on success, writes SPAKE2_MSG_SIZE bytes to out. */
int spake2_generate(spake2_ctx *c, uint8_t out[SPAKE2_MSG_SIZE],
                    const uint8_t *password, size_t password_len);
/* Returns 1 on success, writes SPAKE2_KEY_SIZE bytes to key. */
int spake2_process(spake2_ctx *c, uint8_t key[SPAKE2_KEY_SIZE],
                   const uint8_t *their_msg, size_t their_len);
void spake2_free(spake2_ctx *c);
#endif
