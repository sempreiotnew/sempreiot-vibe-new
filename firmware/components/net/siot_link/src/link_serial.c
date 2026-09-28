/* link_serial — the tablet link (brief §6.5), from pocs/board/main/board_main.c
 * downlink_task + serial_link.c. Same SAFR bytes as every other hop. */
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "siot_hal_serial.h"
#include "siot_link.h"

#define SERIAL_RX_CHUNK     256
#define SERIAL_RX_TIMEOUT_MS 100

static TaskHandle_t s_task;

static void serial_task(void *arg)
{
    (void)arg;
    static siot_link_reasm_t reasm;
    uint8_t chunk[SERIAL_RX_CHUNK];
    siot_link_reasm_reset(&reasm);
    for (;;) {
        const size_t n = siot_hal_serial_read(chunk, sizeof(chunk), SERIAL_RX_TIMEOUT_MS);
        if (n > 0) siot_link_reasm_feed(&reasm, SIOT_LINK_SERIAL, chunk, n);
    }
}

static esp_err_t serial_start(void)
{
    if (s_task != NULL) return ESP_OK;
    return xTaskCreatePinnedToCore(serial_task, "serial_task", 4096, NULL, 13, &s_task, 1) == pdPASS
               ? ESP_OK : ESP_ERR_NO_MEM;
}

static esp_err_t serial_send(const uint8_t *dst_mac, const uint8_t *frame, size_t len)
{
    (void)dst_mac; /* one peer: the tablet */
    return siot_hal_serial_write(frame, len);
}

static bool serial_is_up(void)
{
    return s_task != NULL; /* the link's liveness is the central's job: spec §9.3 LINK_CHECK */
}

static int serial_rssi(void) { return 0; }

static const siot_link_ops_t s_serial_ops = {
    .start = serial_start,
    .stop = NULL,
    .send = serial_send,
    .is_up = serial_is_up,
    .rssi = serial_rssi,
};

esp_err_t siot_link_serial_init(void)
{
    const esp_err_t err = siot_hal_serial_init();
    if (err != ESP_OK) return err;
    return siot_link_register(SIOT_LINK_SERIAL, &s_serial_ops);
}
