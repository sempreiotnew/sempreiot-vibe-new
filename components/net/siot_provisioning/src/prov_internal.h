/* Private interface between the SoftAP, the HTTP server and the component entry. */
#pragma once

#include <stdbool.h>

#include "esp_err.h"

#include "siot_identity.h"

/* Setup network: SoftAP "SIOT-SETUP-<id>", WPA2 = pop, channel 6, 4 STA, 192.168.4.1. */
esp_err_t prov_softap_start(const siot_identity_t *id);

/* HTTP contract on port 80. `on_stored` runs when normal-mode boot should happen. */
typedef void (*prov_done_cb_t)(void);
esp_err_t prov_http_start(const siot_identity_t *id, bool is_board, prov_done_cb_t on_stored);
