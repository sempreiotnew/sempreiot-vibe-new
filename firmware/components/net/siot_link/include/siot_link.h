/* siot_link — moves whole SAFR frames between this unit and the next hop
 * (brief §6). One registry of backends behind link_iface (§6.2); the
 * layers above (netcore, coordinator) see only kinds, never sockets, UARTs
 * or Mesh-Lite.
 *
 *   SIOT_LINK_MESH   node:  Mesh-Lite raw messages to the root, or the root's
 *                           TCP session to the board at 192.168.4.1:5340
 *                    board: the installation AP + TCP server, one client = the root
 *   SIOT_LINK_SERIAL board: the tablet, 115200 8N1 (siot_hal_serial)
 *   (Phase 2)        SIOT_LINK_ESPNOW, no signature changes needed (§6.4)
 *
 * Every backend delivers WHOLE frames; byte-stream backends reassemble with
 * siot_link_reasm_feed (SOF + LEN + CRC, discard one byte on failure — spec
 * §10). Decryption, replay, dedupe and dispatch happen above, in siot_safr.
 *
 * Ported from pocs/node/main/node_mesh.c, pocs/board/main/tcp_link.c and
 * serial_link.c.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "sdkconfig.h"

#include "siot_safr.h"
#ifndef CONFIG_IDF_TARGET_LINUX
#include "siot_config.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    SIOT_LINK_MESH = 0,
    SIOT_LINK_SERIAL,
    /* Phase 2: SIOT_LINK_ESPNOW */
    SIOT_LINK_KIND_MAX
} siot_link_kind_t;

/* One whole frame arrived on `kind`. Runs in the backend's rx task. */
typedef void (*siot_link_rx_cb_t)(siot_link_kind_t kind, const uint8_t *frame, size_t len, void *ctx);

typedef struct {
    esp_err_t (*start)(void);
    esp_err_t (*stop)(void);
    esp_err_t (*send)(const uint8_t *dst_mac, const uint8_t *frame, size_t len); /* raw SAFR frame */
    bool      (*is_up)(void);
    int       (*rssi)(void);     /* dBm, 0 when meaningless */
} siot_link_ops_t;

/* ---- registry (link_iface) ------------------------------------------- */

esp_err_t siot_link_register(siot_link_kind_t kind, const siot_link_ops_t *ops);
esp_err_t siot_link_set_rx(siot_link_rx_cb_t cb, void *ctx);
esp_err_t siot_link_start(siot_link_kind_t kind);
esp_err_t siot_link_stop(siot_link_kind_t kind);
/* ESP_ERR_INVALID_STATE when the backend is missing or down (frame dropped,
 * the caller's retry logic decides what to do). */
esp_err_t siot_link_send(siot_link_kind_t kind, const uint8_t *dst_mac,
                         const uint8_t *frame, size_t len);
bool      siot_link_is_up(siot_link_kind_t kind);
int       siot_link_rssi(siot_link_kind_t kind);

/* Backends hand a whole frame up with this. */
void siot_link_deliver(siot_link_kind_t kind, const uint8_t *frame, size_t len);

/* ---- byte-stream reassembler (spec §10 steps 1–3) --------------------- */

typedef struct {
    uint8_t acc[2 * SAFR_MAX_FRAME];
    size_t  len;
} siot_link_reasm_t;

void siot_link_reasm_reset(siot_link_reasm_t *r);

/* Appends `n` bytes, delivers every complete frame whose SOF, LEN (34..250)
 * and CRC check out via siot_link_deliver(kind, ...), discards exactly one
 * byte on any failure and rescans. Returns the number of frames delivered.
 * The accumulator is reset when it would overflow. */
size_t siot_link_reasm_feed(siot_link_reasm_t *r, siot_link_kind_t kind, const uint8_t *chunk, size_t n);

/* ---- byte stream that also carries raw runs (protocol §13.3) ------------- */

/* One piece of a raw run: `len` bytes, `left` still to come (0 = the run is
 * complete). `data == NULL` = the run was aborted (the sender went silent);
 * no more calls follow for it. */
typedef void (*siot_link_raw_cb_t)(const uint8_t *data, size_t len, size_t left, void *ctx);

typedef struct {
    siot_link_reasm_t  reasm;
    size_t             raw_left;
    siot_link_raw_cb_t raw_cb;
    void              *raw_ctx;
    uint32_t           good;     /* frames delivered + raw bytes handed over: noise never counts */
} siot_link_stream_t;

void siot_link_stream_reset(siot_link_stream_t *s);

/* Frames go to siot_link_deliver(kind, ...). A frame's handler may call
 * siot_link_stream_expect_raw(): the next `len` bytes of the stream are then
 * handed to `cb` as they are — never scanned for SOF — and frames resume
 * after them. */
void siot_link_stream_feed(siot_link_stream_t *s, siot_link_kind_t kind, const uint8_t *data, size_t n);
esp_err_t siot_link_stream_expect_raw(siot_link_stream_t *s, size_t len, siot_link_raw_cb_t cb, void *ctx);
void siot_link_stream_abort_raw(siot_link_stream_t *s);

#ifndef CONFIG_IDF_TARGET_LINUX
/* ---- backends: init registers the ops; siot_link_start() brings it up --- */

/* Node: Mesh-Lite with this installation's router SSID/PSK, mesh id and
 * channel (brief §6.3), plus the root's TCP client to the board. */
esp_err_t siot_link_mesh_node_init(const siot_installation_t *code);

/* Board: installation AP (net_ssid/net_psk/channel, 192.168.4.1) + TCP
 * server on :5340, one client (the current root, newest wins). */
esp_err_t siot_link_mesh_board_init(const siot_installation_t *code);

/* Board: the tablet link over siot_hal_serial. */
esp_err_t siot_link_serial_init(void);

/* Board, from inside the handler of a frame that arrived on the serial link
 * (it runs in the link's rx task): the next `len` bytes are raw (§13.3
 * OTA_PUSH_CHUNK). 1 s without a byte aborts the run. */
esp_err_t siot_link_serial_expect_raw(size_t len, siot_link_raw_cb_t cb, void *ctx);

/* Board: line speed of the tablet link (§13.3 OTA_BAUD). What is queued
 * leaves at the old speed first. 20 s without a byte at any speed but the
 * default puts the link back at the default. */
esp_err_t siot_link_serial_set_baud(uint32_t baud);

/* Board admin window (lifecycle §11): swap the one SoftAP to the setup
 * network (SSID/password/channel given) and back to the installation AP. */
esp_err_t siot_link_mesh_board_suspend(const char *ssid, const char *pass, uint8_t channel);
esp_err_t siot_link_mesh_board_resume(void);

/* ---- mesh queries (node backend; 0 / false on the board) --------------- */

uint8_t siot_link_mesh_level(void);                       /* 0 = not joined, 1 = root */
bool    siot_link_mesh_parent(uint8_t mac[6], int8_t *rssi); /* STA's AP: parent, or the board when root */
size_t  siot_link_mesh_children(uint8_t (*macs)[6], int8_t *rssi, size_t max); /* direct children */
bool    siot_link_mesh_board_up(void);                    /* root with the TCP session open */

/* Node: push a downlink frame one hop further, to this node's own children
 * (brief §6.3; the caller dedupes so it is a loop-safe re-broadcast). */
esp_err_t siot_link_mesh_broadcast_children(const uint8_t *frame, size_t len);
#endif

#ifdef __cplusplus
}
#endif
