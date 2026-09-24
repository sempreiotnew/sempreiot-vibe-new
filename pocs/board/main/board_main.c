/*
 * board — POC-BRIEF.md §4.2. Setup mode (siot_prov) if unprovisioned;
 * otherwise normal mode: installation-network AP, TCP bridge to the mesh
 * root, tablet-facing SAFR serial link, root duties.
 */
#include <string.h>

#include "esp_event.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"

#include "prov_http.h"
#include "prov_store.h"
#include "prov_types.h"
#include "wifi_softap.h"

#include "board_button.h"
#include "board_state.h"
#include "root_duties.h"
#include "safr_frame.h"
#include "serial_link.h"
#include "siot_led.h"
#include "tcp_link.h"

static board_state_t s_board;

static void on_provisioned(const siot_installation_t *inst)
{
    (void)inst;
    esp_restart(); /* reload as provisioned on the next boot */
}

/* Normal-mode installation AP: net_ssid/net_psk/channel from the loaded
 * installation code (POC-BRIEF §4.2) — distinct from siot_wifi_softap_start,
 * which is setup-mode-only (fixed "SIOT-SETUP-<id>" SSID, pop as password). */
static void start_installation_ap(const siot_installation_t *inst)
{
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_ap();

    wifi_init_config_t init_cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init_cfg));

    wifi_config_t ap_cfg = {
        .ap = {
            .authmode = WIFI_AUTH_WPA2_PSK,
            .max_connection = BOARD_MAX_CHILDREN,
            .channel = inst->channel,
            .ssid_hidden = 0,
        },
    };
    strlcpy((char *)ap_cfg.ap.ssid, inst->net_ssid, sizeof(ap_cfg.ap.ssid));
    ap_cfg.ap.ssid_len = (uint8_t)strlen(inst->net_ssid);
    strlcpy((char *)ap_cfg.ap.password, inst->net_psk, sizeof(ap_cfg.ap.password));

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &ap_cfg));
    ESP_ERROR_CHECK(esp_wifi_start());
    /* esp_netif's default AP config already hands out 192.168.4.1 + DHCP. */
}

static void on_uplink_frame(const uint8_t *raw, size_t len,
                           const safr_rx_frame_t *rx)
{
    root_duties_handle_uplink(&s_board, raw, len, rx);
    siot_led_comm_blink(); /* a frame arrived from the mesh */
}

/* Reframes the tablet's raw byte stream (SOF+LEN+CRC), same resync loop as
 * mocked-device/main/mocked-device.c's rx_task and tcp_link.c's uplink side,
 * over serial_link instead of a socket. */
static void downlink_task(void *arg)
{
    (void)arg;
    static uint8_t acc[SAFR_MAX_FRAME * 2];
    size_t acc_len = 0;

    for (;;) {
        uint8_t chunk[256];
        const size_t n = serial_link_recv(chunk, sizeof(chunk), pdMS_TO_TICKS(100));
        if (n == 0) continue;

        if (acc_len + n > sizeof(acc)) acc_len = 0; /* overflow guard */
        memcpy(&acc[acc_len], chunk, n);
        acc_len += n;

        size_t pos = 0;
        while (acc_len - pos >= SAFR_MIN_FRAME) {
            if (acc[pos] != SAFR_SOF) { pos++; continue; }
            const size_t flen = ((size_t)acc[pos + 2] << 8) | acc[pos + 3];
            if (flen < SAFR_MIN_FRAME || flen > SAFR_MAX_FRAME) { pos++; continue; }
            if (acc_len - pos < flen) break; /* wait for more bytes */

            safr_rx_frame_t rx;
            if (safr_parse_frame(&acc[pos], flen, &rx)) {
                root_duties_handle_downlink(&s_board, &acc[pos], flen, &rx);
                pos += flen;
            } else {
                pos++; /* false SOF or corrupt frame: resync by one byte */
            }
        }
        memmove(acc, &acc[pos], acc_len - pos);
        acc_len -= pos;
    }
}

void app_main(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    siot_factory_id_t factory;
    ESP_ERROR_CHECK(siot_store_load_factory(&factory));

    siot_installation_t inst;
    if (!siot_store_load_installation(&inst)) {
        /* Setup mode: siot_prov owns the rest of boot from here.
         * on_provisioned() stores the code and reboots into normal mode. */
        siot_led_init();
        siot_led_set_pattern(SIOT_LED_WHITE_BLINK, 0);
        siot_wifi_softap_start(factory.id, factory.pop);
        siot_http_start(&factory, SIOT_ROLE_BOARD, on_provisioned);
        board_button_start(); /* factory-reset hold only, armed in setup mode too */
        return;
    }

    uint8_t board_mac[6];
    esp_read_mac(board_mac, ESP_MAC_WIFI_STA);

    siot_led_init();
    /* Bench LED (no console on the board): magenta solid = this is the
     * board ("router" of the mesh), installed and serving; blue fast blink
     * (magenta off meanwhile) for every frame exchanged with the mesh --
     * received (on_uplink_frame) or sent (tcp_link_send). */
    siot_led_set_pattern(SIOT_LED_MAGENTA_SOLID, 0);

    safr_frame_init(inst.system_id, inst.safr_psk);
    root_duties_init(&s_board, board_mac, &inst);

    /* /enroll (POC-BRIEF §5) was persisted independently of /provision's
     * reboot timing — load it back now that root_duties_init has zeroed
     * s_board, so INSTALLATION (0x09) can report real enrolled devices. */
    siot_enrolled_entry_t enrolled[SIOT_MAX_ENROLLED];
    size_t enrolled_count = siot_store_load_enrolled(enrolled, SIOT_MAX_ENROLLED);
    for (size_t i = 0; i < enrolled_count && i < BOARD_MAX_ENROLLED; i++) {
        s_board.enrolled[i].used = true;
        memcpy(s_board.enrolled[i].mac, enrolled[i].mac, 6);
        strlcpy(s_board.enrolled[i].name, enrolled[i].name, sizeof(s_board.enrolled[i].name));
        strlcpy(s_board.enrolled[i].zone, enrolled[i].zone, sizeof(s_board.enrolled[i].zone));
    }

    serial_link_init();
    start_installation_ap(&inst);
    tcp_link_init(on_uplink_frame);
    board_button_start(); /* factory-reset hold, blueprint "any time" */

    xTaskCreate(downlink_task, "downlink", 4096, NULL, 10, NULL);

    for (;;) {
        root_duties_step(&s_board, esp_timer_get_time() / 1000);
        vTaskDelay(pdMS_TO_TICKS(250));
    }
}
