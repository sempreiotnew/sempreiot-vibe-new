/* link_mesh_board — the board's side of the mesh (brief §6.1, §8): the
 * installation AP and the TCP server the root dials. From
 * pocs/board/main/board_main.c start_installation_ap() and tcp_link.c. */
#include <string.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/sockets.h"

#include "sdkconfig.h"
#include "siot_link.h"

static const char *TAG = "link_mesh_board";

#define BOARD_MAX_CHILDREN 8      /* AP max_connection (brief §6.1) */
#define TCP_LISTEN_PORT    5340
#define TCP_BACKLOG        2
#define RX_CHUNK_SIZE      256
#define KEEPALIVE_IDLE_S   5      /* a root that lost power is dropped in ~11 s */
#define KEEPALIVE_INTVL_S  2
#define KEEPALIVE_CNT      3

static siot_installation_t s_code;
static volatile int s_client_fd = -1; /* -1 = no root connected */
static TaskHandle_t s_task;

static esp_err_t ap_start(void)
{
    esp_err_t err = esp_netif_init();
    if (err != ESP_OK) return err;
    err = esp_event_loop_create_default();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err;
    if (esp_netif_create_default_wifi_ap() == NULL) return ESP_FAIL;

    wifi_init_config_t init_cfg = WIFI_INIT_CONFIG_DEFAULT();
    err = esp_wifi_init(&init_cfg);
    if (err != ESP_OK) return err;

    wifi_config_t ap_cfg = {
        .ap = {
            .authmode = WIFI_AUTH_WPA2_PSK,
            .max_connection = BOARD_MAX_CHILDREN,
            .channel = s_code.channel,
            .ssid_hidden = 0,
        },
    };
    strlcpy((char *)ap_cfg.ap.ssid, s_code.net_ssid, sizeof(ap_cfg.ap.ssid));
    ap_cfg.ap.ssid_len = (uint8_t)strlen(s_code.net_ssid);
    strlcpy((char *)ap_cfg.ap.password, s_code.net_psk, sizeof(ap_cfg.ap.password));

    err = esp_wifi_set_mode(WIFI_MODE_AP);
    if (err == ESP_OK) err = esp_wifi_set_config(WIFI_IF_AP, &ap_cfg);
    if (err == ESP_OK) err = esp_wifi_start();
    if (err == ESP_OK) {
        ESP_LOGI(TAG, "installation AP up: %s ch=%u (192.168.4.1)", s_code.net_ssid, s_code.channel);
    }
    return err; /* esp_netif's default AP config hands out 192.168.4.1 + DHCP */
}

static void drop_client(int *client)
{
    if (*client < 0) return;
    s_client_fd = -1;
    close(*client);
    *client = -1;
}

/* One root at a time, never stuck on a dead one: select() watches the
 * listening socket and the client together, a new root replaces the old
 * connection the moment it arrives, keepalive reaps a vanished one. */
static void tcp_server_task(void *arg)
{
    (void)arg;
    const int listen_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listen_fd < 0) { ESP_LOGE(TAG, "socket failed"); vTaskDelete(NULL); }

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(TCP_LISTEN_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        listen(listen_fd, TCP_BACKLOG) != 0) {
        ESP_LOGE(TAG, "bind/listen :%d failed", TCP_LISTEN_PORT);
        close(listen_fd);
        vTaskDelete(NULL);
    }

    static siot_link_reasm_t reasm;
    uint8_t chunk[RX_CHUNK_SIZE];
    int client = -1;
    siot_link_reasm_reset(&reasm);

    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(listen_fd, &rfds);
        int maxfd = listen_fd;
        if (client >= 0) {
            FD_SET(client, &rfds);
            if (client > maxfd) maxfd = client;
        }
        struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
        if (select(maxfd + 1, &rfds, NULL, NULL, &tv) < 0) continue;

        if (FD_ISSET(listen_fd, &rfds)) {
            struct sockaddr_in peer;
            socklen_t peer_len = sizeof(peer);
            const int fd = accept(listen_fd, (struct sockaddr *)&peer, &peer_len);
            if (fd >= 0) {
                drop_client(&client); /* newest root wins */
                const int ka = 1, idle = KEEPALIVE_IDLE_S, intvl = KEEPALIVE_INTVL_S, cnt = KEEPALIVE_CNT;
                setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &ka, sizeof(ka));
                setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle));
                setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
                setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
                client = fd;
                siot_link_reasm_reset(&reasm);
                s_client_fd = fd;
                ESP_LOGI(TAG, "root connected");
            }
        }
        if (client >= 0 && FD_ISSET(client, &rfds)) {
            const int n = recv(client, chunk, sizeof(chunk), 0);
            if (n <= 0) {
                ESP_LOGW(TAG, "root connection dropped");
                drop_client(&client);
                siot_link_reasm_reset(&reasm);
                continue;
            }
            siot_link_reasm_feed(&reasm, SIOT_LINK_MESH, chunk, (size_t)n);
        }
    }
}

static esp_err_t board_start(void)
{
    if (s_task != NULL) return ESP_OK;
    const esp_err_t err = ap_start();
    if (err != ESP_OK) return err;
    return xTaskCreatePinnedToCore(tcp_server_task, "mesh_tcp_srv", 4096, NULL, 10, &s_task, 0) == pdPASS
               ? ESP_OK : ESP_ERR_NO_MEM;
}

static esp_err_t board_send(const uint8_t *dst_mac, const uint8_t *frame, size_t len)
{
    (void)dst_mac; /* the root relays to whichever node DST_MAC names */
    const int fd = s_client_fd;
    if (fd < 0) return ESP_ERR_INVALID_STATE; /* no root: dropped, no queue in Phase 1 */
    size_t sent = 0;
    while (sent < len) {
        const int n = send(fd, frame + sent, len - sent, 0);
        if (n <= 0) return ESP_FAIL; /* connection gone; the server loop notices */
        sent += (size_t)n;
    }
    return ESP_OK;
}

static bool board_is_up(void) { return s_client_fd >= 0; }
static int  board_rssi(void)  { return 0; }

static const siot_link_ops_t s_board_ops = {
    .start = board_start,
    .stop = NULL,
    .send = board_send,
    .is_up = board_is_up,
    .rssi = board_rssi,
};

esp_err_t siot_link_mesh_board_init(const siot_installation_t *code)
{
    if (code == NULL) return ESP_ERR_INVALID_ARG;
    s_code = *code;
    return siot_link_register(SIOT_LINK_MESH, &s_board_ops);
}

#if !CONFIG_MESH_LITE_ENABLE
/* Mesh queries are node-only (link_mesh_node.c); on the board image they
 * answer "no mesh here". */
uint8_t siot_link_mesh_level(void) { return 0; }
bool    siot_link_mesh_parent(uint8_t mac[6], int8_t *rssi) { (void)mac; (void)rssi; return false; }
size_t  siot_link_mesh_children(uint8_t (*macs)[6], int8_t *rssi, size_t max) { (void)macs; (void)rssi; (void)max; return 0; }
bool    siot_link_mesh_board_up(void) { return false; }
esp_err_t siot_link_mesh_broadcast_children(const uint8_t *frame, size_t len) { (void)frame; (void)len; return ESP_ERR_NOT_SUPPORTED; }
esp_err_t siot_link_mesh_node_init(const siot_installation_t *code) { (void)code; return ESP_ERR_NOT_SUPPORTED; }
#endif
