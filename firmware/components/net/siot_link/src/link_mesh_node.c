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
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "siot_identity.h"
#include "siot_link.h"
#include "siot_util.h"

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
/* Mesh-Lite's "fusion" is OFF (2026-11-06). It is the library's own way of
 * getting from several roots to one (User Guide, Automatic Root Node
 * Selection): every root broadcasts "join_me_req" on the board's network with
 * its signal to the board, the weaker root answers by telling its whole tree
 * "fusion_network" and they all go and look for the stronger root's tree —
 * and for nothing else, until that tree is found. Since 2026-11-05 the BOARD
 * keeps the one root (ROOT_YIELD, link_mesh_board.c), so the two mechanisms
 * met: a fusion began in the seconds two units were on the board, the board
 * then told the "stronger" one to yield, and the units sent after its tree
 * went on scanning for a tree that never came — on a table, beside a root at
 * -25 dBm, until RESTART (0.5.6: "Scan done" every 12 s and nothing else).
 *
 * Read from libesp_mesh_lite_esp32s3.a 1.0.2 (esp_mesh_lite_comm.c.obj):
 *   - a fusion starts only in join_me_process (a root receiving
 *     "join_me_req") and reaches the children only as "fusion_network"; both
 *     are entries of the library's message table, and a table registered
 *     later is consulted first, first match wins
 *     (esp_mesh_lite_msg_action_process). s_fusion_off_actions takes both
 *     and drops them: this unit never starts or follows a fusion, whatever
 *     firmware the sender runs;
 *   - a root sends "join_me_req" when it gets its address, when the start
 *     timer fires and then every fusion_frequency_sec — none of them while the
 *     start timer is still running. FUSION_OFF_S is the longest the library's
 *     arithmetic takes (seconds x 1000 in 32 bits): 46 days. After that a root
 *     sends one again now and then; every unit with this firmware drops it.
 * The other switch, esp_mesh_lite_set_networking_mode(ROUTER), silences
 * fusion too but makes every unit that hears the board well attach to it:
 * the opposite of one root. Not used. */
#define FUSION_OFF_S        4000000
/* Parent choice (2026-10-31, corrected 2026-11-05 from the library's own
 * code — esp_mesh_lite_vendor_ie_cb in libesp_mesh_lite_esp32s3.a).
 *
 * The floor is NOT a preference. A candidate heard below it is dropped
 * before it is compared with anything; and a unit left with no candidate
 * connects to the router — the board — at ANY signal (the library's router
 * floor is -125 dBm) and makes itself a root. With the floor at -80 (set on
 * 2026-10-31) a unit that heard its neighbours between -80 and -95 took the
 * board at -93 instead: a second root, for good ("2 andar", 2026-11-05).
 * So the floor is where the radio stops, -95: any unit that is heard is a
 * parent, and a weak one is still better than a second root.
 *
 * What keeps a weak shallow parent from being chosen is the range list, not
 * the floor: a deeper candidate wins when it is stronger than the best so far
 * by more than the list's margin for that signal (5 dB below -75, 10, 15,
 * 20 above) — the root at -90 loses to the siren at -63 beside it in either
 * order. The list is the one from the header's own example. */
#define PARENT_RSSI_MIN_DBM    (-95)
/* ONE root, kept by the board (link_mesh_board.c, protocol §7.6 ROOT_YIELD).
 * A unit the board tells to yield does two things, both undone as soon as it
 * has a parent — it can then replace a root that dies, like any other unit —
 * or after ROOT_YIELD_BAR_MS without one (the root may be gone by then; if it
 * is not, the board says so again):
 *
 *   1. it closes its own access point (esp_mesh_lite_set_leaf_node(true): the
 *      library drops its children, stops advertising it and switches the
 *      SoftAP off). Without this the unit kept its children: the library never
 *      resets a unit's level when it leaves the board, so it went on
 *      advertising "level 1", its children stayed under a root with no path,
 *      and it could not join them either (the library will not join a unit of
 *      its own tree) — a whole branch dead until someone pressed RESTART
 *      (building, 2026-11-05, firmware 0.5.3). With the access point closed
 *      the children look for the real mesh, and the unit then joins through
 *      them or through anyone else it hears;
 *   2. it bars itself from level 1 (esp_mesh_lite_set_disallowed_level(1):
 *      the library leaves the router at once, looks for a parent, and does
 *      not go back to the router while barred).
 *
 * Both are RAM only: a restart starts clean. */
#define ROOT_YIELD_BAR_MS      90000
/* A unit is the root only when its station is on the BOARD's access point
 * (table, 2026-11-05). The library gives a unit "its parent's level + 1" and
 * never checks where that leads: when a root went away and came back
 * advertising no level, every unit still attached to it counted 0 + 1 and
 * announced itself ROOT while attached to another unit ("role: ROOT (level
 * 1)" with an address on a unit's network). The library accepts any unit that
 * advertises level 1 as a parent, so others joined those false roots and each
 * other: groups with no path to the board, offline on the tablet, breathing.
 * Two guards, both in mesh_guard_poll():
 *
 *   - level 1 while attached to another unit = NOT a root and not joined
 *     (siot_link_mesh_level() says 0). After FALSE_ROOT_POLLS polls in a row
 *     its access point closes, so nobody joins a unit with no path; it opens
 *     again when the unit is really in the mesh (level >= 2, or level 1 on the
 *     board);
 *   - attached to another unit and nothing from the central has come down for
 *     NO_PATH_REJOIN_MS (the board's HEARTBEAT comes every 15 s): the unit
 *     leaves that parent and looks again, instead of waiting for a RESTART.
 *     The wait doubles each time up to NO_PATH_REJOIN_MAX_MS and starts over
 *     when the central is heard: with the board switched off the mesh stays
 *     formed, a unit only looks around now and then. A few seconds of spread
 *     per unit (its MAC) keep a whole floor from leaving at the same instant. */
#define FALSE_ROOT_POLLS           3       /* x 500 ms */
#define NO_PATH_REJOIN_MS      60000
#define NO_PATH_REJOIN_MAX_MS 600000
/* A root must prove it (table, 2026-11-05, firmware 0.5.4). One unit stayed
 * at "level 1" for 17 minutes with no session to the board; it advertised
 * itself as the root, so every other unit attached to it and none tried the
 * board: a network with no root, for good. The guards above did not apply —
 * it was not attached to another unit. So: a unit at level 1 (and not under
 * another unit) that has had no session with the board for UNPROVEN_ROOT_MS
 * asks whether the board is there. It is, when the unit is associated to the
 * board's access point, or when a connect to it failed in the last
 * BOARD_NEWS_MS for any reason but "no such access point" (on_wifi_event
 * keeps the last word of the Wi-Fi driver on that — no scan of our own, which
 * would collide with the library's). Then this unit is not the board's root:
 * it gives the role up exactly as on ROOT_YIELD (access point closed, level 1
 * barred until it has a parent, ROOT_YIELD_BAR_MS at most), and another unit
 * attaches. The driver says "no such access point": the board is off, and
 * the root keeps the mesh together as before (brief §6.3). No word at all on
 * the board for UNPROVEN_SILENT_MS: the library is not even trying it, and
 * the unit gives the role up too. A normal election or failover has its
 * session within a few seconds. */
#define UNPROVEN_ROOT_MS       20000
#define UNPROVEN_RECHECK_MS     5000
#define UNPROVEN_SILENT_MS     60000
#define BOARD_NEWS_MS          30000
/* The time runs from the moment the unit is ON the board (table, 2026-11-06,
 * firmware 0.5.6): it used to run from the moment the unit was level 1, so a
 * unit that had looked for the mesh for 20 s and then attached to the board
 * gave the root up half a second later, before its dial could finish — and
 * nobody was left to be the root. Each association to the board now gets its
 * own UNPROVEN_ROOT_MS, UNPROVEN_GRANTS times per spell at most (a unit the
 * board keeps dropping must not wait for ever). */
#define UNPROVEN_GRANTS            3
/* Out of the mesh = not attached where its level says: a child (level >= 2)
 * on a unit, or the root (level 1) on the board. Not counted as out: a unit
 * attached to nothing whose Wi-Fi driver said "no such access point" about
 * the board in the last BOARD_OFF_NEWS_MS — the library is trying, the board
 * is off (or this unit hears nobody at all): nothing is stuck, and the root
 * keeps the mesh for the day the board comes back (brief §6.3).
 *
 * Out for OUT_LOG_MS: the library's own log and the Wi-Fi driver's go on
 * (both are off in normal running — app_main), and one line of ours says
 * every OUT_SAY_MS what this unit holds; all off again when it is back in.
 * A unit that stays out shows why on its console, without anyone having to
 * catch the moment. siot_netcore restarts the unit after 5 minutes of this
 * (siot_link_mesh_out_s). */
#define BOARD_OFF_NEWS_MS      60000
#define OUT_LOG_MS             60000
#define OUT_SAY_MS             30000

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
static volatile bool s_yield_requested; /* ROOT_YIELD arrived: the tcp task acts on it */
static bool    s_root_barred;           /* level 1 disallowed until a parent, or s_root_bar_until_ms */
static int64_t s_root_bar_until_ms;
static bool    s_ap_closed;             /* this unit's access point is closed (leaf mode) */
static uint8_t s_false_root_polls;      /* polls in a row at "level 1, attached to another unit" */
static volatile uint32_t s_last_downlink_s; /* when the last frame of the central came down the mesh to us (s since boot; 0 = never) */
static int64_t s_on_unit_since_ms;      /* attached to another unit since (0 = not attached to one) */
static int64_t s_last_rejoin_ms;
static uint32_t s_rejoin_wait_ms = NO_PATH_REJOIN_MS;
static int64_t s_unproven_since_ms;     /* at level 1 with no session to the board since (0 = not so) */
static int64_t s_unproven_next_ms;      /* when to look for the board's access point again */
static int64_t s_unproven_said_ms;      /* last "the board is off" line */
static bool    s_unproven_on_board;     /* the station was on the board at the last poll of this spell */
static uint8_t s_unproven_grants;       /* fresh waits given in this spell, one per association to the board */
static volatile uint32_t s_out_since_s; /* out of the mesh since (s since boot + 1; 0 = in it). Read by siot_netcore */
static bool    s_out_log_on;            /* the library's and the Wi-Fi driver's logs are on (out for OUT_LOG_MS) */
static int64_t s_out_said_ms;
static volatile uint32_t s_fusion_dropped; /* Mesh-Lite fusion messages dropped (written in the library's rx task) */
static uint32_t s_fusion_said;
static int     s_dial_errno;            /* why the last dial to the board failed (0 = none failed yet) */
/* The Wi-Fi driver's last word on the board's access point (seconds since
 * boot + 1; 0 = never): when it was last on the air for certain, when a
 * connect to it last found no such access point, and why a connect to it
 * last failed. Written from the event task. */
static volatile uint32_t s_board_on_air_s;
static volatile uint32_t s_board_absent_s;
static volatile uint8_t  s_board_fail_reason;
static volatile bool s_rejoin_requested; /* siot_link_mesh_rejoin(): the tcp task leaves the parent */

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

/* Where this unit's station is: on the board's access point (the router SSID
 * itself), on another unit's (the router SSID plus that unit's suffix), or
 * nowhere. */
typedef enum { STA_NOWHERE, STA_ON_BOARD, STA_ON_UNIT } sta_where_t;

static sta_where_t sta_where(char ssid_out[33])
{
    wifi_ap_record_t ap;
    if (esp_wifi_sta_get_ap_info(&ap) != ESP_OK) return STA_NOWHERE;
    if (ssid_out) strlcpy(ssid_out, (const char *)ap.ssid, 33);
    return strncmp((const char *)ap.ssid, s_code.net_ssid, sizeof(ap.ssid)) == 0 ? STA_ON_BOARD : STA_ON_UNIT;
}

/* The level as it really is: the library's, except that a unit is the root
 * only with its station ON THE BOARD's access point. "Level 1" attached to
 * another unit (see FALSE_ROOT_POLLS) or to nothing — the library sets level
 * 1 the moment it decides to TRY the board, and keeps it when the board is
 * lost — is not a root and not in the mesh: 0. (2026-11-06: units announced
 * "role: ROOT" while still looking for the board.) */
static uint8_t mesh_level(void)
{
    const uint8_t level = esp_mesh_lite_get_level();
    return level == 1 && sta_where(NULL) != STA_ON_BOARD ? 0 : level;
}

static bool is_root(void) { return mesh_level() == 1; }

void siot_link_mesh_yield_root(void)
{
    if (is_root()) s_yield_requested = true;
}

/* The access point of a unit with no path is closed: its children are dropped
 * and it stops advertising itself, so units look for the real mesh instead
 * (esp_mesh_lite_set_leaf_node: SoftAP off, vendor IE removed). */
static void ap_close(void)
{
    if (s_ap_closed) return;
    s_ap_closed = true;
    const esp_err_t err = esp_mesh_lite_set_leaf_node(true);
    if (err != ESP_OK) ESP_LOGW(TAG, "access point not closed: %s", esp_err_to_name(err));
}

static void ap_open(void)
{
    if (!s_ap_closed) return;
    s_ap_closed = false;
    const esp_err_t err = esp_mesh_lite_set_leaf_node(false);
    if (err != ESP_OK) ESP_LOGW(TAG, "access point not opened: %s", esp_err_to_name(err));
}

/* The board has another root: off level 1, into the mesh as a child. The
 * access point closes first, while the station is still on the board, so the
 * mode change does not land in the middle of the scan that follows. */
static void root_bar_start(void)
{
    s_root_barred = true;
    s_root_bar_until_ms = now_ms() + ROOT_YIELD_BAR_MS;
    ap_close();
    const esp_err_t bar = esp_mesh_lite_set_disallowed_level(1);
    ESP_LOGW(TAG, "one root: this unit yields — its access point is closed (its units go and find the mesh) "
                  "and level 1 is barred (%s) until it has a parent, %d s at most",
             esp_err_to_name(bar), ROOT_YIELD_BAR_MS / 1000);
}

/* What the Wi-Fi driver says about the board's access point (the router SSID
 * itself; a unit's SSID carries a suffix). */
static bool is_board_ssid(const uint8_t *ssid, uint8_t len)
{
    return len == strlen(s_code.net_ssid) && memcmp(ssid, s_code.net_ssid, len) == 0;
}

static void on_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg; (void)base;
    const uint32_t now_s = (uint32_t)(now_ms() / 1000) + 1;
    if (id == WIFI_EVENT_STA_CONNECTED) {
        const wifi_event_sta_connected_t *e = (const wifi_event_sta_connected_t *)data;
        if (is_board_ssid(e->ssid, e->ssid_len)) s_board_on_air_s = now_s;
    } else if (id == WIFI_EVENT_STA_DISCONNECTED) {
        const wifi_event_sta_disconnected_t *e = (const wifi_event_sta_disconnected_t *)data;
        if (!is_board_ssid(e->ssid, e->ssid_len)) return;
        if (e->reason == WIFI_REASON_NO_AP_FOUND) {
            s_board_absent_s = now_s;
        } else if (e->reason != WIFI_REASON_BEACON_TIMEOUT && e->reason != WIFI_REASON_ASSOC_LEAVE) {
            /* It answered, and the connect failed all the same (beacon timeout
             * and our own leaving say nothing about it being there now). */
            s_board_on_air_s = now_s;
            s_board_fail_reason = e->reason;
        }
    }
}

/* The addresses this unit holds, for the line that says why it gave the root
 * up: its station's and its own access point's. */
static void own_addresses(esp_ip4_addr_t *sta, esp_ip4_addr_t *ap)
{
    esp_netif_ip_info_t info;
    sta->addr = 0;
    ap->addr = 0;
    esp_netif_t *n = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    if (n && esp_netif_get_ip_info(n, &info) == ESP_OK) *sta = info.ip;
    n = esp_netif_get_handle_from_ifkey("WIFI_AP_DEF");
    if (n && esp_netif_get_ip_info(n, &info) == ESP_OK) *ap = info.ip;
}

void siot_link_mesh_describe(char *out, size_t cap)
{
    if (out == NULL || cap == 0) return;
    wifi_ap_record_t ap;
    const bool on = esp_wifi_sta_get_ap_info(&ap) == ESP_OK;
    esp_netif_ip_info_t sta = {0};
    esp_ip4_addr_t sta_ip, ap_ip;
    own_addresses(&sta_ip, &ap_ip);
    esp_netif_t *n = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    if (n) esp_netif_get_ip_info(n, &sta);
    snprintf(out, cap, "library level %u, parent %s (%d dBm), station " IPSTR " gw " IPSTR ", own access point " IPSTR "%s",
             esp_mesh_lite_get_level(), on ? (const char *)ap.ssid : "none", on ? ap.rssi : 0,
             IP2STR(&sta_ip), IP2STR(&sta.gw), IP2STR(&ap_ip), s_ap_closed ? " (closed)" : "");
}

void siot_link_mesh_rejoin(void) { s_rejoin_requested = true; }

/* Mesh-Lite fusion messages: taken before the library's own handlers and
 * dropped (see FUSION_OFF_S). Runs in the library's receive task. */
static cJSON *on_fusion_msg(cJSON *payload, uint32_t seq)
{
    (void)payload; (void)seq;
    s_fusion_dropped++;
    return NULL; /* no answer */
}

/* NULL-terminated: the library walks the array until type == NULL. */
static const esp_mesh_lite_msg_action_t s_fusion_off_actions[] = {
    {"join_me_req",    NULL, on_fusion_msg},
    {"fusion_network", NULL, on_fusion_msg},
    {NULL, NULL, NULL},
};

/* The library's own log and the Wi-Fi driver's: on while a unit stays out of
 * the mesh, off in normal running (the levels app_main sets). */
static void out_log(bool on)
{
    s_out_log_on = on;
    esp_mesh_lite_core_log_enable(on);
    esp_log_level_set("wifi", on ? ESP_LOG_INFO : ESP_LOG_ERROR);
}

/* What this unit holds, for the console of a unit that stays out. */
static void out_say(int64_t now, uint32_t out_s)
{
    static char where[176]; /* tcp task only */
    siot_link_mesh_describe(where, sizeof(where));
    const uint32_t now_s = (uint32_t)(now / 1000) + 1;
    const uint32_t on_air = s_board_on_air_s, absent = s_board_absent_s;
    char board[72];
    if (on_air == 0 && absent == 0) snprintf(board, sizeof(board), "no word from the Wi-Fi driver yet");
    else if (on_air >= absent) snprintf(board, sizeof(board), "on the air %" PRIu32 " s ago (last refusal: reason %u)",
                                        now_s - on_air, s_board_fail_reason);
    else snprintf(board, sizeof(board), "not found %" PRIu32 " s ago", now_s - absent);
    s_out_said_ms = now;
    ESP_LOGW(TAG, "out of the mesh for %" PRIu32 " s: %s; level 1 %s (library: barred level %u, allowed level %u, "
                  "leaf %d); the board's access point: %s; fusion messages dropped: %" PRIu32,
             out_s, where, s_root_barred ? "barred by this unit" : "not barred", esp_mesh_lite_get_disallowed_level(),
             esp_mesh_lite_get_allowed_level(), esp_mesh_lite_is_leaf_node(), board, s_fusion_dropped);
}

static void out_of_mesh_poll(int64_t now, uint8_t level, sta_where_t where)
{
    const uint32_t dropped = s_fusion_dropped;
    if (dropped != s_fusion_said) {
        ESP_LOGW(TAG, "Mesh-Lite fusion is off: %" PRIu32 " fusion message(s) of another unit dropped (%" PRIu32
                      " since boot) — the board keeps the one root", dropped - s_fusion_said, dropped);
        s_fusion_said = dropped;
    }

    const uint32_t now_s = (uint32_t)(now / 1000) + 1;
    const uint32_t on_air = s_board_on_air_s, absent = s_board_absent_s;
    const bool board_off = where == STA_NOWHERE && absent != 0 && absent > on_air &&
                           now_s - absent <= BOARD_OFF_NEWS_MS / 1000;
    const bool attached = (level >= 2 && where == STA_ON_UNIT) || (level == 1 && where == STA_ON_BOARD);
    if (attached || board_off) {
        const uint32_t since = s_out_since_s;
        if (s_out_log_on) {
            out_log(false);
            ESP_LOGW(TAG, "%s after %" PRIu32 " s out of the mesh: the library's log is off again",
                     attached ? "back in the mesh" : "the board is off (its access point is not on the air)",
                     since ? now_s - since : 0);
        }
        s_out_since_s = 0;
        return;
    }
    if (s_out_since_s == 0) s_out_since_s = now_s;
    const uint32_t out_s = now_s - s_out_since_s;
    if (!s_out_log_on && out_s >= OUT_LOG_MS / 1000) {
        out_log(true);
        ESP_LOGW(TAG, "out of the mesh for %" PRIu32 " s: the library's own log and the Wi-Fi driver's are on until "
                      "this unit is back in", out_s);
        out_say(now, out_s);
    } else if (s_out_log_on && now - s_out_said_ms >= OUT_SAY_MS) {
        out_say(now, out_s);
    }
}

uint32_t siot_link_mesh_out_s(void)
{
    const uint32_t since = s_out_since_s;
    if (since == 0) return 0;
    const uint32_t now_s = (uint32_t)(now_ms() / 1000) + 1;
    return now_s > since ? now_s - since : 1;
}

/* Every 500 ms (parked) or second (root with a session), from the tcp task:
 * the guards that keep a unit from being a root it is not, and from staying
 * under a parent that leads nowhere. */
static void mesh_guard_poll(void)
{
    const int64_t now = now_ms();
    const uint8_t level = esp_mesh_lite_get_level(); /* the library's own, unfiltered */
    char parent[33] = "";
    const sta_where_t where = sta_where(parent);

    /* 1. A false root: the library says level 1, the station is on a unit. */
    if (level == 1 && where == STA_ON_UNIT) {
        if (s_false_root_polls < 0xFF) s_false_root_polls++;
        if (s_false_root_polls == FALSE_ROOT_POLLS) {
            ESP_LOGW(TAG, "not a root: the library says level 1 but this unit is attached to %s, not to the board "
                          "(that unit has no level yet) — not joined, access point closed until it is in the mesh",
                     parent);
            ap_close();
        }
    } else {
        s_false_root_polls = 0;
    }

    /* 2. Told to yield: the bar goes when the unit has a parent, or times out. */
    if (s_root_barred && (level >= 2 || now >= s_root_bar_until_ms)) {
        s_root_barred = false;
        const esp_err_t bar = esp_mesh_lite_set_disallowed_level(0); /* 0 = no level barred */
        if (level >= 2) {
            ESP_LOGI(TAG, "one root: joined the mesh at level %u — level 1 allowed again (%s)", level, esp_err_to_name(bar));
        } else {
            ESP_LOGW(TAG, "one root: no unit of the mesh heard in %d s — level 1 allowed again (%s): the board decides",
                     ROOT_YIELD_BAR_MS / 1000, esp_err_to_name(bar));
        }
    }

    /* 3. Really in the mesh: a child of a unit that has a level, or the root
     *    on the board. The access point opens again. */
    const bool in_mesh = level >= 2 || (level == 1 && where == STA_ON_BOARD);
    if (s_ap_closed && !s_root_barred && in_mesh) {
        ESP_LOGI(TAG, "in the mesh (level %u, on %s): access point open again", level, parent);
        ap_open();
    }

    /* 5. A root must prove it: level 1, not under another unit, and no session
     *    with the board. (While barred the unit is already on its way out.) */
    const bool on_board = where == STA_ON_BOARD;
    if (level != 1 || where == STA_ON_UNIT || s_tcp_sock >= 0 || s_root_barred) {
        s_unproven_since_ms = 0;
        s_unproven_grants = 0;
        s_unproven_on_board = false;
    } else if (s_unproven_since_ms == 0) {
        s_unproven_since_ms = now;
        s_unproven_next_ms = now + UNPROVEN_ROOT_MS;
        s_unproven_on_board = on_board;
    } else if (on_board && !s_unproven_on_board && s_unproven_grants < UNPROVEN_GRANTS) {
        /* Just attached to the board: the dial gets its time from here. */
        s_unproven_grants++;
        s_unproven_on_board = true;
        if (s_unproven_next_ms < now + UNPROVEN_ROOT_MS) s_unproven_next_ms = now + UNPROVEN_ROOT_MS;
    } else if (now < s_unproven_next_ms) {
        s_unproven_on_board = on_board;
    } else {
        s_unproven_on_board = on_board;
        s_unproven_next_ms = now + UNPROVEN_RECHECK_MS;
        const uint32_t now_s = (uint32_t)(now / 1000) + 1;
        const uint32_t on_air = s_board_on_air_s, absent = s_board_absent_s;
        const bool on_air_now = on_air != 0 && now_s - on_air <= BOARD_NEWS_MS / 1000 && on_air >= absent;
        const bool absent_now = absent != 0 && now_s - absent <= BOARD_NEWS_MS / 1000 && absent > on_air;
        const uint32_t for_s = (uint32_t)((now - s_unproven_since_ms) / 1000);
        const bool silent = !on_air_now && !absent_now && for_s >= UNPROVEN_SILENT_MS / 1000;
        esp_ip4_addr_t sta_ip, ap_ip;
        own_addresses(&sta_ip, &ap_ip);
        if (where == STA_ON_BOARD || on_air_now || silent) {
            ESP_LOGW(TAG, "root not proven: level 1 for %" PRIu32 " s with no session to the board — station %s "
                          "(address " IPSTR ", own access point " IPSTR "), last dial to %s:%d: %s, last Wi-Fi "
                          "refusal by the board: reason %u. %s: this unit gives the root up and another one attaches",
                     for_s,
                     where == STA_ON_BOARD ? "ON the board's access point" : "not associated",
                     IP2STR(&sta_ip), IP2STR(&ap_ip), BOARD_TCP_IP, BOARD_TCP_PORT,
                     s_dial_errno ? strerror(s_dial_errno) : "none tried", s_board_fail_reason,
                     where == STA_ON_BOARD ? "The board is there (associated to it)"
                     : on_air_now ? "The board is there (it answered a connect)"
                                  : "The library is not trying the board at all");
            s_unproven_since_ms = 0;
            s_unproven_grants = 0;
            s_unproven_on_board = false;
            root_bar_start();
        } else if (absent_now && now - s_unproven_said_ms >= 60000) {
            s_unproven_said_ms = now;
            ESP_LOGW(TAG, "root without the board for %" PRIu32 " s (address " IPSTR ", own access point " IPSTR
                          "): the board's access point is not on the air — the board is off, this unit keeps the mesh",
                     for_s, IP2STR(&sta_ip), IP2STR(&ap_ip));
        }
    }

    /* 7. Out of the mesh (see OUT_LOG_MS). */
    out_of_mesh_poll(now, level, where);

    /* 6. Asked to leave the parent (siot_netcore: the central hears others
     *    and not this unit). */
    if (s_rejoin_requested) {
        s_rejoin_requested = false;
        if (where == STA_ON_UNIT) {
            ESP_LOGW(TAG, "rejoin: leaving %s to look for a parent again", parent);
            s_last_rejoin_ms = now;
            esp_mesh_lite_disconnect();
            esp_mesh_lite_connect();
            return;
        }
    }

    /* 4. Attached to a unit, and the central is not heard through it. */
    if (where != STA_ON_UNIT) {
        s_on_unit_since_ms = 0;
        return;
    }
    if (s_on_unit_since_ms == 0) s_on_unit_since_ms = now;
    int64_t since = s_on_unit_since_ms;
    const int64_t heard = (int64_t)s_last_downlink_s * 1000;
    if (heard > since) since = heard;
    if (s_last_rejoin_ms > since) since = s_last_rejoin_ms;
    const uint32_t spread_ms = (uint32_t)(siot_identity_get()->mac[5] % 16) * 1000;
    if (now - since < (int64_t)s_rejoin_wait_ms + spread_ms) return;
    const uint32_t waited_s = (uint32_t)((now - since) / 1000);
    s_last_rejoin_ms = now;
    s_rejoin_wait_ms = s_rejoin_wait_ms >= NO_PATH_REJOIN_MAX_MS / 2 ? NO_PATH_REJOIN_MAX_MS : s_rejoin_wait_ms * 2;
    ESP_LOGW(TAG, "no path: attached to %s for %" PRIu32 " s with nothing from the central — leaving it to look "
                  "for another parent (next look in %" PRIu32 " s if this one has no path either)",
             parent, waited_s, s_rejoin_wait_ms / 1000);
    esp_mesh_lite_disconnect();
    esp_mesh_lite_connect();
}

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
    if (sock < 0) { s_dial_errno = errno ? errno : ENOMEM; return -1; }
    const int flags = fcntl(sock, F_GETFL, 0);
    fcntl(sock, F_SETFL, flags | O_NONBLOCK);

    /* s_dial_errno: why the dial failed, for the "root not proven" line. */
    int rc = connect(sock, (const struct sockaddr *)addr, sizeof(*addr));
    if (rc != 0 && errno != EINPROGRESS) { s_dial_errno = errno; close(sock); return -1; }
    if (rc != 0) {
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(sock, &wfds);
        struct timeval tv = { .tv_sec = TCP_CONNECT_TIMEOUT_MS / 1000,
                              .tv_usec = (TCP_CONNECT_TIMEOUT_MS % 1000) * 1000 };
        if (select(sock + 1, NULL, &wfds, NULL, &tv) <= 0) { s_dial_errno = ETIMEDOUT; close(sock); return -1; }
        int err = 0;
        socklen_t len = sizeof(err);
        if (getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len) != 0 || err != 0) {
            s_dial_errno = err ? err : EIO;
            close(sock);
            return -1;
        }
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
        mesh_guard_poll();
        /* Parked until elected — and while barred: the library may still say
         * level 1 for a moment after the yield. */
        if (!is_root() || s_root_barred) { vTaskDelay(pdMS_TO_TICKS(500)); continue; }

        struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons(BOARD_TCP_PORT) };
        inet_pton(AF_INET, BOARD_TCP_IP, &addr.sin_addr);
        const int sock = tcp_connect_bounded(&addr);
        if (sock < 0) { vTaskDelay(pdMS_TO_TICKS(TCP_RECONNECT_BACKOFF_MS)); continue; } /* root without a board: keep the mesh, keep trying */

        ESP_LOGI(TAG, "connected to the board (%s:%d)", BOARD_TCP_IP, BOARD_TCP_PORT);
        xSemaphoreTake(s_tcp_lock, portMAX_DELAY);
        s_tcp_sock = sock;
        xSemaphoreGive(s_tcp_lock);

        siot_link_reasm_reset(&reasm);
        s_yield_requested = false; /* a new session: only what the board says on it counts */
        for (;;) {
            mesh_guard_poll();
            if (!is_root()) break; /* root failover away from us */
            const int n = recv(sock, chunk, sizeof(chunk), 0);
            if (n < 0 && (errno == EWOULDBLOCK || errno == EAGAIN)) continue; /* SO_RCVTIMEO tick */
            if (n <= 0) break; /* board gone (or keepalive gave up) */
            siot_link_reasm_feed(&reasm, SIOT_LINK_MESH, chunk, (size_t)n);
            if (s_yield_requested) break; /* ROOT_YIELD was in it (siot_netcore) */
        }

        const bool yield = s_yield_requested;
        s_yield_requested = false;
        ESP_LOGW(TAG, "board session %s", yield ? "ended by the board: another unit is the root" : "dropped, reconnecting");
        xSemaphoreTake(s_tcp_lock, portMAX_DELAY);
        s_tcp_sock = -1;
        xSemaphoreGive(s_tcp_lock);
        close(sock);
        if (yield) { root_bar_start(); continue; }
        vTaskDelay(pdMS_TO_TICKS(TCP_RECONNECT_BACKOFF_MS));
    }
}

/* ---- Mesh-Lite raw-message callbacks (raw_msg_process_cb_t) ----------- */

/* A descendant's uplink reached us: only the root acts, bridging it to TCP
 * unchanged. What is lost here is said, at most once every 10 s: a unit that
 * hears the central and is never heard by it (table, 2026-11-05) showed
 * nothing on any console. */
static esp_err_t on_uplink_raw_msg(uint8_t *data, uint32_t size, uint8_t **outbuf, uint32_t *outlen, uint32_t seq)
{
    (void)outbuf; (void)outlen; (void)seq;
    static int64_t s_said_ms = -10000;
    static uint32_t s_lost;
    const bool root = is_root();
    if (root && tcp_write_frame(data, size) == ESP_OK) return ESP_OK;
    s_lost++;
    const int64_t now = now_ms();
    if (now - s_said_ms >= 10000) {
        char src[SIOT_MAC_STR_LEN] = "?";
        if (size >= SAFR_MIN_FRAME) siot_mac_to_str(&data[9], src);
        if (root) {
            ESP_LOGW(TAG, "uplink lost: %" PRIu32 " frame(s) of other units (last: type 0x%02X from %s) reached this "
                          "root and it has no session with the board", s_lost, size >= 5 ? data[4] : 0, src);
        } else {
            ESP_LOGW(TAG, "uplink lost: %" PRIu32 " frame(s) (last: type 0x%02X from %s) were sent to this unit as if "
                          "it were the root — it is not (library level %u, station %s): dropped", s_lost,
                     size >= 5 ? data[4] : 0, src, esp_mesh_lite_get_level(),
                     sta_where(NULL) == STA_ON_UNIT ? "on another unit" : "attached to nothing");
        }
        s_said_ms = now;
        s_lost = 0;
    }
    return ESP_OK;
}

/* A parent's downlink broadcast: hand it up; netcore dedupes and re-broadcasts. */
static esp_err_t on_downlink_raw_msg(uint8_t *data, uint32_t size, uint8_t **outbuf, uint32_t *outlen, uint32_t seq)
{
    (void)outbuf; (void)outlen; (void)seq;
    if (size >= SAFR_MIN_FRAME && size <= SAFR_MAX_FRAME) {
        s_last_downlink_s = (uint32_t)(now_ms() / 1000) + 1; /* this parent leads to the central */
        s_rejoin_wait_ms = NO_PATH_REJOIN_MS;
        siot_link_deliver(SIOT_LINK_MESH, data, size);
    }
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
    /* The driver's word on the board's access point (mesh_guard_poll, "a root
     * must prove it"). */
    err = esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_wifi_event, NULL, NULL);
    if (err != ESP_OK) return err;

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

    /* Fusion off, receiving side (see FUSION_OFF_S): registered after the
     * library's own table (esp_mesh_lite_init), so consulted before it. */
    err = esp_mesh_lite_msg_action_list_register(s_fusion_off_actions);
    if (err != ESP_OK) ESP_LOGE(TAG, "Mesh-Lite fusion NOT switched off: %s", esp_err_to_name(err));

    /* Mesh-Lite keeps the mesh id in its own NVS namespace ("mesh_lite") and
     * boots with THAT, not with mesh_cfg.mesh_id. A unit moved to another
     * installation kept its first id through our factory reset (siot_inst
     * only) and through every reflash: bench 2026-10-30, "Mesh ID: 7" and
     * "Mesh ID: 137" next to "mesh_id=69" on the two nodes — two one-node
     * meshes, "[vid mesh id dont match]", two roots fighting for the board.
     * The installation code wins, every boot. */
    const uint8_t stored_mesh_id = esp_mesh_lite_get_mesh_id();
    if (stored_mesh_id != s_code.mesh_id) {
        ESP_LOGW(TAG, "Mesh-Lite remembered mesh id %u, the code says %u: the code wins",
                 stored_mesh_id, s_code.mesh_id);
    }
    esp_mesh_lite_set_mesh_id(s_code.mesh_id, true);

    err = esp_mesh_lite_set_softap_info(s_softap_ssid, s_code.net_psk);
    if (err != ESP_OK) return err;

    /* "Router" = the board's installation AP. Whoever associates to it is
     * level 1 (root). No esp_mesh_lite_set_allowed_level(): it defeats failover. */
    mesh_lite_sta_config_t router_cfg = {0};
    strlcpy((char *)router_cfg.ssid, s_code.net_ssid, sizeof(router_cfg.ssid));
    strlcpy((char *)router_cfg.password, s_code.net_psk, sizeof(router_cfg.password));
    err = esp_mesh_lite_set_router_config(&router_cfg);
    if (err != ESP_OK) return err;

    /* Fusion off, sending side: no "join_me_req" from this unit while the
     * start timer runs (fusion_rssi_threshold 0 = left as the library has it). */
    esp_mesh_lite_fusion_config_t fusion = {
        .fusion_start_time_sec = FUSION_OFF_S,
        .fusion_frequency_sec = FUSION_OFF_S,
    };
    err = esp_mesh_lite_set_fusion_config(&fusion);
    if (err != ESP_OK) ESP_LOGW(TAG, "fusion config: %s", esp_err_to_name(err));
    else ESP_LOGI(TAG, "Mesh-Lite fusion off: the board keeps the one root");

    static esp_mesh_lite_rssi_threshold_list_t rssi_level[] = {
        {0, -35, 20},
        {-35, -55, 15},
        {-55, -75, 10},
        {-75, -125, 5},
    };
    err = esp_mesh_lite_set_rssi_threshold(rssi_level, sizeof(rssi_level) / sizeof(rssi_level[0]),
                                           PARENT_RSSI_MIN_DBM);
    if (err != ESP_OK) ESP_LOGW(TAG, "parent rssi floor %d dBm not set: %s", PARENT_RSSI_MIN_DBM, esp_err_to_name(err));
    else ESP_LOGI(TAG, "parent rssi floor %d dBm", PARENT_RSSI_MIN_DBM);

    err = esp_mesh_lite_raw_msg_action_list_register(s_raw_actions);
    if (err != ESP_OK) return err;

    esp_mesh_lite_start();

    err = esp_wifi_set_inactive_time(WIFI_IF_STA, STA_INACTIVE_TIME_S);
    if (err != ESP_OK) ESP_LOGW(TAG, "set_inactive_time: %s", esp_err_to_name(err));

    ESP_LOGI(TAG, "mesh-lite started: mesh_id=%u router=%s softap=%s ch=%u",
             s_code.mesh_id, s_code.net_ssid, s_softap_ssid, s_code.channel);

    /* 6144: the task also runs mesh_guard_poll() — the library's disconnect /
     * connect and a few long log lines — beside the frame path. */
    if (xTaskCreatePinnedToCore(root_tcp_task, "mesh_tcp_task", 6144, NULL, 10, &s_tcp_task, 0) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }
    s_started = true;
    return ESP_OK;
}

/* Uplink: every frame this node originates goes "to the board" whatever DST_MAC says. */
static esp_err_t node_send(const uint8_t *dst_mac, const uint8_t *frame, size_t len)
{
    (void)dst_mac;
    if (mesh_level() == 0) return ESP_ERR_INVALID_STATE; /* not joined: nothing can carry it */
    if (is_root()) return tcp_write_frame(frame, len);
    return mesh_send_raw(MESH_UPLINK_MSG_ID, frame, len, esp_mesh_lite_send_raw_msg_to_root);
}

static bool node_is_up(void)
{
    const uint8_t level = mesh_level();
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
    return mesh_level(); /* a false root (level 1 on another unit) is not joined */
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
    if (mesh_level() == 0) return ESP_ERR_INVALID_STATE;
    return mesh_send_raw(MESH_DOWNLINK_MSG_ID, frame, len, esp_mesh_lite_send_broadcast_raw_msg_to_child);
}
