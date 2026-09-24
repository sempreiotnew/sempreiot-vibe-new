/*
 * Setup network: SoftAP "SIOT-SETUP-<id>", WPA2, password = pop.
 * Blueprint §0 "Setup network" / §2.
 */
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* Brings up esp_netif/esp_event/esp_wifi and raises the AP. Call once. */
void siot_wifi_softap_start(const char *device_id, const char *pop);

#ifdef __cplusplus
}
#endif
