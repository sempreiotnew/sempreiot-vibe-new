#include "wifi_softap.h"

#include <stdio.h>
#include <string.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"

static const char *TAG = "siot_softap";

void siot_wifi_softap_start(const char *device_id, const char *pop)
{
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_ap();

    wifi_init_config_t init_cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init_cfg));

    wifi_config_t ap_cfg = {
        .ap = {
            .authmode = WIFI_AUTH_WPA2_PSK,
            .max_connection = 4,
            .channel = 6,
        },
    };
    int ssid_len = snprintf((char *)ap_cfg.ap.ssid, sizeof(ap_cfg.ap.ssid),
                             "SIOT-SETUP-%s", device_id);
    ap_cfg.ap.ssid_len = (uint8_t)(ssid_len < 0 ? 0 : ssid_len);
    strlcpy((char *)ap_cfg.ap.password, pop, sizeof(ap_cfg.ap.password));

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &ap_cfg));
    ESP_ERROR_CHECK(esp_wifi_start());

    ESP_LOGI(TAG, "setup network up: SSID=%s (esp_netif default AP IP 192.168.4.1)",
             ap_cfg.ap.ssid);
}
