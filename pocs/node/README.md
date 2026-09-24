# node — AC Mesh-Lite device firmware

Implements the round-1 AC node from `pocs/POC-BRIEF.md` §4.3: joins the
board's installation network via `esp_mesh_lite`, emits SAFR HEARTBEAT/
TOPOLOGY/NAME_ANNOUNCE, reacts to the test button (short press = MANUAL_TEST,
double press = a simulated SMOKE_ALARM, hold >=5s = factory reset), and
answers downlink IDENTIFY/TEST/RESET/TIME_SYNC. Whichever node Mesh-Lite
elects root also bridges SAFR traffic to `pocs/board`'s TCP listener at
`192.168.4.1:5340`.

## Not compiled

No ESP-IDF toolchain was available in the environment this was written in
(same situation `pocs/autoconnect/README.md` already documents) — build it
before flashing, and expect to fix real compile errors, especially in
`node_mesh.c` (see below).

## Mesh-Lite API — verify before building

`espressif/mesh_lite`'s `User_Guide.md` and header comments were fetched
during this task (WebFetch/WebSearch), but the fetch tooling summarizes
rather than returning raw file contents, so several specifics could not be
pinned down with certainty. Confirmed function names actually used here:

- `esp_mesh_lite_send_raw_msg_to_root(data, size)` — uplink, any non-root
  node; Mesh-Lite is documented to forward it hop-by-hop to the root itself
  (blueprint `docs/others/system-blueprint-v1.md` §4 step 4), so `node_mesh.c` never
  manually relays a descendant's frame.
- `esp_mesh_lite_send_broadcast_raw_msg_to_child(data, size)` — downlink,
  called by every node that receives a downlink frame (not just the root),
  because whether Mesh-Lite's own broadcast already propagates past one hop
  was **not** confirmed — see the dedup/re-broadcast loop-guard in
  `node_mesh.c`'s `handle_downlink_frame()`. If it turns out Mesh-Lite does
  go further than one hop by itself, this is still correct (just a few
  harmless deduped resends), so it was left in as the safe default.
- `esp_mesh_lite_raw_msg_action_list_register()`, `esp_mesh_lite_get_level()`,
  `esp_mesh_lite_set_mesh_id()`, `esp_mesh_lite_set_allowed_level()`,
  `esp_mesh_lite_set_router_config()`, `esp_mesh_lite_core_init()`,
  `esp_mesh_lite_get_nodes_list()`.

**Not confirmed — marked `TODO(verify)` at each call site in `node_mesh.c`:**

- Whether `esp_mesh_lite_core_init()` is actually the right "bring the stack
  up" call, or whether a higher-level `esp_mesh_lite_init()` wrapper exists
  and should be used instead/as well.
- `esp_mesh_lite_config_t`'s exact field names (assumed `softap_ssid`/
  `softap_password`) and `mesh_lite_sta_config_t`'s exact field names
  (assumed `ssid`/`password`) — the real struct definitions live in a port
  header this task's fetches did not reach.
- How `esp_mesh_lite_raw_msg_action_t.msg_id` actually correlates to a call
  to `esp_mesh_lite_send_raw_msg_to_root()`/`..._to_child()`, which take no
  `msg_id` parameter in the signatures found. `NODE_MESH_UPLINK_MSG_ID` /
  `NODE_MESH_DOWNLINK_MSG_ID` in `node_mesh.c` are a best-effort guess.
- `esp_mesh_lite_get_nodes_list()`'s scope (this node's direct children only,
  vs. the whole mesh subtree) — `node_mesh_get_children()` filters by
  `level == my_level + 1` as an approximation; it also has no RSSI field, so
  `CHILD_RSSI` in TOPOLOGY is reported as `SAFR_NA_RSSI` throughout.
- `raw_msg_process_cb_t`'s exact signature — `on_uplink_raw_msg`/
  `on_downlink_raw_msg` in `node_mesh.c` guess at
  `esp_err_t (*)(uint8_t *data, uint32_t size, uint8_t **outbuf, uint32_t *outlen, const uint8_t addr[6])`
  (data/size/optional-response-out/sender-addr, the common shape for this
  kind of Espressif callback) — the real typedef was not reached by the
  fetches available while writing this; fix the signature to match before
  building if the compiler disagrees.

None of this affects the SAFR side (framing, payload layouts, retry/re-announce
state machine) — that part follows `mocked-device/main/mesh_sim.c` and
`docs/safr/protocol-safr-v3.md` directly and has no such uncertainty.

## What's real / confirmed

- `esp_wifi_sta_get_ap_info()` (standard ESP-IDF Wi-Fi API, not Mesh-Lite
  specific) is used for PARENT_MAC/RSSI_TO_PARENT in HEARTBEAT/TOPOLOGY —
  every Mesh-Lite node's station interface associates to its parent's SoftAP
  (the board's, for the root), so this is a solid, documented mechanism
  regardless of the Mesh-Lite-specific gaps above.
- Root detection is `esp_mesh_lite_get_level() == 1`.
- The board's TCP bridge framing (SOF + LEN resync) in `node_mesh.c`'s
  `reassemble_and_dispatch()` is ported byte-for-byte from
  `mocked-device/main/mocked-device.c`'s `rx_task`.

## Files

| File | Purpose |
|---|---|
| `node.c` | `app_main`: setup-mode vs. normal-mode boot, wiring |
| `node_button.c/h` | GPIO21 debounce, short/double press, 5s factory reset (ported from `pocs/patinha`, double-press added) |
| `node_mesh.c/h` | Mesh-Lite bring-up, uplink/downlink transport, TCP bridge (root only), dedup |
| `node_safr.c/h` | SAFR payload encode/decode, emitter schedule, alarm retry/re-announce, downlink command dispatch |

## Explicitly out of scope

ESP-NOW, battery leaves, flash journal, OTA, cloud/MQTT, viewer app,
`SET_CHANNEL`, siren cause-and-effect, certification hardware, real smoke/
temp sensing (this bench rig has no sensor — EVENT payloads report `n/a`
sentinels for SMOKE/TEMP/HUMIDITY/BATTERY_PCT; only the button drives events).
