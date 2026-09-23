/* link_mesh_node — ESP-Mesh-Lite 1.0.2 as brought up in pocs/node/main/
 * node_mesh.c (brief §6.3), plus the root's TCP session to the board.
 *
 * Uplink:  root  → straight onto the board TCP socket
 *          child → esp_mesh_lite_send_msg(RAW, "SAFR", max_retry 0, to root);
 *                  the root's raw_process callback writes the bytes to TCP.
 * Downlink: root reads TCP → siot_link_deliver; every node that receives a
 *          downlink frame (TCP or the "SAFD" broadcast from its parent)
 *          delivers it upward; the caller (netcore) dedupes and re-broadcasts
 *          to its own children with siot_link_mesh_broadcast_children().
 * max_retry is always 0: retries are SAFR's own (blueprint rule 8).
 */
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include "lwip/sockets.h"

#include "esp_bridge.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_mesh_lite.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "siot_identity.h"
#include "siot_link.h"

static const char *TAG = "link_mesh_node";

#define BOARD_TCP_IP             "192.168.4.1"
#define BOARD_TCP_PORT           5340
#define TCP_RECONNECT_BACKOFF_MS 2000
#define TCP_CONNECT_TIMEOUT_MS   3000 /* a blocking connect() sat ~60 s on unanswered SYNs after failover */
#define TCP_KEEPALIVE_IDLE_S     5    /* dead board noticed in ~11 s */
#define TCP_KEEPALIVE_INTVL_S    2
#define TCP_KEEPALIVE_CNT        3
#define STA_INACTIVE_TIME_S      6    /* parent beacon loss; driver default seen on the bench was 25 s */
#define MESH_MAX_LEVEL           4

/* App-chosen ids for the two raw-message channels: the receiver dispatches
 * on this id to the raw_process callback registered below. 0 is
 * MESH_LITE_MSG_ID_INVALID and 1..3 are taken by the library. */
#define MESH_UPLINK_MSG_ID    0x53414652u /* "SAFR" */
#define MESH_DOWNLINK_MSG_ID  0x53414644u /* "SAFD" */

static siot_installation_t s_code;
static char s_softap_ssid[33];
static int  s_tcp_sock = -1;
static SemaphoreHandle_t s_tcp_lock;   /* serializes writes from several senders */
static TaskHandle_t s_tcp_task;
static bool s_started;

static bool is_root(void) { return esp_mesh_lite_get_level() == 1; }

/* Single-shot raw send. */
static esp_err_t mesh_send_raw(uint32_t msg_id, const uint8_t *data, size_t len,
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
    const esp_err_t err = esp_mesh_lite_send_msg(ESP_MESH_LITE_RAW_MSG, &cfg);
    if (err != ESP_OK) ESP_LOGD(TAG, "raw send 0x%08" PRIx32 ": %s", msg_id, esp_err_to_name(err));
    return err;
}

static esp_err_t tcp_write_frame(const uint8_t *frame, size_t len)
{
    esp_err_t err = ESP_ERR_INVALID_STATE;
    xSemaphoreTake(s_tcp_lock, portMAX_DELAY);
    if (s_tcp_sock >= 0) err = send(s_tcp_sock, frame, len, 0) == (int)len ? ESP_OK : ESP_FAIL;
    xSemaphoreGive(s_tcp_lock);
    return err;
}

/* Bounded connect: non-blocking + select() so a stale route right after the
 * STA came up costs TCP_CONNECT_TIMEOUT_MS, not lwip's whole retransmit budget. */
static int tcp_connect_bounded(const struct sockaddr_in *addr)
{
    int sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock < 0) return -1;
    const int flags = fcntl(sock, F_GETFL, 0);
    fcntl(sock, F_SETFL, flags | O_NONBLOCK);

    int rc = connect(sock, (const struct sockaddr *)addr, sizeof(*addr));
    if (rc != 0 && errno != EINPROGRESS) { close(sock); return -1; }
    if (rc != 0) {
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(sock, &wfds);
        struct timeval tv = { .tv_sec = TCP_CONNECT_TIMEOUT_MS / 1000,
                              .tv_usec = (TCP_CONNECT_TIMEOUT_MS % 1000) * 1000 };
        if (select(sock + 1, NULL, &wfds, NULL, &tv) <= 0) { close(sock); return -1; }
        int err = 0;
        socklen_t len = sizeof(err);
        if (getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len) != 0 || err != 0) { close(sock); return -1; }
    }
    fcntl(sock, F_SETFL, flags);

    const int ka = 1, idle = TCP_KEEPALIVE_IDLE_S, intvl = TCP_KEEPALIVE_INTVL_S, cnt = TCP_KEEPALIVE_CNT;
    setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, &ka, sizeof(ka));
    setsockopt(sock, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle));
    setsockopt(sock, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
    setsockopt(sock, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
    const struct timeval rto = { .tv_sec = 1, .tv_usec = 0 }; /* re-check the root role every second */
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &rto, sizeof(rto));
    return sock;
}

static void root_tcp_task(void *arg)
{
    (void)arg;
    static siot_link_reasm_t reasm;
    uint8_t chunk[256];

    for (;;) {
        if (!is_root()) { vTaskDelay(pdMS_TO_TICKS(500)); continue; } /* parked until elected */

        struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons(BOARD_TCP_PORT) };
        inet_pton(AF_INET, BOARD_TCP_IP, &addr.sin_addr);
        const int sock = tcp_connect_bounded(&addr);
        if (sock < 0) { vTaskDelay(pdMS_TO_TICKS(TCP_RECONNECT_BACKOFF_MS)); continue; } /* root without a board: keep the mesh, keep trying */

        ESP_LOGI(TAG, "connected to the board (%s:%d)", BOARD_TCP_IP, BOARD_TCP_PORT);
        xSemaphoreTake(s_tcp_lock, portMAX_DELAY);
        s_tcp_sock = sock;
        xSemaphoreGive(s_tcp_lock);

        siot_link_reasm_reset(&reasm);
        for (;;) {
            if (!is_root()) break; /* root failover away from us */
            const int n = recv(sock, chunk, sizeof(chunk), 0);
            if (n < 0 && (errno == EWOULDBLOCK || errno == EAGAIN)) continue; /* SO_RCVTIMEO tick */
            if (n <= 0) break; /* board gone (or keepalive gave up) */
            siot_link_reasm_feed(&reasm, SIOT_LINK_MESH, chunk, (size_t)n);
        }

        ESP_LOGW(TAG, "board session dropped, reconnecting");
        xSemaphoreTake(s_tcp_lock, portMAX_DELAY);
        s_tcp_sock = -1;
        xSemaphoreGive(s_tcp_lock);
        close(sock);
        vTaskDelay(pdMS_TO_TICKS(TCP_RECONNECT_BACKOFF_MS));
    }
}

/* ---- Mesh-Lite raw-message callbacks (raw_msg_process_cb_t) ----------- */

/* A descendant's uplink reached us: only the root acts, bridging it to TCP unchanged. */
static esp_err_t on_uplink_raw_msg(uint8_t *data, uint32_t size, uint8_t **outbuf, uint32_t *outlen, uint32_t seq)
{
    (void)outbuf; (void)outlen; (void)seq;
    if (is_root()) tcp_write_frame(data, size);
    return ESP_OK;
}

/* A parent's downlink broadcast: hand it up; netcore dedupes and re-broadcasts. */
static esp_err_t on_downlink_raw_msg(uint8_t *data, uint32_t size, uint8_t **outbuf, uint32_t *outlen, uint32_t seq)
{
    (void)outbuf; (void)outlen; (void)seq;
    if (size >= SAFR_MIN_FRAME && size <= SAFR_MAX_FRAME) siot_link_deliver(SIOT_LINK_MESH, data, size);
    return ESP_OK;
}

/* NULL-terminated: the library walks the array until raw_process == NULL. */
static const esp_mesh_lite_raw_msg_action_t s_raw_actions[] = {
    {MESH_UPLINK_MSG_ID,   0, on_uplink_raw_msg},
    {MESH_DOWNLINK_MSG_ID, 0, on_downlink_raw_msg},
    {0, 0, NULL},
};

/* Bring-up mirrors managed_components/espressif__mesh_lite/external_examples/no_router. */
static esp_err_t node_start(void)
{
    if (s_started) return ESP_OK;

    esp_err_t err = esp_netif_init();
    if (err != ESP_OK) return err;
    err = esp_event_loop_create_default();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err;

    /* SoftAP (DHCP server) + station netifs, esp_wifi_init()/start(). */
    esp_bridge_create_all_netif();

    /* This node's own SoftAP must NOT reuse the board's SSID: Mesh-Lite
     * treats net_ssid as "the router", and a child that found a sibling
     * under that SSID elected itself root on the bench. Suffix the STA MAC. */
    const uint8_t *mac = siot_identity_get()->mac;
    snprintf(s_softap_ssid, sizeof(s_softap_ssid), "%.22s-%02x%02x%02x", s_code.net_ssid, mac[3], mac[4], mac[5]);

    wifi_config_t sta_cfg = {0}; /* router credentials come via set_router_config */
    err = esp_bridge_wifi_set_config(WIFI_IF_STA, &sta_cfg);
    if (err != ESP_OK) return err;

    wifi_config_t ap_cfg = { .ap = { .channel = s_code.channel } };
    strlcpy((char *)ap_cfg.ap.ssid, s_softap_ssid, sizeof(ap_cfg.ap.ssid));
    strlcpy((char *)ap_cfg.ap.password, s_code.net_psk, sizeof(ap_cfg.ap.password));
    err = esp_bridge_wifi_set_config(WIFI_IF_AP, &ap_cfg);
    if (err != ESP_OK) return err;

    esp_mesh_lite_config_t mesh_cfg = ESP_MESH_LITE_DEFAULT_INIT();
    mesh_cfg.mesh_id = s_code.mesh_id;
    mesh_cfg.max_level = MESH_MAX_LEVEL;
    /* The mesh must outlive the board (brief §6.3): with the default (false)
     * a root that loses the router drops its role and every child detaches. */
    mesh_cfg.join_mesh_ignore_router_status = true;
    mesh_cfg.softap_ssid = s_softap_ssid;
    mesh_cfg.softap_password = s_code.net_psk;
    esp_mesh_lite_init(&mesh_cfg);

    err = esp_mesh_lite_set_softap_info(s_softap_ssid, s_code.net_psk);
    if (err != ESP_OK) return err;

    /* "Router" = the board's installation AP. Whoever associates to it is
     * level 1 (root). No esp_mesh_lite_set_allowed_level(): it defeats failover. */
    mesh_lite_sta_config_t router_cfg = {0};
    strlcpy((char *)router_cfg.ssid, s_code.net_ssid, sizeof(router_cfg.ssid));
    strlcpy((char *)router_cfg.password, s_code.net_psk, sizeof(router_cfg.password));
    err = esp_mesh_lite_set_router_config(&router_cfg);
    if (err != ESP_OK) return err;

    err = esp_mesh_lite_raw_msg_action_list_register(s_raw_actions);
    if (err != ESP_OK) return err;

    esp_mesh_lite_start();

    err = esp_wifi_set_inactive_time(WIFI_IF_STA, STA_INACTIVE_TIME_S);
    if (err != ESP_OK) ESP_LOGW(TAG, "set_inactive_time: %s", esp_err_to_name(err));

    ESP_LOGI(TAG, "mesh-lite started: mesh_id=%u router=%s softap=%s ch=%u",
             s_code.mesh_id, s_code.net_ssid, s_softap_ssid, s_code.channel);

    if (xTaskCreatePinnedToCore(root_tcp_task, "mesh_tcp_task", 4096, NULL, 10, &s_tcp_task, 0) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }
    s_started = true;
    return ESP_OK;
}

/* Uplink: every frame this node originates goes "to the board" whatever DST_MAC says. */
static esp_err_t node_send(const uint8_t *dst_mac, const uint8_t *frame, size_t len)
{
    (void)dst_mac;
    if (esp_mesh_lite_get_level() == 0) return ESP_ERR_INVALID_STATE; /* not joined: nothing can carry it */
    if (is_root()) return tcp_write_frame(frame, len);
    return mesh_send_raw(MESH_UPLINK_MSG_ID, frame, len, esp_mesh_lite_send_raw_msg_to_root);
}

static bool node_is_up(void)
{
    const uint8_t level = esp_mesh_lite_get_level();
    if (level == 0) return false;
    return level >= 2 || s_tcp_sock >= 0; /* root: only with the board session */
}

static int node_rssi(void)
{
    wifi_ap_record_t ap;
    return esp_wifi_sta_get_ap_info(&ap) == ESP_OK ? ap.rssi : 0;
}

static const siot_link_ops_t s_node_ops = {
    .start = node_start,
    .stop = NULL,
    .send = node_send,
    .is_up = node_is_up,
    .rssi = node_rssi,
};

esp_err_t siot_link_mesh_node_init(const siot_installation_t *code)
{
    if (code == NULL) return ESP_ERR_INVALID_ARG;
    s_code = *code;
    if (s_tcp_lock == NULL) s_tcp_lock = xSemaphoreCreateMutex();
    return siot_link_register(SIOT_LINK_MESH, &s_node_ops);
}

/* ---- mesh queries ------------------------------------------------------ */

uint8_t siot_link_mesh_level(void)
{
    return esp_mesh_lite_get_level();
}

/* Every non-root node's STA associates to its parent's SoftAP, the root's to
 * the board's AP: esp_wifi_sta_get_ap_info() reports "the parent" in both cases. */
bool siot_link_mesh_parent(uint8_t mac[6], int8_t *rssi)
{
    wifi_ap_record_t ap;
    if (esp_wifi_sta_get_ap_info(&ap) != ESP_OK) return false;
    memcpy(mac, ap.bssid, 6);
    /* ap.bssid is the parent's SoftAP MAC. On ESP32 (IDF v5.5.2,
     * ESP_MAC_WIFI_SOFTAP) that is the parent's STA MAC — its SAFR identity /
     * SRC_MAC — with only the last byte incremented (mac[5] += 1, no carry).
     * Undo it so PARENT_MAC is the identity the tablet keys devices by; the
     * root then wires under the board and a child under its root. */
    mac[5] = (uint8_t)(mac[5] - 1);
    *rssi = ap.rssi;
    return true;
}

/* Direct children = the stations on this node's own SoftAP, with real RSSI
 * (no CONFIG_MESH_LITE_NODE_INFO_REPORT needed). */
size_t siot_link_mesh_children(uint8_t (*macs)[6], int8_t *rssi, size_t max)
{
    wifi_sta_list_t sta_list;
    if (esp_wifi_ap_get_sta_list(&sta_list) != ESP_OK) return 0;
    size_t n = 0;
    for (int i = 0; i < sta_list.num && n < max; i++) {
        memcpy(macs[n], sta_list.sta[i].mac, 6);
        rssi[n] = sta_list.sta[i].rssi;
        n++;
    }
    return n;
}

bool siot_link_mesh_board_up(void)
{
    return is_root() && s_tcp_sock >= 0;
}

esp_err_t siot_link_mesh_broadcast_children(const uint8_t *frame, size_t len)
{
    if (esp_mesh_lite_get_level() == 0) return ESP_ERR_INVALID_STATE;
    return mesh_send_raw(MESH_DOWNLINK_MSG_ID, frame, len, esp_mesh_lite_send_broadcast_raw_msg_to_child);
}
