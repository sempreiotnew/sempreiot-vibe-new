/* sempreiot-node — app_main.
 *
 * Step 1 of brief §15: initialise NVS and log the version. The rest of the boot
 * sequence (brief §3: identity, board_def, hal, ui, evbus, config, safr,
 * netcore) is wired in by the following steps; nothing else lives here.
 */
#include "esp_err.h"
#include "esp_log.h"
#include "nvs_flash.h"

#include "siot_version.h"

static const char *TAG = "node";

/* Brief §3 step 1: erase + retry on NO_FREE_PAGES / NEW_VERSION_FOUND
 * (same sequence as pocs/node/main/node.c). */
static void nvs_init(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);
}

void app_main(void)
{
    nvs_init();
    ESP_LOGI(TAG, "sempreiot-node fw %s (build %s)",
             siot_version_string(), siot_version_build_id());
}
