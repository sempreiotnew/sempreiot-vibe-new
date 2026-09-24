#include "node_mesh.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include "lwip/sockets.h"

#include "esp_log.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "esp_bridge.h"
#include "esp_event.h"
#include "esp_mesh_lite.h"
#include "esp_netif.h"

#include "safr_frame.h"
#include "siot_led.h"

static const char *TAG = "node_mesh";

/* Board's installation AP, per POC-BRIEF §4.2. */
#define BOARD_TCP_IP    "192.168.4.1"
#define BOARD_TCP_PORT  5340
#define TCP_RECONNECT_BACKOFF_MS 2000
#define TCP_CONNECT_TIMEOUT_MS   3000 /* a blocking connect() would sit ~60 s on
                                       * unanswered SYNs (lwip retransmit budget);
                                       * failover measured that on the bench */
#define TCP_KEEPALIVE_IDLE_S     5    /* dead board noticed in ~11 s */
#define TCP_KEEPALIVE_INTVL_S    2
#define TCP_KEEPALIVE_CNT        3
#define STA_INACTIVE_TIME_S      6    /* parent beacon loss -> disconnect; the
                                       * driver default seen on the bench was 25 s */

/* App-chosen ids for the two raw-message channels this project uses.
 * Mesh-Lite raw messages carry a msg_id envelope: the sender goes through
 * esp_mesh_lite_send_msg(ESP_MESH_LITE_RAW_MSG, ...) naming the id and the
 * transport function, and the receiver dispatches on that id to the
 * raw_process callback registered with
 * esp_mesh_lite_raw_msg_action_list_register() (see the library's own use in
 * managed_components/espressif__mesh_lite/src/esp_mesh_lite.c). Calling the
 * transport functions directly with bare SAFR bytes would never reach a
 * callback. 0 is MESH_LITE_MSG_ID_INVALID and 1..3 are taken by the library. */
#define NODE_MESH_UPLINK_MSG_ID    0x53414652u /* "SAFR" */
#define NODE_MESH_DOWNLINK_MSG_ID  0x53414644u /* "SAFD" */

#define DEDUP_CAP   16
#define DEDUP_TTL_MS 30000

typedef struct {
    bool     used;
    uint8_t  src_mac[6];
    uint16_t msg_id;
    int64_t  seen_ms;
} dedup_entry_t;

static siot_installation_t s_inst;
static node_mesh_downlink_cb_t s_downlink_cb;
static dedup_entry_t s_dedup[DEDUP_CAP];
static SemaphoreHandle_t s_dedup_lock;

static int s_tcp_sock = -1;
static SemaphoreHandle_t s_tcp_lock; /* serializes writes from multiple senders */

/* ---- dedupe: (SRC_MAC, MSG_ID) for 30 s, spec-adjacent to the leaf's own
 * dedupe rule in docs/safr/protocol-safr-v3.md §10, reused here for the
 * downlink re-broadcast loop-guard called for in POC-BRIEF §4.3. ---- */

static bool dedup_check_and_insert(const uint8_t src_mac[6], uint16_t msg_id)
{
    const int64_t now_ms = esp_timer_get_time() / 1000;
    xSemaphoreTake(s_dedup_lock, portMAX_DELAY);

    int free_slot = -1;
    for (int i = 0; i < DEDUP_CAP; i++) {
        dedup_entry_t *e = &s_dedup[i];
        if (!e->used || now_ms - e->seen_ms > DEDUP_TTL_MS) {
            if (free_slot < 0) free_slot = i;
            continue;
        }
        if (e->msg_id == msg_id && memcmp(e->src_mac, src_mac, 6) == 0) {
            xSemaphoreGive(s_dedup_lock);
            return true; /* already seen */
        }
    }
    if (free_slot < 0) free_slot = 0; /* evict arbitrary slot, cache is small */
    s_dedup[free_slot] = (dedup_entry_t){
        .used = true, .msg_id = msg_id, .seen_ms = now_ms,
    };
    memcpy(s_dedup[free_slot].src_mac, src_mac, 6);
    xSemaphoreGive(s_dedup_lock);
    return false;
}

/* Single-shot raw send (max_retry = 0: SAFR does its own retries,
 * POC-BRIEF §4.3 forbids Mesh-Lite's retry machinery for SAFR). */
static bool mesh_send_raw(uint32_t msg_id, const uint8_t *data, size_t len,
                          esp_err_t (*transport)(const uint8_t *, size_t))
{
    esp_mesh_lite_msg_config_t cfg = {
        .raw_msg = {
            .msg_id = msg_id,
            .expect_resp_msg_id = 0,
            .max_retry = 0,
            .data = data,
            .size = len,
            .raw_resend = transport,
        },
    };
    esp_err_t err = esp_mesh_lite_send_msg(ESP_MESH_LITE_RAW_MSG, &cfg);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "raw send 0x%08" PRIx32 " failed: %s", msg_id,
                 esp_err_to_name(err));
    }
    return err == ESP_OK;
}

/* ---- root <-> board TCP bridge ---- */

static bool tcp_write_frame(const uint8_t *frame, size_t len)
{
    bool sent = false;
    xSemaphoreTake(s_tcp_lock, portMAX_DELAY);
    if (s_tcp_sock >= 0) {
        sent = send(s_tcp_sock, frame, len, 0) == (int)len;
    }
    xSemaphoreGive(s_tcp_lock);
    return sent;
}

/* Common path for a distinct downlink frame, whichever transport it arrived
 * on: dedupe, hand to node_safr, and push it one more hop into this node's
 * own children (see the file header's rationale). */
static void handle_downlink_frame(const uint8_t *frame, size_t len)
{
    safr_rx_frame_t rx;
    if (!safr_parse_frame(frame, len, &rx)) return; /* corrupt/foreign, drop */

    if (dedup_check_and_insert(rx.src_mac, rx.msg_id)) return;

    siot_led_comm_blink(); /* a downlink frame reached this node */

    if (s_downlink_cb) s_downlink_cb(frame, len);

    /* No-op if this node has no children; harmless if the transport already
     * propagated the broadcast further by itself (children dedupe too). */
    mesh_send_raw(NODE_MESH_DOWNLINK_MSG_ID, frame, len,
                  esp_mesh_lite_send_broadcast_raw_msg_to_child);
}

/* Reassembles a byte stream into SAFR frames: SOF + LEN resync, identical
 * to mocked-device/main/mocked-device.c's rx_task (ported pattern, spec §9,
 * POC-BRIEF §4.2 "reframe with SOF+LEN+CRC exactly like mocked-device.c"). */
static void reassemble_and_dispatch(uint8_t *acc, size_t *acc_len,
                                    const uint8_t *chunk, size_t n)
{
    if (*acc_len + n > SAFR_MAX_FRAME * 2) *acc_len = 0; /* overflow guard */
    memcpy(acc + *acc_len, chunk, n);
    *acc_len += n;

    size_t pos = 0;
    while (*acc_len - pos >= SAFR_MIN_FRAME) {
        if (acc[pos] != SAFR_SOF) { pos++; continue; }
        const size_t flen = ((size_t)acc[pos + 2] << 8) | acc[pos + 3];
        if (flen < SAFR_MIN_FRAME || flen > SAFR_MAX_FRAME) { pos++; continue; }
        if (*acc_len - pos < flen) break; /* wait for more bytes */

        handle_downlink_frame(&acc[pos], flen);
        pos += flen;
    }
    memmove(acc, acc + pos, *acc_len - pos);
    *acc_len -= pos;
}

/* Bounded connect: non-blocking + select(), so an attempt that gets no
 * SYN/ACK (stale route right after the STA came up, board still busy with
 * the dead root's socket) costs TCP_CONNECT_TIMEOUT_MS instead of lwip's
 * full retransmit budget. Returns the connected fd or -1. */
static int tcp_connect_bounded(const struct sockaddr_in *addr)
{
    int sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock < 0) return -1;

    const int flags = fcntl(sock, F_GETFL, 0);
    fcntl(sock, F_SETFL, flags | O_NONBLOCK);

    int rc = connect(sock, (const struct sockaddr *)addr, sizeof(*addr));
    if (rc != 0 && errno != EINPROGRESS) {
        close(sock);
        return -1;
    }
    if (rc != 0) {
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(sock, &wfds);
        struct timeval tv = {
            .tv_sec = TCP_CONNECT_TIMEOUT_MS / 1000,
            .tv_usec = (TCP_CONNECT_TIMEOUT_MS % 1000) * 1000,
        };
        if (select(sock + 1, NULL, &wfds, NULL, &tv) <= 0) {
            close(sock);
            return -1;
        }
        int err = 0;
        socklen_t len = sizeof(err);
        if (getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len) != 0 || err != 0) {
            close(sock);
            return -1;
        }
    }
    fcntl(sock, F_SETFL, flags);

    /* Keepalive: a board that vanishes (power cut) is noticed in
     * idle + intvl * cnt seconds instead of never. */
    const int ka = 1, idle = TCP_KEEPALIVE_IDLE_S, intvl = TCP_KEEPALIVE_INTVL_S,
              cnt = TCP_KEEPALIVE_CNT;
    setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, &ka, sizeof(ka));
    setsockopt(sock, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle));
    setsockopt(sock, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
    setsockopt(sock, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));

    /* recv() wakes every second so the loop re-checks the root role. */
    const struct timeval rto = { .tv_sec = 1, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &rto, sizeof(rto));
    return sock;
}

static void root_tcp_task(void *arg)
{
    static uint8_t acc[SAFR_MAX_FRAME * 2];
    uint8_t chunk[256];

    for (;;) {
        if (!node_mesh_is_root()) {
            /* Lost root status (or never gained it yet) -- park here.
             * node_safr's HEARTBEAT/TOPOLOGY keep running regardless. */
            vTaskDelay(pdMS_TO_TICKS(500));
            continue;
        }

        struct sockaddr_in addr = {
            .sin_family = AF_INET,
            .sin_port = htons(BOARD_TCP_PORT),
        };
        inet_pton(AF_INET, BOARD_TCP_IP, &addr.sin_addr);

        const int sock = tcp_connect_bounded(&addr);
        if (sock < 0) {
            /* Root without a board (board off, or not yet up): keep the mesh,
             * keep trying. Children's frames are dropped meanwhile. */
            ESP_LOGD(TAG, "board TCP connect failed, retrying in %d ms",
                     TCP_RECONNECT_BACKOFF_MS);
            vTaskDelay(pdMS_TO_TICKS(TCP_RECONNECT_BACKOFF_MS));
            continue;
        }

        ESP_LOGI(TAG, "connected to board TCP bridge");
        xSemaphoreTake(s_tcp_lock, portMAX_DELAY);
        s_tcp_sock = sock;
        xSemaphoreGive(s_tcp_lock);

        size_t acc_len = 0;
        for (;;) {
            if (!node_mesh_is_root()) break; /* root failover away from us */
            const int n = recv(sock, chunk, sizeof(chunk), 0);
            if (n < 0 && (errno == EWOULDBLOCK || errno == EAGAIN)) continue; /* SO_RCVTIMEO tick */
            if (n <= 0) break; /* board dropped the connection (or keepalive gave up) */
            reassemble_and_dispatch(acc, &acc_len, chunk, (size_t)n);
        }

        ESP_LOGW(TAG, "board TCP bridge dropped, reconnecting");
        xSemaphoreTake(s_tcp_lock, portMAX_DELAY);
        s_tcp_sock = -1;
        xSemaphoreGive(s_tcp_lock);
        close(sock);
        vTaskDelay(pdMS_TO_TICKS(TCP_RECONNECT_BACKOFF_MS));
    }
}

/* ---- Mesh-Lite raw-message callbacks ---- */

/* Fired (on the elected root only, in principle -- see the msg_id caveat
 * above) when Mesh-Lite delivers a descendant's (or our own) uplink raw
 * message. Bridge it onto the board's TCP socket unchanged. */
/* Signature pinned by mesh_lite's raw_msg_process_cb_t (esp_mesh_lite_core.h):
 * esp_err_t (*)(uint8_t *data, uint32_t len, uint8_t **out_data,
 *               uint32_t *out_len, uint32_t seq) -- no sender-MAC param, but
 * none is needed here since the raw payload is already a full SAFR frame
 * carrying its own SRC_MAC (protocol spec §3). */
static esp_err_t on_uplink_raw_msg(uint8_t *data, uint32_t size, uint8_t **outbuf,
                                   uint32_t *outlen, uint32_t seq)
{
    (void)outbuf; (void)outlen; (void)seq;
    if (node_mesh_is_root()) {
        /* Bench LED: a child's frame reached the root, whether or not the
         * board is there to forward it to. */
        siot_led_comm_blink();
        tcp_write_frame(data, size);
    }
    return ESP_OK;
}

static esp_err_t on_downlink_raw_msg(uint8_t *data, uint32_t size, uint8_t **outbuf,
                                     uint32_t *outlen, uint32_t seq)
{
    (void)outbuf; (void)outlen; (void)seq;
    handle_downlink_frame(data, size);
    return ESP_OK;
}

/* ---- public API ---- */

static char s_softap_ssid[33];

/* Registered as one NULL-terminated list: the library walks the array until
 * an entry with raw_process == NULL. */
static const esp_mesh_lite_raw_msg_action_t s_raw_actions[] = {
    {NODE_MESH_UPLINK_MSG_ID,   0, on_uplink_raw_msg},
    {NODE_MESH_DOWNLINK_MSG_ID, 0, on_downlink_raw_msg},
    {0, 0, NULL},
};

/* Bring-up mirrors managed_components/espressif__mesh_lite/external_examples/
 * no_router/main/no_router.c app_main(): netif + event loop, iot_bridge
 * netifs (SoftAP with DHCP server/NAPT + station), Wi-Fi configs through the
 * bridge, ESP_MESH_LITE_DEFAULT_INIT() overridden with this installation's
 * values, SoftAP info, router config, then start. */
void node_mesh_start(const siot_installation_t *inst)
{
    s_inst = *inst;
    s_dedup_lock = xSemaphoreCreateMutex();
    s_tcp_lock = xSemaphoreCreateMutex();
    memset(s_dedup, 0, sizeof(s_dedup));

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());

    /* Creates the SoftAP (data-forwarding, DHCP server) and station netifs
     * enabled in sdkconfig, and does esp_wifi_init()/esp_wifi_start(). */
    esp_bridge_create_all_netif();

    /* This node's own SoftAP is what its children associate to. It must NOT
     * reuse the board's SSID: Mesh-Lite treats the board's AP (net_ssid) as
     * "the router", and a child that found a sibling's AP under the router's
     * SSID would believe it reached the router and elect itself root. Suffix
     * the STA MAC so every node's AP is distinct; the password is net_psk
     * (POC-BRIEF §4.3) and Mesh-Lite finds parents via its vendor IE / mesh
     * id, not the SSID. */
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(s_softap_ssid, sizeof(s_softap_ssid), "%.22s-%02x%02x%02x",
             s_inst.net_ssid, mac[3], mac[4], mac[5]);

    wifi_config_t sta_cfg = {0}; /* router creds come via set_router_config */
    ESP_ERROR_CHECK(esp_bridge_wifi_set_config(WIFI_IF_STA, &sta_cfg));

    wifi_config_t ap_cfg = {
        .ap = {
            .channel = s_inst.channel,
        },
    };
    strlcpy((char *)ap_cfg.ap.ssid, s_softap_ssid, sizeof(ap_cfg.ap.ssid));
    strlcpy((char *)ap_cfg.ap.password, s_inst.net_psk, sizeof(ap_cfg.ap.password));
    ESP_ERROR_CHECK(esp_bridge_wifi_set_config(WIFI_IF_AP, &ap_cfg));

    esp_mesh_lite_config_t mesh_cfg = ESP_MESH_LITE_DEFAULT_INIT();
    mesh_cfg.mesh_id = s_inst.mesh_id;
    mesh_cfg.max_level = 4; /* POC-BRIEF §4.3: max level 4 */
    /* The mesh must outlive the board (blueprint §6 rule: sirens act on any
     * authenticated ALARM overheard "board reachable or not"). With this
     * false (the default) a root that loses the router drops its role and
     * every child detaches -- the whole network went idle when the board
     * was switched off on the bench. With it true the nodes keep the tree,
     * elect a root among themselves, and Mesh-Lite's self-reference re-homes
     * the best node onto the board when it reappears (User_Guide.md,
     * "Self-Reference"). */
    mesh_cfg.join_mesh_ignore_router_status = true;
    mesh_cfg.softap_ssid = s_softap_ssid;
    mesh_cfg.softap_password = s_inst.net_psk;
    esp_mesh_lite_init(&mesh_cfg);

    ESP_ERROR_CHECK(esp_mesh_lite_set_softap_info(s_softap_ssid, s_inst.net_psk));

    /* "Router" = the board's installation AP (POC-BRIEF §4.2/§4.3). The node
     * that associates to it becomes level 1 (root); the others join under
     * it. No esp_mesh_lite_set_allowed_level() here -- that pins a node to
     * one specific level, which would defeat failover. */
    mesh_lite_sta_config_t router_cfg = {0};
    strlcpy((char *)router_cfg.ssid, s_inst.net_ssid, sizeof(router_cfg.ssid));
    strlcpy((char *)router_cfg.password, s_inst.net_psk, sizeof(router_cfg.password));
    ESP_ERROR_CHECK(esp_mesh_lite_set_router_config(&router_cfg));

    ESP_ERROR_CHECK(esp_mesh_lite_raw_msg_action_list_register(s_raw_actions));

    esp_mesh_lite_start();

    /* Parent-loss detection. The driver's beacon timeout on the bench was
     * 25 s, which was most of the failover time; esp_wifi_set_inactive_time
     * (esp_wifi.h) lowers it (min 3 s for a station). */
    esp_err_t it = esp_wifi_set_inactive_time(WIFI_IF_STA, STA_INACTIVE_TIME_S);
    if (it != ESP_OK) {
        ESP_LOGW(TAG, "set_inactive_time failed: %s", esp_err_to_name(it));
    }

    ESP_LOGI(TAG, "mesh-lite started: mesh_id=%u router=%s softap=%s ch=%u",
             s_inst.mesh_id, s_inst.net_ssid, s_softap_ssid, s_inst.channel);

    xTaskCreate(root_tcp_task, "node_tcp", 4096, NULL, 10, NULL);
}

bool node_mesh_is_root(void)
{
    return esp_mesh_lite_get_level() == 1;
}

uint8_t node_mesh_get_level(void)
{
    return esp_mesh_lite_get_level();
}

bool node_mesh_get_parent_info(uint8_t mac_out[6], int8_t *rssi_out)
{
    wifi_ap_record_t ap_info;
    if (esp_wifi_sta_get_ap_info(&ap_info) != ESP_OK) return false;
    memcpy(mac_out, ap_info.bssid, 6);
    *rssi_out = ap_info.rssi;
    return true;
}

size_t node_mesh_get_children(uint8_t mac_out[][6], int8_t rssi_out[],
                              size_t max_out)
{
    /* esp_mesh_lite_get_nodes_list() would need CONFIG_MESH_LITE_NODE_INFO_REPORT,
     * which (per espressif/mesh_lite's Kconfig) depends on MESH_LITE_ENABLE ->
     * BRIDGE_DATA_FORWARDING_NETIF_SOFTAP -- pulling in espressif/iot_bridge's
     * whole NAT/router-bridging feature set just for a child list, which is
     * unrelated to this POC and links with --whole-archive (risk of
     * unexpected auto-init). Every node is already its own children's SoftAP,
     * so esp_wifi_ap_get_sta_list() (core esp_wifi, no extra component) gives
     * the same information directly -- and unambiguously *direct* children
     * only, resolving the subtree-vs-direct uncertainty the mesh_lite path
     * would have left open. It also carries real per-station RSSI. */
    wifi_sta_list_t sta_list;
    if (esp_wifi_ap_get_sta_list(&sta_list) != ESP_OK) return 0;

    size_t n = 0;
    for (int i = 0; i < sta_list.num && n < max_out; i++) {
        memcpy(mac_out[n], sta_list.sta[i].mac, 6);
        rssi_out[n] = sta_list.sta[i].rssi;
        n++;
    }
    return n;
}

bool node_mesh_send_uplink(const uint8_t *frame, size_t len)
{
    if (esp_mesh_lite_get_level() == 0) {
        /* Not joined yet (no router, no parent): nothing can carry the frame.
         * HEARTBEAT/TOPOLOGY are periodic, the next one goes out once joined. */
        ESP_LOGD(TAG, "uplink dropped, not joined yet");
        return false;
    }
    bool sent;
    if (node_mesh_is_root()) {
        /* Our own frames never traverse the mesh: straight onto the board's
         * TCP socket, same path a child's frame takes in on_uplink_raw_msg. */
        sent = tcp_write_frame(frame, len);
    } else {
        sent = mesh_send_raw(NODE_MESH_UPLINK_MSG_ID, frame, len,
                             esp_mesh_lite_send_raw_msg_to_root);
    }
    if (sent) siot_led_comm_blink(); /* bench LED: a frame left this node */
    return sent;
}

bool node_mesh_board_link_up(void)
{
    return node_mesh_is_root() && s_tcp_sock >= 0;
}

void node_mesh_set_downlink_handler(node_mesh_downlink_cb_t cb)
{
    s_downlink_cb = cb;
}
