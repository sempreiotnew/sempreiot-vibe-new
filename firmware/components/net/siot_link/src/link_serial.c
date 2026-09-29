/* link_serial — the tablet link (brief §6.5), from pocs/board/main/board_main.c
 * downlink_task + serial_link.c. Same SAFR bytes as every other hop, plus the
 * raw runs of a firmware push and its line speed (protocol §13.3). */
#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "siot_hal_serial.h"
#include "siot_link.h"

static const char *TAG = "siot_link_serial";

#define SERIAL_RX_CHUNK        1024
#define SERIAL_RX_TIMEOUT_MS   100
#define RAW_SILENCE_MS         1000   /* a raw run whose sender went silent is dropped */
#define BAUD_SILENCE_MS        20000  /* §13.3: back to the default speed */

static TaskHandle_t s_task;
static siot_link_stream_t s_stream; /* touched by the rx task only */
static volatile bool s_baud_changed;

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

static void serial_task(void *arg)
{
    (void)arg;
    static uint8_t chunk[SERIAL_RX_CHUNK];
    siot_link_stream_reset(&s_stream);
    int64_t last_rx_ms = now_ms();   /* any byte: a raw run is still arriving */
    int64_t last_good_ms = now_ms(); /* a frame whose CRC matched, or announced raw bytes */
    for (;;) {
        const size_t n = siot_hal_serial_read(chunk, sizeof(chunk), SERIAL_RX_TIMEOUT_MS);
        const int64_t t = now_ms();
        if (s_baud_changed) { s_baud_changed = false; last_good_ms = t; }
        if (n > 0) {
            last_rx_ms = t;
            const uint32_t before = s_stream.good;
            siot_link_stream_feed(&s_stream, SIOT_LINK_SERIAL, chunk, n);
            if (s_stream.good != before) last_good_ms = t;
        }
        if (s_stream.raw_left > 0 && t - last_rx_ms > RAW_SILENCE_MS) {
            ESP_LOGW(TAG, "raw run: %u byte(s) never came, dropped", (unsigned)s_stream.raw_left);
            siot_link_stream_abort_raw(&s_stream);
        }
        /* Bytes are not traffic: a tablet that went back to the default speed
         * and keeps talking reaches us as noise, and must not hold us here. */
        if (siot_hal_serial_baud() != SIOT_HAL_SERIAL_BAUD && t - last_good_ms > BAUD_SILENCE_MS) {
            ESP_LOGW(TAG, "%d s without a valid frame at %u baud: back to %u", BAUD_SILENCE_MS / 1000,
                     (unsigned)siot_hal_serial_baud(), (unsigned)SIOT_HAL_SERIAL_BAUD);
            siot_link_stream_abort_raw(&s_stream);
            siot_hal_serial_set_baud(SIOT_HAL_SERIAL_BAUD);
            siot_link_stream_reset(&s_stream);
            last_rx_ms = last_good_ms = t;
        }
    }
}

static esp_err_t serial_start(void)
{
    if (s_task != NULL) return ESP_OK;
    /* 8 KB: a push writes flash or a FAT file and hashes 4 KB from this task (protocol §13.3) */
    return xTaskCreatePinnedToCore(serial_task, "serial_task", 8192, NULL, 13, &s_task, 1) == pdPASS
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

esp_err_t siot_link_serial_expect_raw(size_t len, siot_link_raw_cb_t cb, void *ctx)
{
    if (s_task == NULL || xTaskGetCurrentTaskHandle() != s_task) return ESP_ERR_INVALID_STATE;
    return siot_link_stream_expect_raw(&s_stream, len, cb, ctx);
}

esp_err_t siot_link_serial_set_baud(uint32_t baud)
{
    s_baud_changed = true; /* the silence clock starts again at the new speed */
    const esp_err_t err = siot_hal_serial_set_baud(baud);
    if (err == ESP_OK) ESP_LOGW(TAG, "tablet link at %u baud", (unsigned)baud);
    return err;
}
