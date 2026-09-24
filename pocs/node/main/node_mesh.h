/*
 * Mesh-Lite transport for the AC node -- POC-BRIEF.md §4.3.
 *
 * Uplink: every node hands its own SAFR frames to Mesh-Lite for delivery to
 * the root; Mesh-Lite is documented to do the hop-by-hop forwarding itself
 * (docs/others/system-blueprint-v1.md §4 step 4), so non-root nodes never need to
 * manually relay a descendant's uplink. Only the elected root additionally
 * bridges the raw bytes it receives (its own + everyone else's, arriving via
 * the same Mesh-Lite raw-message channel) onto a TCP socket to the board at
 * 192.168.4.1:5340.
 *
 * Downlink: the root reads frames off that TCP socket and broadcasts them
 * into the mesh. Per POC-BRIEF §4.3 it is NOT confirmed whether Mesh-Lite's
 * broadcast-to-children propagates beyond one hop (see the TODO in
 * node_mesh.c), so every node that receives a downlink frame -- root
 * included, right after reading it off TCP -- re-broadcasts it again to its
 * own children, deduped by (SRC_MAC, MSG_ID) for 30s so this is safe
 * whether or not the underlying transport already goes further by itself.
 */
#pragma once

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#include "prov_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Brings up Mesh-Lite with this installation's router SSID/password,
 * mesh_id and channel, and starts the root's TCP bridge task (dormant on a
 * non-root node until/unless it becomes root). Call once, after
 * safr_frame_init(). */
void node_mesh_start(const siot_installation_t *inst);

/* True once Mesh-Lite has elected this device to level 1 (directly
 * associated to the board's installation AP, i.e. this node bridges to the
 * board's TCP socket). */
bool node_mesh_is_root(void);

uint8_t node_mesh_get_level(void);

/* Parent BSSID/RSSI, read from this node's own STA-to-AP association: in
 * Mesh-Lite every non-root node's station interface associates to its
 * parent's SoftAP, and the root's station associates to the board's
 * installation AP -- so esp_wifi_sta_get_ap_info() reports "the parent"
 * uniformly in both cases. Returns false if not associated yet. */
bool node_mesh_get_parent_info(uint8_t mac_out[6], int8_t *rssi_out);

/* Best-effort direct-children enumeration for TOPOLOGY (spec §7.4). See the
 * TODO in node_mesh.c: esp_mesh_lite_get_nodes_list()'s exact scope (whole
 * subtree vs this node's direct children only) is not confirmed from the
 * docs available while writing this -- verify before trusting CHILD_COUNT
 * on a multi-level mesh. Returns the number of entries written. */
size_t node_mesh_get_children(uint8_t mac_out[][6], int8_t rssi_out[],
                              size_t max_out);

/* Hands a fully-built SAFR frame (as produced by safr_build_frame) to
 * Mesh-Lite for delivery to the root (or, on the root, to the board's TCP
 * socket). Returns true when a live transport accepted it -- false while
 * not joined, or on the root while the board's socket is down. */
bool node_mesh_send_uplink(const uint8_t *frame, size_t len);

/* Root only: true while the TCP socket to the board is open. */
bool node_mesh_board_link_up(void);

/* node_safr registers this once; node_mesh invokes it for every distinct
 * (deduped) downlink frame, whether it arrived from the board's TCP socket
 * (this node is root) or from a parent's broadcast (not root). node_mesh
 * has already re-broadcast the frame to this node's own children by the
 * time the callback runs -- the callback only needs to act on it if
 * DST_MAC is this node's own MAC or broadcast. */
typedef void (*node_mesh_downlink_cb_t)(const uint8_t *frame, size_t len);
void node_mesh_set_downlink_handler(node_mesh_downlink_cb_t cb);

#ifdef __cplusplus
}
#endif
