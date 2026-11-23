/* siot_link — moves whole SAFR frames between this unit and the next hop
 * (brief §6). One registry of backends behind link_iface (§6.2); the
 * layers above (netcore, coordinator) see only kinds, never sockets, UARTs
 * or Mesh-Lite.
 *
 *   SIOT_LINK_MESH   node:  Mesh-Lite raw messages to the root, or the root's
 *                           TCP session to the board at 192.168.4.1:5340
 *                    board: the installation AP + TCP server, one client = the
 *                           root — ONE root, kept by the board (see "one root")
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

/* ---- one root (blueprint §4, protocol §7.6 ROOT_YIELD) ------------------ */

/* A root that works is left alone (decided 2026-11-05): a second unit attached
 * to the board takes the root only when the root's own link is WEAK — below
 * the protocol's weak-link level, the one the map paints red (spec §9.4) —
 * and the board hears the newcomer at least SIOT_LINK_ROOT_TAKEOVER_DB
 * better. A root that moves, moves the whole tree with it. */
#define SIOT_LINK_ROOT_WEAK_DBM    (-85)
#define SIOT_LINK_ROOT_TAKEOVER_DB 10

/* The board's rule, when a second unit dials while the root is alive: does
 * the newcomer (the challenger) take the root? Signals are what the board's
 * AP measures of each station, in dBm; unknown on either side = the root
 * stays. Pure: tested on the host (test/host test_root_arbiter.c). */
bool siot_link_root_challenger_wins(bool root_known, int root_rssi,
                                    bool challenger_known, int challenger_rssi);

#ifndef CONFIG_IDF_TARGET_LINUX
/* ---- backends: init registers the ops; siot_link_start() brings it up --- */

/* Node: Mesh-Lite with this installation's router SSID/PSK, mesh id and
 * channel (brief §6.3), plus the root's TCP client to the board. */
esp_err_t siot_link_mesh_node_init(const siot_installation_t *code);

/* Board: installation AP (net_ssid/net_psk/channel, 192.168.4.1) + TCP
 * server on :5340, one client: the root. ONE root (blueprint §4): a second
 * unit that dials while the root is alive is told to yield — or takes the
 * root, when the root's link is weak and the board hears the newcomer
 * SIOT_LINK_ROOT_TAKEOVER_DB better, and then the old root is told
 * (link_mesh_board.c). */
esp_err_t siot_link_mesh_board_init(const siot_installation_t *code);

/* Board: who writes the ROOT_YIELD frame (protocol §7.6) the board sends to a
 * unit that must leave level 1 — the layer that owns SAFR (siot_coordinator).
 * `root_mac` is the unit that keeps the root (zeros when unknown). Returns
 * the frame length written to `out`, 0 = nothing to send. Runs in the link's
 * server task. Without one the unit is only disconnected. */
typedef size_t (*siot_link_root_yield_fn)(const uint8_t root_mac[6], uint8_t *out, size_t cap);
void siot_link_mesh_board_set_root_yield(siot_link_root_yield_fn fn);

/* Board: the central chose `mac` to be the root (protocol §7.6 ROOT_TAKE,
 * v3.11). For SIOT_LINK_ROOT_DESIGNATE_MS, when that unit dials while the
 * root is alive it takes the root whatever the signals say, and the old root
 * is told to yield. Nothing happens until it dials: a unit that never
 * reaches the board changes nothing. Safe from any task. */
#define SIOT_LINK_ROOT_DESIGNATE_MS 60000
void siot_link_mesh_board_designate_root(const uint8_t mac[6]);

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

/* 0 = not joined, 1 = root. A unit is the root only with its station on the
 * BOARD's access point: the library's "level 1" under another unit (a parent
 * that came back with no level) or attached to nothing (still trying the
 * board, or the board was lost) is reported 0 — not a root, not in the mesh
 * (link_mesh_node.c, mesh_level). */
uint8_t siot_link_mesh_level(void);
bool    siot_link_mesh_parent(uint8_t mac[6], int8_t *rssi); /* STA's AP: parent, or the board when root */
size_t  siot_link_mesh_children(uint8_t (*macs)[6], int8_t *rssi, size_t max); /* direct children */
bool    siot_link_mesh_board_up(void);                    /* root with the TCP session open */

/* Node, on ROOT_YIELD from the board (protocol §7.6): this unit is at level 1
 * and another unit is the root. It closes its access point (its own units
 * leave and find the mesh), leaves the board and may not come back to level 1
 * until it has a parent in the mesh — or for 90 s when it finds none (the root
 * may be gone by then: failover). Nothing when it is not at level 1. Safe from
 * the link's rx path: the mesh task does the work. */
void siot_link_mesh_yield_root(void);

/* Node, on ROOT_TAKE from the central (protocol §7.6, v3.11): this unit is a
 * child and the central chose it to be the root. It leaves its parent and may
 * be at level 1 only, so it attaches to the board; the restriction goes as
 * soon as it has its session with the board, or after 45 s when it never got
 * there (it then looks for a parent as any unit does). Nothing for a unit
 * that is not attached to another unit. Safe from the link's rx path: the
 * mesh task does the work. */
void siot_link_mesh_take_root(void);

/* Node: how this unit hears the BOARD's access point, in dBm (protocol §7.3
 * BOARD_RSSI, v3.11) — the root from its own station, any other unit by
 * listening to the board's beacons for 1.5 s once a minute (no scan, no
 * frame sent, the unit stays on its channel). SIOT_LINK_RSSI_NONE = not
 * heard in the last three minutes. */
#define SIOT_LINK_RSSI_NONE 0x7F
int8_t siot_link_mesh_board_rssi(void);

/* Node: one line that says where this unit hangs, for the logs — the
 * library's level, its parent's SSID and signal, its station's address and
 * gateway, its own access point's address. */
void siot_link_mesh_describe(char *out, size_t cap);

/* Node: leave the parent and look for one again — what a RESTART does to the
 * mesh, without restarting. Only for a unit attached to another unit; nothing
 * for the root. Safe from any task: the mesh task does the work. */
void siot_link_mesh_rejoin(void);

/* Node: for how many seconds in a row this unit has been out of the mesh —
 * attached neither to a unit (as a child) nor to the board (as the root).
 * 0 = it is in the mesh, or it is attached to nothing while its Wi-Fi driver
 * says the board's access point is not on the air. For the unit's own log
 * (link_mesh_node.c, OUT_LOG_MS); the restart of a unit with no path is
 * siot_netcore's, by what comes down from the central. */
uint32_t siot_link_mesh_out_s(void);

/* Node: the tree this unit is in is whole and the CENTRAL is what is missing
 * (protocol §7.16 HELD, v3.14) — it is the root that had its session with
 * the board and lost the board, or its parent says so. Such a unit keeps
 * still: it does not restart itself for having no path. */
bool siot_link_mesh_tree_held(void);

/* Node: what the link did about a lost path since the last call with `reset`
 * — for the outage record (protocol §7.17 OUTAGE_REPORT, v3.14). */
#define SIOT_LINK_OUT_NONE          0
#define SIOT_LINK_OUT_BOOT          1 /* (siot_netcore) no path since the unit started */
#define SIOT_LINK_OUT_PARENT_LOST   2 /* the parent went off the air */
#define SIOT_LINK_OUT_PARENT_SILENT 3 /* attached, and nothing of the central came down */
#define SIOT_LINK_OUT_BOARD_LOST    4 /* the root: its session with the board dropped */
#define SIOT_LINK_OUT_YIELD         5 /* at the board, and not its root: told to yield, or never proven */
#define SIOT_LINK_OUT_MOVE          6 /* it left its parent by itself, for a unit with a better path (v3.15) */
#define SIOT_LINK_OUT_F_ORPHAN   0x01 /* it held the root's role with no board in reach */
#define SIOT_LINK_OUT_F_PATHLESS 0x02 /* it was under a parent with no path */
#define SIOT_LINK_OUT_F_NOWHERE  0x04 /* it was attached to nothing, as a child */
typedef struct {
    uint8_t cause;        /* SIOT_LINK_OUT_*: how it began (the first one counts) */
    uint8_t flags;        /* SIOT_LINK_OUT_F_* */
    uint8_t rescues;      /* moves to a neighbour that said it had a path */
    uint8_t rescue_fails; /* ...that did not get there in time */
    uint8_t any_rounds;   /* rounds of "any parent the library finds" */
    bool    rescued;      /* one of those moves got there */
} siot_link_recovery_t;
void siot_link_mesh_recovery(siot_link_recovery_t *out, bool reset);

/* Node: the last time this unit left its parent for a BETTER path (the best
 * path, below — never a rescue), for the record (protocol §7.17 v3.15): the
 * central is told of every such move, so a reorganisation is never read as a
 * unit that dropped. `started_ms` / `ended_ms` are on esp_timer's clock. */
#define SIOT_LINK_MOVE_NONE   0
#define SIOT_LINK_MOVE_GOING  1 /* it left, and is not on the new parent yet */
#define SIOT_LINK_MOVE_MOVED  2 /* it is on the parent it went for */
#define SIOT_LINK_MOVE_MISSED 3 /* it did not reach it in time: any parent now */
typedef struct {
    uint8_t state;        /* SIOT_LINK_MOVE_* */
    uint8_t to[6];        /* the unit it went for (its SAFR address) */
    uint8_t from[6];      /* the unit it left; all zero = not known */
    int8_t  path_before;  /* dBm: the path it had */
    int8_t  path_after;   /* dBm: the path the other unit offered */
    int64_t started_ms;
    int64_t ended_ms;     /* MOVED / MISSED: when */
} siot_link_move_t;
void siot_link_mesh_move(siot_link_move_t *out, bool reset);

/* ---- the best path (siot_link_path.h, protocol §7.16 PATH_ADVERT, v3.12) --
 * A unit does not stay under a parent with a weak path when another unit
 * offers a clearly better one: every mains unit says its path on ESP-NOW,
 * every unit compares, and the one with a weak path moves by itself
 * (link_mesh_node.c, "The best path"). siot_netcore owns the frames. */

/* Node: the PATH_ADVERT payload this unit should broadcast now, written to
 * `out` (>= SIOT_PATH_ADVERT_MAX_LEN). 0 = it says nothing: its access point
 * closed, or in the middle of a move. `alarm`: this unit is in alarm — the
 * units around it hear so and none of them moves (SIOT_PATH_F_ALARM_MASK). */
size_t siot_link_mesh_path_advert(uint8_t *out, size_t cap, bool alarm);

/* Node: the PATH_ADVERT of another unit of this installation — its SAFR
 * SRC_MAC, BOOT_CTR and MSG_CTR (an older frame is a replay), the signal it
 * was heard at on ESP-NOW and its payload. Safe from any task. */
void siot_link_mesh_path_heard(const uint8_t id[6], uint16_t boot_ctr, uint32_t msg_ctr, int8_t rssi,
                               const uint8_t *payload, size_t len);

/* Node: this unit's own path — the weakest link between the root and it, dBm
 * (0 = it is the root, with its session to the board) — or
 * SIOT_LINK_RSSI_NONE when it has none it can vouch for: out of the mesh, in
 * a move, or under a parent whose advert is not believed. What its
 * PARENT_OFFER tells a battery unit (protocol §7.15, v3.13). */
int8_t siot_link_mesh_own_path(void);

/* Node: whether this unit may move to a better parent now. False while it is
 * in alarm, not ONLINE, or a command passed not long ago (an operator is
 * working on the installation, or an update runs). Starts false. */
void siot_link_mesh_path_allow(bool allow);

/* Node: push a downlink frame one hop further, to this node's own children
 * (brief §6.3; the caller dedupes so it is a loop-safe re-broadcast). */
esp_err_t siot_link_mesh_broadcast_children(const uint8_t *frame, size_t len);
#endif

#ifdef __cplusplus
}
#endif
