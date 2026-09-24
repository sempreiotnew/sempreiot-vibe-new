/*
 * SAFR v2 mock device — simulates an esp-mesh-lite network's root node
 * bridged to the central over UART0.
 * Protocol: sempreiot-vibe-new/docs/safr/protocol-safr-v3.md
 *
 * The console is disabled (CONFIG_ESP_CONSOLE_NONE, see sdkconfig.defaults):
 * frames go through the raw UART driver, so the VFS newline translation that
 * corrupted v1 binary output (0x0A -> 0x0D 0x0A) can never happen. After
 * changing sdkconfig.defaults run: rm sdkconfig && idf.py reconfigure.
 */
#include <string.h>

#include "driver/uart.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "mesh_sim.h"
#include "safr_frame.h"

#define SAFR_UART       UART_NUM_0
#define UART_BAUD       115200
#define RX_BUF_SIZE     2048
#define TX_BUF_SIZE     4096
#define STEP_MS         250

void safr_link_send(const uint8_t *frame, size_t len)
{
    uart_write_bytes(SAFR_UART, frame, len);
}

/* Reassembles downlink frames from the central: SOF + LEN + CRC resync,
 * mirroring the central's reframer (spec §9). */
static void rx_task(void *arg)
{
    static uint8_t acc[SAFR_MAX_FRAME * 2];
    static size_t acc_len = 0;
    uint8_t chunk[256];

    for (;;) {
        const int n = uart_read_bytes(SAFR_UART, chunk, sizeof(chunk),
                                      pdMS_TO_TICKS(100));
        if (n <= 0) continue;

        if (acc_len + (size_t)n > sizeof(acc)) acc_len = 0; /* overflow guard */
        memcpy(&acc[acc_len], chunk, (size_t)n);
        acc_len += (size_t)n;

        size_t pos = 0;
        while (acc_len - pos >= SAFR_MIN_FRAME) {
            if (acc[pos] != SAFR_SOF) { pos++; continue; }
            const size_t flen = ((size_t)acc[pos + 2] << 8) | acc[pos + 3];
            if (flen < SAFR_MIN_FRAME || flen > SAFR_MAX_FRAME) { pos++; continue; }
            if (acc_len - pos < flen) break; /* wait for more bytes */

            safr_rx_frame_t rx;
            if (safr_parse_frame(&acc[pos], flen, &rx)) {
                mesh_sim_handle_rx(&rx, esp_timer_get_time() / 1000);
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
    const uart_config_t cfg = {
        .baud_rate = UART_BAUD,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    ESP_ERROR_CHECK(uart_driver_install(SAFR_UART, RX_BUF_SIZE, TX_BUF_SIZE, 0,
                                        NULL, 0));
    ESP_ERROR_CHECK(uart_param_config(SAFR_UART, &cfg));
    /* Explicit pin routing: with the console disabled nothing else claims
     * UART0, so pin the classic ESP32 defaults (TX=GPIO1, RX=GPIO3) that the
     * on-board USB-serial bridge is wired to. */
    ESP_ERROR_CHECK(uart_set_pin(SAFR_UART, 1, 3, UART_PIN_NO_CHANGE,
                                 UART_PIN_NO_CHANGE));

    safr_frame_init();
    mesh_sim_init();

    /* Let the host's port settle past the boot-ROM chatter, then emit the
     * deterministic Appendix-A vectors for capture-based interop tests. */
    vTaskDelay(pdMS_TO_TICKS(1500));
    mesh_sim_emit_boot_vectors();

    xTaskCreate(rx_task, "safr_rx", 4096, NULL, 10, NULL);

    for (;;) {
        mesh_sim_step(esp_timer_get_time() / 1000);
        vTaskDelay(pdMS_TO_TICKS(STEP_MS));
    }
}
