/* From pocs/components/siot_prov/wifi_softap.c. */
#include <stdio.h>
#include <string.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"

#include "prov_internal.h"

static const char *TAG = "siot_prov";

#define SETUP_CHANNEL 6
#define SETUP_MAX_STA 4

esp_err_t prov_softap_start(const siot_identity_t *id)
{
    esp_err_t err = esp_netif_init();
    if (err != ESP_OK) return err;
    err = esp_event_loop_create_default();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err; /* evbus may own it */
    if (esp_netif_create_default_wifi_ap() == NULL) return ESP_FAIL;

    wifi_init_config_t init_cfg = WIFI_INIT_CONFIG_DEFAULT();
    err = esp_wifi_init(&init_cfg);
    if (err != ESP_OK) return err;

    wifi_config_t ap_cfg = {
        .ap = {
            .authmode = WIFI_AUTH_WPA2_PSK,
            .max_connection = SETUP_MAX_STA,
            .channel = SETUP_CHANNEL,
        },
    };
    const int ssid_len = snprintf((char *)ap_cfg.ap.ssid, sizeof(ap_cfg.ap.ssid),
                                  "SIOT-SETUP-%s", id->id);
    ap_cfg.ap.ssid_len = (uint8_t)(ssid_len < 0 ? 0 : ssid_len);
    strlcpy((char *)ap_cfg.ap.password, id->pop, sizeof(ap_cfg.ap.password));

    err = esp_wifi_set_mode(WIFI_MODE_AP);
    if (err == ESP_OK) err = esp_wifi_set_config(WIFI_IF_AP, &ap_cfg);
    if (err == ESP_OK) err = esp_wifi_start();
    if (err != ESP_OK) return err;

    ESP_LOGI(TAG, "setup network up: SSID=%s (192.168.4.1)", ap_cfg.ap.ssid);
    return ESP_OK;
}
