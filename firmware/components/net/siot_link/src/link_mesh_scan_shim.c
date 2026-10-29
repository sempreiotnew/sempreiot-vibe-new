/* link_mesh_scan_shim — Mesh-Lite 1.0.2 on ESP-IDF v5.5.2 (2026-10-29).
 *
 * The prebuilt Mesh-Lite library was compiled against an ESP-IDF whose
 * wifi_scan_config_t was 32 bytes. Its three scan call sites zero-fill exactly
 * 32 bytes of a stack struct and call esp_wifi_scan_start (seen in
 * libesp_mesh_lite_esp32s3.a: esp_mesh_lite_connect, esp_mesh_lite_check_best_ap,
 * esp_mesh_lite_scan_to_get_router_rssi). On v5.5.2 the struct is 44 bytes: the
 * last 12 — channel_bitmap and coex_background_scan — are stack garbage. The
 * router scan names a channel, so the driver ignores the bitmap and that scan
 * works; the PARENT scan runs on all channels (channel 0), the driver takes the
 * garbage bitmap, logs "2g bitmap contains only invalid channels" and returns
 * no networks. A node therefore never discovered another node: every unit that
 * heard the board became root and nobody ever joined a sibling (bench
 * 2026-10-28/29).
 *
 * This wrapper (-Wl,--wrap=esp_wifi_scan_start, siot_link/CMakeLists.txt, node
 * image only) rebuilds the struct: the 32 bytes the library fills, the rest
 * zero — all channels, as the library intends. It drops any channel_bitmap a
 * caller set on purpose; nothing in the node image does. Remove it the day
 * Mesh-Lite ships a build for this IDF (the library's own log line above
 * disappearing is the proof it was needed). */
#include <stddef.h>
#include <string.h>

#include "esp_wifi.h"

#define MESH_LITE_SCAN_CONFIG_SIZE 32

_Static_assert(offsetof(wifi_scan_config_t, channel_bitmap) == MESH_LITE_SCAN_CONFIG_SIZE,
               "wifi_scan_config_t layout changed: re-check what Mesh-Lite fills (link_mesh_scan_shim.c)");
_Static_assert(sizeof(wifi_scan_config_t) > MESH_LITE_SCAN_CONFIG_SIZE,
               "wifi_scan_config_t is back to the size Mesh-Lite was built for: the shim can go");

esp_err_t __real_esp_wifi_scan_start(const wifi_scan_config_t *config, bool block);

esp_err_t __wrap_esp_wifi_scan_start(const wifi_scan_config_t *config, bool block)
{
    if (config == NULL) return __real_esp_wifi_scan_start(NULL, block);
    wifi_scan_config_t fixed;
    memset(&fixed, 0, sizeof(fixed));
    memcpy(&fixed, config, MESH_LITE_SCAN_CONFIG_SIZE);
    return __real_esp_wifi_scan_start(&fixed, block);
}
