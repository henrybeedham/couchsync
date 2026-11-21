// C interface to the Rust iroh bridge in net/src/lib.rs.
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum {
    CS_EVENT_INCOMING = 1,
    CS_EVENT_READY = 2,
    CS_EVENT_DATA = 3,
    CS_EVENT_CLOSED = 4,
};

typedef void (*cs_event_fn)(void *ctx, uint64_t conn, int32_t kind, const uint8_t *data, size_t len);

bool cs_net_start(const uint8_t *secret, cs_event_fn callback, void *ctx);
void cs_net_generate_secret(uint8_t *out);
bool cs_net_code_for_secret(const uint8_t *secret, char *out, size_t out_len);
bool cs_net_is_code(const char *s);
void cs_net_set_accepting(bool on);
uint64_t cs_net_connect(const char *code);
void cs_net_send(uint64_t conn, const uint8_t *data, size_t len);
void cs_net_close(uint64_t conn);
