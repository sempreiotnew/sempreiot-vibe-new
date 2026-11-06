/* link_mesh_board — the board's side of the mesh (brief §6.1, §8): the
 * installation AP and the TCP server the root dials. From
 * pocs/board/main/board_main.c start_installation_ap() and tcp_link.c.
 *
 * ONE root, and the board is who keeps it (blueprint §4, 2026-11-05).
 * Mesh-Lite makes a root of every unit that finds no parent and can attach to
 * this AP, and merges two roots only when they hear each other: two units
 * that both hear the board and not each other stayed two roots for good
 * (a building, 2026-11-05: "2 andar" at -93 dBm beside "1 andar" at -62).
 * This server held one session and let the newest dial win, so the two took
 * turns on it and every frame sent in the other's turn was lost. Now:
 *
 *   - the root's session is never taken by another unit's dial;
 *   - a second unit that dials is held aside (a challenger) until the root is
 *     proven alive — TCP keepalive drops a dead root's session in ~5 s, and
 *     then the challenger IS the new root: failover is not delayed;
 *   - with the root alive, a root that works is left alone: the newcomer
 *     takes the root only when the root's own link is weak (below
 *     SIOT_LINK_ROOT_WEAK_DBM) and the board hears the newcomer
 *     SIOT_LINK_ROOT_TAKEOVER_DB better. The other one is sent ROOT_YIELD
 *     (protocol §7.6) and disconnected: it closes its own access point — so
 *     the units under it go and find the mesh instead of staying with it —
 *     leaves level 1 and joins the mesh as a child (link_mesh_node.c). A
 *     unit that can reach nobody but the board stays out: it is not in this
 *     mesh, and the tablet shows it without communication instead of a
 *     second root that loses frames.
 *
 * Units older than this rule (node firmware up to 0.5.2) do not know
 * ROOT_YIELD: told to yield, they dial again two seconds later. Held out for
 * good they could never be reached again — not even by the update that
 * teaches them. So a unit that dials within YIELD_DEAF_MS of being told to
 * yield is taken for one of those, and for LEGACY_MS after it the server is
 * what it was before: the newest dial is the root. A unit that knows the rule
 * never does that (it is barred from level 1 for 90 s). With every unit
 * updated this path is never taken. */
#include <string.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "esp_wifi_ap_get_sta_list.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/sockets.h"

#include "sdkconfig.h"
#include "siot_evbus.h"
#include "siot_link.h"

static const char *TAG = "link_mesh_board";

#define BOARD_MAX_CHILDREN 8      /* AP max_connection (brief §6.1) */
#define TCP_LISTEN_PORT    5340
#define TCP_BACKLOG        2
#define RX_CHUNK_SIZE      256
/* lwIP aborts the session keep_idle + cnt × intvl after the last segment it
 * received from the root (tcp_slowtmr, independent of unacked data): a root
 * that lost power is dropped in ~5 s and SIOT_EVT_LINK_DOWN fires. */
#define KEEPALIVE_IDLE_S   2
#define KEEPALIVE_INTVL_S  1
#define KEEPALIVE_CNT      3
/* A challenger waits this long for the root to prove it is alive: one second
 * more than keepalive needs to drop a dead root's session. A root heard
 * within ROOT_HEARD_MS needs no waiting. */
#define ROOT_PROOF_MS      ((KEEPALIVE_IDLE_S + KEEPALIVE_CNT * KEEPALIVE_INTVL_S + 1) * 1000)
#define ROOT_HEARD_MS      2000
#define CHALLENGERS_MAX    4      /* units held aside at once; one more is closed and dials again */
#define YIELD_DEAF_MS      30000  /* told to yield and back within this: a unit that does not know ROOT_YIELD */
#define LEGACY_MS          60000  /* then the newest dial wins, as before the rule, for this long */

typedef struct {
    int            fd;       /* -1 = free */
    struct in_addr ip;
    int64_t        since_ms;
} challenger_t;

static siot_installation_t s_code;
static volatile int s_client_fd = -1; /* -1 = no root connected */
static struct in_addr s_client_ip;    /* the root's address: the same unit dialling again replaces its own session */
static int64_t s_client_rx_ms;        /* the root's last bytes */
static challenger_t s_challengers[CHALLENGERS_MAX];
static struct { struct in_addr ip; int64_t at_ms; } s_yielded[CHALLENGERS_MAX]; /* the last units told to yield */
static int     s_yielded_next;
static int64_t s_legacy_until_ms;     /* newest dial wins until then (a unit that does not know ROOT_YIELD) */
static siot_link_root_yield_fn s_root_yield;
static TaskHandle_t s_task;

void siot_link_mesh_board_set_root_yield(siot_link_root_yield_fn fn) { s_root_yield = fn; }

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

static esp_err_t ap_apply(const char *ssid, const char *pass, uint8_t channel, uint8_t max_sta)
{
    wifi_config_t ap_cfg = {
        .ap = {
            .authmode = WIFI_AUTH_WPA2_PSK,
            .max_connection = max_sta,
            .channel = channel,
            .ssid_hidden = 0,
        },
    };
    strlcpy((char *)ap_cfg.ap.ssid, ssid, sizeof(ap_cfg.ap.ssid));
    ap_cfg.ap.ssid_len = (uint8_t)strlen(ssid);
    strlcpy((char *)ap_cfg.ap.password, pass, sizeof(ap_cfg.ap.password));
    esp_err_t err = esp_wifi_set_mode(WIFI_MODE_AP);
    if (err == ESP_OK) err = esp_wifi_set_config(WIFI_IF_AP, &ap_cfg);
    if (err == ESP_OK) err = esp_wifi_start();
    return err;
}

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

    err = ap_apply(s_code.net_ssid, s_code.net_psk, s_code.channel, BOARD_MAX_CHILDREN);
    if (err == ESP_OK) {
        ESP_LOGI(TAG, "installation AP up: %s ch=%u (192.168.4.1)", s_code.net_ssid, s_code.channel);
    }
    return err; /* esp_netif's default AP config hands out 192.168.4.1 + DHCP */
}

/* Admin window (lifecycle §11): the one SoftAP becomes the setup network for
 * a few minutes; the root loses the board meanwhile and rejoins on resume. */
esp_err_t siot_link_mesh_board_suspend(const char *ssid, const char *pass, uint8_t channel)
{
    esp_err_t err = esp_wifi_stop();
    if (err != ESP_OK) return err;
    err = ap_apply(ssid, pass, channel, 4);
    if (err == ESP_OK) ESP_LOGW(TAG, "installation AP suspended: setup network %s up", ssid);
    return err;
}

esp_err_t siot_link_mesh_board_resume(void)
{
    esp_err_t err = esp_wifi_stop();
    if (err != ESP_OK) return err;
    err = ap_apply(s_code.net_ssid, s_code.net_psk, s_code.channel, BOARD_MAX_CHILDREN);
    if (err == ESP_OK) ESP_LOGI(TAG, "installation AP resumed: %s ch=%u", s_code.net_ssid, s_code.channel);
    return err;
}

static void drop_client(int *client)
{
    if (*client < 0) return;
    s_client_fd = -1;
    close(*client);
    *client = -1;
}

/* The station behind an address on our AP: its MAC and the signal the AP
 * measures of it. False when it is not (or no longer) associated. */
static bool station_of(struct in_addr ip, uint8_t mac[6], int8_t *rssi)
{
    static wifi_sta_list_t stations;        /* the server task only */
    static wifi_sta_mac_ip_list_t leases;
    if (esp_wifi_ap_get_sta_list(&stations) != ESP_OK) return false;
    if (esp_wifi_ap_get_sta_list_with_ip(&stations, &leases) != ESP_OK) return false;
    for (int i = 0; i < leases.num && i < stations.num; i++) {
        if (leases.sta[i].ip.addr != ip.s_addr) continue;
        for (int j = 0; j < stations.num; j++) {
            if (memcmp(stations.sta[j].mac, leases.sta[i].mac, 6) != 0) continue;
            memcpy(mac, stations.sta[j].mac, 6);
            *rssi = stations.sta[j].rssi;
            return true;
        }
    }
    return false;
}

/* ROOT_YIELD on this unit's own session, then the session ends: the unit
 * reads the frame before it sees the close. */
static void yield_and_close(int fd, struct in_addr ip, const uint8_t root_mac[6])
{
    static uint8_t frame[SAFR_MAX_FRAME];   /* the server task only */
    const size_t n = s_root_yield ? s_root_yield(root_mac, frame, sizeof(frame)) : 0;
    if (n > 0 && send(fd, frame, n, 0) != (int)n) ESP_LOGW(TAG, "ROOT_YIELD not sent (the unit is gone?)");
    close(fd);
    s_yielded[s_yielded_next].ip = ip;
    s_yielded[s_yielded_next].at_ms = now_ms();
    s_yielded_next = (s_yielded_next + 1) % CHALLENGERS_MAX;
}

/* Told to yield a moment ago, and dialling again: it did not understand. */
static bool deaf_to_yield(struct in_addr ip)
{
    const int64_t now = now_ms();
    for (int i = 0; i < CHALLENGERS_MAX; i++) {
        if (s_yielded[i].at_ms != 0 && s_yielded[i].ip.s_addr == ip.s_addr &&
            now - s_yielded[i].at_ms < YIELD_DEAF_MS) return true;
    }
    return false;
}

static void set_keepalive(int fd)
{
    const int ka = 1, idle = KEEPALIVE_IDLE_S, intvl = KEEPALIVE_INTVL_S, cnt = KEEPALIVE_CNT;
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &ka, sizeof(ka));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
}

/* This session is the root's from now on. */
static void adopt_root(int *client, siot_link_reasm_t *reasm, int fd, struct in_addr ip)
{
    *client = fd;
    s_client_ip = ip;
    s_client_rx_ms = now_ms();
    siot_link_reasm_reset(reasm);
    s_client_fd = fd;
    char who[16];
    inet_ntoa_r(ip, who, sizeof(who));
    ESP_LOGI(TAG, "root connected (%s)", who);
    const siot_evt_link_t ev = {.link_kind = SIOT_LINK_MESH};
    siot_evbus_post(SIOT_EVT_LINK_UP, &ev, sizeof(ev));
}

/* The units held aside: with no root, the first one is the root; with the
 * root proven alive, one of the two yields (see the top of this file). */
static void settle_challengers(int *client, siot_link_reasm_t *reasm)
{
    const int64_t now = now_ms();
    for (int i = 0; i < CHALLENGERS_MAX; i++) {
        challenger_t *c = &s_challengers[i];
        if (c->fd < 0) continue;
        char who[16];
        inet_ntoa_r(c->ip, who, sizeof(who));
        if (*client < 0) {
            /* The root's session ended while this unit waited: failover. */
            ESP_LOGW(TAG, "%s is the root now (the previous root is gone)", who);
            adopt_root(client, reasm, c->fd, c->ip);
            c->fd = -1;
            continue;
        }
        const bool root_alive = now - s_client_rx_ms <= ROOT_HEARD_MS || now - c->since_ms >= ROOT_PROOF_MS;
        if (!root_alive) continue; /* a dead root's session is dropped by keepalive before the proof ends */

        uint8_t root_mac[6] = {0}, new_mac[6] = {0};
        int8_t root_rssi = 0, new_rssi = 0;
        const bool root_known = station_of(s_client_ip, root_mac, &root_rssi);
        const bool new_known = station_of(c->ip, new_mac, &new_rssi);
        if (siot_link_root_challenger_wins(root_known, root_rssi, new_known, new_rssi)) {
            ESP_LOGW(TAG, "one root: the root's link is weak (%d dBm) — %s (%d dBm) takes the root, the old root is told to yield",
                     root_rssi, who, new_rssi);
            const int old = *client;
            const struct in_addr old_ip = s_client_ip;
            s_client_fd = -1; /* nothing more goes down the old session */
            *client = -1;
            yield_and_close(old, old_ip, new_mac);
            adopt_root(client, reasm, c->fd, c->ip);
        } else {
            ESP_LOGW(TAG, "one root: %s (%d dBm%s) is told to yield, the root stays (%d dBm%s)",
                     who, new_rssi, new_known ? "" : ", not measured",
                     root_rssi, root_known ? "" : ", not measured");
            yield_and_close(c->fd, c->ip, root_mac);
        }
        c->fd = -1;
    }
}

/* A unit dialled. */
static void on_dial(int *client, siot_link_reasm_t *reasm, int fd, struct in_addr ip)
{
    set_keepalive(fd);
    if (*client < 0) { /* no root: this unit is it */
        adopt_root(client, reasm, fd, ip);
        return;
    }
    if (ip.s_addr == s_client_ip.s_addr) {
        /* The root itself, back on a new session (it restarted, or its old
         * session broke on its side first): not a second root. */
        ESP_LOGW(TAG, "the root dialled again: its new session replaces the old one");
        drop_client(client);
        adopt_root(client, reasm, fd, ip);
        return;
    }
    char who[16];
    inet_ntoa_r(ip, who, sizeof(who));
    if (deaf_to_yield(ip)) {
        ESP_LOGW(TAG, "one root: %s was told to yield and dialled again — a unit that does not know ROOT_YIELD "
                      "(firmware before the rule): the newest dial wins for %d s, update it", who, LEGACY_MS / 1000);
        s_legacy_until_ms = now_ms() + LEGACY_MS;
    }
    if (now_ms() < s_legacy_until_ms) { /* as before the rule: see the top of this file */
        drop_client(client);
        adopt_root(client, reasm, fd, ip);
        return;
    }
    for (int i = 0; i < CHALLENGERS_MAX; i++) {
        if (s_challengers[i].fd >= 0 && s_challengers[i].ip.s_addr == ip.s_addr) {
            close(s_challengers[i].fd); /* the same unit, dialling again: its newer session waits */
            s_challengers[i].fd = fd;
            return;
        }
    }
    for (int i = 0; i < CHALLENGERS_MAX; i++) {
        if (s_challengers[i].fd >= 0) continue;
        s_challengers[i] = (challenger_t){.fd = fd, .ip = ip, .since_ms = now_ms()};
        ESP_LOGW(TAG, "one root: %s dialled while the root is connected — held until the root proves alive", who);
        return;
    }
    ESP_LOGW(TAG, "one root: %s dialled, too many units waiting — closed, it dials again", who);
    close(fd);
}

/* One root at a time, never stuck on a dead one: select() watches the
 * listening socket, the root and the units held aside; keepalive reaps a
 * vanished root, and a unit held aside takes its place at once. */
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
    for (int i = 0; i < CHALLENGERS_MAX; i++) s_challengers[i].fd = -1;

    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(listen_fd, &rfds);
        int maxfd = listen_fd;
        if (client >= 0) {
            FD_SET(client, &rfds);
            if (client > maxfd) maxfd = client;
        }
        for (int i = 0; i < CHALLENGERS_MAX; i++) {
            const int fd = s_challengers[i].fd;
            if (fd < 0) continue;
            FD_SET(fd, &rfds);
            if (fd > maxfd) maxfd = fd;
        }
        struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
        if (select(maxfd + 1, &rfds, NULL, NULL, &tv) < 0) continue;

        if (FD_ISSET(listen_fd, &rfds)) {
            struct sockaddr_in peer;
            socklen_t peer_len = sizeof(peer);
            const int fd = accept(listen_fd, (struct sockaddr *)&peer, &peer_len);
            if (fd >= 0) on_dial(&client, &reasm, fd, peer.sin_addr);
        }
        /* A unit held aside is not the root: what it sends is not read as
         * frames (it sends them again once it is in the mesh, or the root);
         * one that hangs up is forgotten. */
        for (int i = 0; i < CHALLENGERS_MAX; i++) {
            const int fd = s_challengers[i].fd;
            if (fd < 0 || fd == client || !FD_ISSET(fd, &rfds)) continue;
            if (recv(fd, chunk, sizeof(chunk), 0) <= 0) {
                close(fd);
                s_challengers[i].fd = -1;
            }
        }
        if (client >= 0 && FD_ISSET(client, &rfds)) {
            const int n = recv(client, chunk, sizeof(chunk), 0);
            if (n <= 0) {
                /* The root closed, or keepalive gave up on it: the mesh has no
                 * path to us right now — unless a unit held aside takes over
                 * below. */
                ESP_LOGW(TAG, "root connection dropped");
                drop_client(&client);
                siot_link_reasm_reset(&reasm);
                const siot_evt_link_t ev = {.link_kind = SIOT_LINK_MESH};
                siot_evbus_post(SIOT_EVT_LINK_DOWN, &ev, sizeof(ev));
            } else {
                s_client_rx_ms = now_ms();
                siot_link_reasm_feed(&reasm, SIOT_LINK_MESH, chunk, (size_t)n);
            }
        }
        settle_challengers(&client, &reasm);
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
void    siot_link_mesh_yield_root(void) {}
void    siot_link_mesh_describe(char *out, size_t cap) { if (out && cap) out[0] = 0; }
void    siot_link_mesh_rejoin(void) {}
uint32_t siot_link_mesh_out_s(void) { return 0; }
esp_err_t siot_link_mesh_broadcast_children(const uint8_t *frame, size_t len) { (void)frame; (void)len; return ESP_ERR_NOT_SUPPORTED; }
esp_err_t siot_link_mesh_node_init(const siot_installation_t *code) { (void)code; return ESP_ERR_NOT_SUPPORTED; }
#endif
