/* link_mesh_scan_shim — Mesh-Lite 1.0.2 on ESP-IDF v5.5.2 (2026-10-30).
 *
 * The Mesh-Lite component ships a prebuilt library, compiled by Espressif
 * with the ESP-IDF 5.1 toolchain (GCC 12.2, 2023), when wifi_scan_config_t
 * was 32 bytes. On v5.5.2 it is 44: channel_bitmap (offset 32) and
 * coex_background_scan were added at the end. The library's scan call sites
 * (esp_mesh_lite_comm_scan, esp_mesh_lite_scan_to_get_router_rssi, seen in
 * the disassembly of libesp_mesh_lite_esp32s3.a) zero exactly 32 bytes of a
 * stack struct and hand it to esp_wifi_scan_start: the last 12 bytes are
 * whatever the stack held.
 *
 * When the scan names a channel the driver ignores the bitmap and the scan
 * works. The PARENT scan — a node that is not connected yet, looking for the
 * board and for other nodes — runs on all channels (channel 0), so the driver
 * reads the garbage bitmap, logs "2g bitmap contains only invalid channels"
 * (0xb170, 0xb0f0 … a different value every boot) and the scan comes back
 * EMPTY, with the board right there. Mesh-Lite then connects to the router
 * SSID blind and makes itself root; it never sees another node. Bench
 * 2026-10-29/30: two nodes both root, a far node never joining the node
 * beside it, a node forbidden from level 1 scanning forever.
 *
 * This wrapper (-Wl,--wrap=esp_wifi_scan_start, siot_link/CMakeLists.txt,
 * node image only) rebuilds the struct: the 32 bytes the library fills, the
 * rest zero — all channels, as the library intends. It drops any
 * channel_bitmap a caller set on purpose; no caller in the node image sets
 * one (Mesh-Lite and wifi_provisioning are the only callers). Remove it the
 * day Mesh-Lite ships a build for this IDF.
 *
 * Proof it is in and working, in this order:
 *   1. the final ELF: esp_mesh_lite_wifi_scan_start calls
 *      __wrap_esp_wifi_scan_start (tools: objdump -d, see the fix commit);
 *   2. the node boot log: the "2g bitmap" error line is gone and
 *      "Mesh-Lite Scan done" is followed by the board's SSID and real MAC
 *      in the "wifi_cfg …, ap_info.ssid …" line. */
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
