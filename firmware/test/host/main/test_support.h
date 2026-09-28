/* Shared fixtures for the host tests: Appendix A inputs, a fake clock and a
 * TX sink that captures the last frame siot_safr_send() produced. */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "siot_safr.h"

/* Appendix A common inputs (docs/safr/protocol-safr-v3.md). */
extern const uint8_t  TV_PSK[16];        /* 25118BA1DD19B84509DF36E9416B8DBE */
extern const uint8_t  TV_SRC_MAC[6];     /* 5A:46:52:00:00:01 */
#define TV_SYSTEM_ID 0x5346
#define TV_BOOT_CTR  0x0001

/* A different unit on the same installation (the receiver in most tests). */
extern const uint8_t  TS_OTHER_MAC[6];   /* 5A:46:52:00:00:99 */

/* Fake monotonic clock handed to siot_safr_init(). */
void    ts_clock_set(int64_t ms);
void    ts_clock_advance(int64_t ms);
int64_t ts_clock_now(void);

/* siot_safr_init() with the Appendix A key/system id, `src_mac` as our MAC,
 * `boot_ctr`, the fake clock, plaintext disallowed. Resets the TX sink. */
void ts_safr_init(const uint8_t src_mac[6], uint16_t boot_ctr);

/* TX sink: siot_safr_send() output. */
extern uint8_t ts_tx_frame[SAFR_MAX_FRAME];
extern size_t  ts_tx_len;
extern uint8_t ts_tx_dst[6];
extern int     ts_tx_calls;
void ts_tx_sink(const uint8_t *frame, size_t len, const uint8_t dst_mac[6], void *ctx);

/* hex string -> bytes into `out`; returns the length. Asserts on bad input. */
size_t ts_unhex(const char *hex, uint8_t *out, size_t out_sz);
