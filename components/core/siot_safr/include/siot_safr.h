/* siot_safr — SAFR v3 on the device: codec, crypto, counters, replay, dedupe,
 * dispatcher (brief §5). The ONLY public header of the component.
 *
 * Wire format: docs/safr/protocol-safr-v3.md — the single source of truth.
 * Do NOT document the layout here; change the spec first, then the code.
 *
 * Ported from pocs/components/safr (safr_proto.h, safr_frame.h/.c, which came
 * from mocked-device/main/safr_*.[ch]). Codec behaviour is unchanged except
 * SAFR_MAX_FRAME = 250 (spec §3, v3.1 2026-09-22: ESP-NOW payload limit).
 * Counters, replay, dedupe and the dispatcher are new in this component;
 * the dedupe table is the one from pocs/node/main/node_mesh.c.
 *
 * Threading: one CCM context and one state lock, both behind src/safr_port.h.
 * siot_safr_rx() runs in the net task; siot_safr_send() may be called from
 * any task, including from inside a handler.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* =========================================================================
 * Protocol constants (spec §3–§7) — from pocs/components/safr/safr_proto.h
 * ========================================================================= */

#define SAFR_SOF        0xA5
#define SAFR_VER        0x03

#define SAFR_HDR_LEN    30   /* header == CCM AAD, bytes 0..29 */
#define SAFR_TAG_LEN    16
#define SAFR_CRC_LEN    2
#define SAFR_NONCE_LEN  12   /* SRC_MAC(6) ‖ BOOT_CTR(2) ‖ MSG_CTR(4) */
#define SAFR_MIN_FRAME  34
#define SAFR_MAX_FRAME  250  /* spec §3 (v3.1): ESP-NOW limit; POC had 256 */
#define SAFR_MAX_PAYLOAD (SAFR_MAX_FRAME - SAFR_HDR_LEN - SAFR_TAG_LEN - SAFR_CRC_LEN) /* 202 */

/* MSG_TYPE */
#define SAFR_MSG_EVENT          0x01
#define SAFR_MSG_HEARTBEAT      0x02
#define SAFR_MSG_TOPOLOGY       0x03
#define SAFR_MSG_ACK            0x04
#define SAFR_MSG_COMMAND        0x05
#define SAFR_MSG_TIME_SYNC      0x06
#define SAFR_MSG_EVENT_LOG_REQ  0x07
#define SAFR_MSG_EVENT_LOG_DATA 0x08
#define SAFR_MSG_INSTALLATION   0x09 /* v3.1, POC round 1 -- spec §7.10 */
#define SAFR_MSG_NAME_ANNOUNCE  0x0A /* v3.1, POC round 1 -- spec §7.11 */

/* FLAGS */
#define SAFR_F_ENC      0x01
#define SAFR_F_ACK_REQ  0x02
#define SAFR_F_RETX     0x04 /* ≤60 s re-announcement of same event (NFPA 72) */

/* EVENT_TYPE */
#define SAFR_EVT_OK       0x01
#define SAFR_EVT_ALERT    0x02
#define SAFR_EVT_ALARM    0x03
#define SAFR_EVT_TROUBLE  0x04

/* EVENT_CODE */
#define SAFR_EC_NONE          0x00
#define SAFR_EC_SMOKE_ALARM   0x01
#define SAFR_EC_HEAT_ALARM    0x02
#define SAFR_EC_SMOKE_RISING  0x03
#define SAFR_EC_MANUAL_TEST   0x04
#define SAFR_EC_TAMPER        0x05
#define SAFR_EC_BATT_LOW      0x06
#define SAFR_EC_BATT_CRIT     0x07
#define SAFR_EC_SENSOR_FAULT  0x08
#define SAFR_EC_COMM_FAULT    0x09
#define SAFR_EC_AC_LOST       0x0A
#define SAFR_EC_RESTORE       0x0B
#define SAFR_EC_RF_INTERF     0x0C

/* EVENT payload length (spec §7.1: v3 = 15 + DEV_SEQ) */
#define SAFR_EVENT_LEN  17

/* EVENT_LOG_DATA (spec §7.9) */
#define SAFR_LOG_DATA_LEN   28
#define SAFR_LOG_F_LAST     0x01
#define SAFR_LOG_F_EMPTY    0x02
#define SAFR_LOG_BATCH_DEF  32

/* PWR_FLAGS */
#define SAFR_PWR_AC_OK        0x01
#define SAFR_PWR_CHARGING     0x02
#define SAFR_PWR_ON_BATTERY   0x04
#define SAFR_PWR_TAMPER       0x08
#define SAFR_PWR_TEST_PRESSED 0x10

/* FAULT_FLAGS / FAULT_CODE */
#define SAFR_FLT_SMOKE_SENSOR 0x01
#define SAFR_FLT_TEMP_SENSOR  0x02
#define SAFR_FLT_BATT_CRIT    0x04
#define SAFR_FLT_MESH_LOST    0x08
#define SAFR_FLT_RELAY_FAIL   0x10

/* NODE_ROLE */
#define SAFR_ROLE_ROOT  0
#define SAFR_ROLE_NODE  1
#define SAFR_ROLE_LEAF  2

/* COMMAND CMD */
#define SAFR_CMD_LINK_CHECK 0x00 /* downlink supervision no-op (§9.3) */
#define SAFR_CMD_SILENCE    0x01
#define SAFR_CMD_TEST       0x02
#define SAFR_CMD_RELAY_SET  0x03
#define SAFR_CMD_IDENTIFY   0x04
#define SAFR_CMD_RESET      0x05 /* operator reset — only alarm-latch clear */
#define SAFR_CMD_GET_INSTALLATION 0x10 /* v3.1, POC round 1 -- spec §7.6 */
#define SAFR_CMD_SET_INSTALLATION 0x11 /* v3.1, Case B only -- ARGS undefined (brief §14 item 1) */

/* ACK STATUS */
#define SAFR_ACK_OK          0x00
#define SAFR_ACK_ERROR       0x01
#define SAFR_ACK_UNKNOWN_DST 0x02

/* Sentinels */
#define SAFR_NA_U8   0xFF
#define SAFR_NA_U16  0xFFFF
#define SAFR_NA_I16  0x7FFF
#define SAFR_NA_RSSI 0x7F

/* TTL at origin = SAFR_TTL_MAX − level; HOPS at origin = level (spec §3). */
#define SAFR_TTL_MAX 7

/* Reserved MAC of the central on the serial link; broadcast / "to central". */
extern const uint8_t SAFR_CENTRAL_MAC[6];
extern const uint8_t SAFR_BCAST_MAC[6];

/* =========================================================================
 * Codec (from safr_frame.h/.c) — stateless apart from SYSTEM_ID + key
 * ========================================================================= */

typedef struct {
    uint8_t  msg_type;
    uint16_t msg_id;
    uint16_t system_id;
    uint8_t  src_mac[6];
    uint8_t  dst_mac[6];
    uint8_t  ttl;
    uint8_t  hops;
    uint8_t  flags;
    uint16_t boot_ctr;
    uint32_t msg_ctr;
    uint8_t  payload[SAFR_MAX_PAYLOAD];
    size_t   payload_len;
} siot_safr_frame_t;

/* CRC-16/CCITT-FALSE (spec §5): check value crc16("123456789") == 0x29B1. */
uint16_t siot_safr_crc16(const uint8_t *data, size_t len);

/* Builds a complete encrypted frame into `out` (>= SAFR_MAX_FRAME bytes) with
 * the SYSTEM_ID and key given to siot_safr_init(). F_ENC is forced on.
 * Returns the frame length, or 0 on error (payload too long, CCM failure).
 * Byte-exact with pocs/components/safr and Appendix A of the spec. */
size_t siot_safr_build_frame(uint8_t *out,
                             uint8_t msg_type,
                             uint16_t msg_id,
                             const uint8_t src_mac[6],
                             const uint8_t dst_mac[6],
                             uint8_t ttl,
                             uint8_t hops,
                             uint8_t flags,
                             uint16_t boot_ctr,
                             uint32_t msg_ctr,
                             const uint8_t *payload,
                             size_t payload_len);

typedef enum {
    SIOT_SAFR_PARSE_OK = 0,
    SIOT_SAFR_PARSE_BAD_FRAME,   /* SOF / VER / LEN bounds / LEN≠len / CRC */
    SIOT_SAFR_PARSE_FOREIGN,     /* SYSTEM_ID ≠ ours — dropped before decrypt (§3.1) */
    SIOT_SAFR_PARSE_AUTH_FAILED, /* CCM tag mismatch: wrong key / nonce / AAD */
} siot_safr_parse_result_t;

/* Validates SOF/VER/LEN/CRC, checks SYSTEM_ID, decrypts (or copies a
 * plaintext payload when F_ENC is clear) and fills `rx`. Does NOT apply the
 * plaintext policy, replay check or dedupe — that is siot_safr_rx(). */
siot_safr_parse_result_t siot_safr_parse_frame(const uint8_t *buf, size_t len,
                                               siot_safr_frame_t *rx);

/* =========================================================================
 * Device-side state: identity, counters, TX
 * ========================================================================= */

/* Delivers a built frame to the link layer. `dst_mac` is the frame's DST_MAC
 * (broadcast/central or one device) so the backend can route. Called with no
 * siot_safr lock held. */
typedef void (*siot_safr_tx_fn)(const uint8_t *frame, size_t len,
                                const uint8_t dst_mac[6], void *ctx);

typedef struct {
    uint16_t system_id;        /* the installation's SYSTEM_ID (≠ 0 in production) */
    uint8_t  safr_psk[16];     /* the installation's AES-128-CCM key */
    uint8_t  src_mac[6];       /* our STA MAC — SRC_MAC of every frame we build */
    uint16_t boot_ctr;         /* persisted + incremented per boot by the caller (siot_config) */
    int64_t (*now_ms)(void);   /* monotonic clock for the dedupe/replay tables (required) */
    bool     allow_plaintext;  /* bench only: accept F_ENC = 0 frames (spec §4.1). Default false */
} siot_safr_config_t;

/* Resets every table and counter (MSG_ID → 0, MSG_CTR → 0), installs the key.
 * May be called again (e.g. after provisioning) — handlers are kept. */
esp_err_t siot_safr_init(const siot_safr_config_t *cfg);

/* Where siot_safr_send() delivers frames. NULL disables sending. */
void siot_safr_set_tx(siot_safr_tx_fn fn, void *ctx);

/* Mesh level at origin: TTL = 7 − level, HOPS = level (spec §3). Board = 0. */
void siot_safr_set_level(uint8_t level);

/* Next MSG_ID for a NEW transmission group (spec §6): fast retries reuse it,
 * a 60 s re-announcement takes a new one. */
uint16_t siot_safr_next_msg_id(void);

/* Builds a frame from this device (fresh MSG_CTR every call — a CCM nonce is
 * never reused, spec §4) and hands it to the TX callback.
 *   ESP_ERR_INVALID_STATE  not initialised or no TX callback
 *   ESP_ERR_INVALID_SIZE   payload > SAFR_MAX_PAYLOAD
 *   ESP_FAIL               CCM failure
 * `flags`: SAFR_F_ACK_REQ / SAFR_F_RETX as needed; F_ENC is always set. */
esp_err_t siot_safr_send(const uint8_t dst_mac[6], uint8_t msg_type, uint16_t msg_id,
                         uint8_t flags, const uint8_t *payload, size_t payload_len);

/* =========================================================================
 * RX pipeline + dispatcher (spec §10 steps 3–10)
 * ========================================================================= */

/* `frame` is the parsed view; `raw`/`raw_len` are the exact wire bytes, for
 * relays that forward frames unchanged (the board to the tablet, a node to
 * its children — spec §4: never re-encoded).
 * `duplicate` = the frame passed every check but its (SRC_MAC, MSG_ID) was
 * seen within the dedupe window: do not process again, but ACK / forward if
 * the protocol says so ("process once, ACK every time", spec §9.1). Runs in
 * the caller's task (net task); must not block. */
typedef void (*siot_safr_handler_t)(const siot_safr_frame_t *frame, const uint8_t *raw,
                                    size_t raw_len, bool duplicate, void *ctx);

/* One handler per MSG_TYPE; registering the same type again replaces it.
 * ESP_ERR_NO_MEM when CONFIG_SIOT_SAFR_HANDLERS_MAX distinct types exist. */
esp_err_t siot_safr_register(uint8_t msg_type, siot_safr_handler_t handler, void *ctx);
esp_err_t siot_safr_unregister(uint8_t msg_type);

typedef enum {
    SIOT_SAFR_RX_OK = 0,             /* dispatched to a handler (duplicate = false) */
    SIOT_SAFR_RX_DUPLICATE,          /* dispatched with duplicate = true */
    SIOT_SAFR_RX_NO_HANDLER,         /* valid, new, nobody registered for MSG_TYPE */
    SIOT_SAFR_RX_BAD_FRAME,          /* SOF/VER/LEN/CRC */
    SIOT_SAFR_RX_FOREIGN,            /* other installation */
    SIOT_SAFR_RX_PLAINTEXT_REJECTED, /* F_ENC = 0 and !allow_plaintext */
    SIOT_SAFR_RX_AUTH_FAILED,        /* CCM tag */
    SIOT_SAFR_RX_REPLAY,             /* (BOOT_CTR, MSG_CTR) ≤ last from same boot */
    SIOT_SAFR_RX_NOT_INIT,
} siot_safr_rx_result_t;

/* One whole frame in (the link layer already reassembled it on SOF+LEN).
 * Order: parse (CRC, SYSTEM_ID, CCM) → plaintext policy → replay → dedupe →
 * handler. Every outcome is counted in the stats. */
siot_safr_rx_result_t siot_safr_rx(const uint8_t *buf, size_t len);

/* =========================================================================
 * Stats (console `safr stats`, exit checklist item 6)
 * ========================================================================= */

typedef struct {
    uint32_t rx_frames;          /* every call to siot_safr_rx() */
    uint32_t rx_ok;              /* dispatched, new */
    uint32_t dup;                /* dispatched, duplicate */
    uint32_t no_handler;
    uint32_t bad_frame;          /* SOF/VER/LEN/CRC ("quadro corrompido") */
    uint32_t foreign;            /* SYSTEM_ID mismatch, not decrypted */
    uint32_t plaintext_rejected;
    uint32_t auth;               /* CCM failures ("verifique a chave") */
    uint32_t replay;
    uint32_t tx_frames;          /* frames handed to the TX callback */
    uint32_t tx_failed;
} siot_safr_stats_t;

void siot_safr_get_stats(siot_safr_stats_t *out);
void siot_safr_reset_stats(void);

#ifdef __cplusplus
}
#endif
