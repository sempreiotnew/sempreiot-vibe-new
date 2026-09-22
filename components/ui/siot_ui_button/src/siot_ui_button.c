#include "siot_ui_button.h"

#include <stdbool.h>
#include <stdint.h>

#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "siot_board_def.h"
#include "siot_config.h"
#include "siot_evbus.h"
#include "siot_hal_gpio.h"

static const char *TAG = "siot_ui_button";

#define DEBOUNCE_PERIOD_MS      10
#define DEBOUNCE_SAMPLES        3
#define LONG_PRESS_MS           5000  /* factory reset */
#define DOUBLE_PRESS_WINDOW_MS  500   /* 2nd press must start within this */
#define RESET_GRACE_MS          300   /* let the bus deliver FACTORY_RESET before reboot */

static TaskHandle_t s_task;
static int s_pin;

static void IRAM_ATTR on_edge(int pin, void *ctx)
{
    (void)pin; (void)ctx;
    BaseType_t hp_task_woken = pdFALSE;
    vTaskNotifyGiveFromISR(s_task, &hp_task_woken);
    portYIELD_FROM_ISR(hp_task_woken);
}

static void factory_reset(void)
{
    ESP_LOGW(TAG, "held >= %d s -> factory reset", LONG_PRESS_MS / 1000);
    siot_evbus_post(SIOT_EVT_BUTTON_HOLD, NULL, 0);
    siot_evbus_post(SIOT_EVT_FACTORY_RESET, NULL, 0);
    vTaskDelay(pdMS_TO_TICKS(RESET_GRACE_MS));
    siot_config_factory_reset();
    esp_restart();
}

static void button_task(void *arg)
{
    (void)arg;
    uint8_t stable, candidate, count = DEBOUNCE_SAMPLES;
    bool    down;
    int64_t down_at_ms = 0;
    bool    long_fired = false;
    bool    pending_single = false;
    int64_t pending_deadline_ms = 0;

    stable = candidate = (uint8_t)siot_hal_gpio_read(s_pin);
    down = (stable == 0);
    if (down) down_at_ms = esp_timer_get_time() / 1000;

    for (;;) {
        const uint8_t raw = (uint8_t)siot_hal_gpio_read(s_pin);
        if (raw != candidate) {
            candidate = raw;
            count = 1;
        } else if (count < DEBOUNCE_SAMPLES) {
            count++;
        }
        if (count >= DEBOUNCE_SAMPLES && stable != candidate) stable = candidate;

        const int64_t now_ms = esp_timer_get_time() / 1000;
        const bool pressed = (stable == 0); /* active low, pull-up */

        if (pressed && !down) {
            down = true;
            down_at_ms = now_ms;
            long_fired = false;
        } else if (pressed && down && !long_fired && now_ms - down_at_ms >= LONG_PRESS_MS) {
            long_fired = true;
            factory_reset(); /* reboots, does not return */
        } else if (!pressed && down) {
            down = false;
            if (!long_fired) {
                if (pending_single && now_ms <= pending_deadline_ms) {
                    pending_single = false;
                    ESP_LOGI(TAG, "double tap");
                    siot_evbus_post(SIOT_EVT_BUTTON_DOUBLE_TAP, NULL, 0);
                } else {
                    pending_single = true;
                    pending_deadline_ms = now_ms + DOUBLE_PRESS_WINDOW_MS;
                }
            }
        }

        /* A pending single press that timed out with no second press is a tap. */
        if (pending_single && !down && now_ms > pending_deadline_ms) {
            pending_single = false;
            ESP_LOGI(TAG, "tap");
            siot_evbus_post(SIOT_EVT_BUTTON_TAP, NULL, 0);
        }

        const bool settling = count < DEBOUNCE_SAMPLES;
        const bool waiting_double = pending_single && !down;
        const TickType_t wait = (settling || down || waiting_double)
                                    ? pdMS_TO_TICKS(DEBOUNCE_PERIOD_MS) : portMAX_DELAY;
        ulTaskNotifyTake(pdTRUE, wait);
    }
}

esp_err_t siot_ui_button_init(void)
{
    s_pin = siot_board_def()->button;
    if (s_pin == SIOT_PIN_NONE) return ESP_ERR_NOT_SUPPORTED;

    esp_err_t err = siot_hal_gpio_input_init(s_pin, true);
    if (err != ESP_OK) return err;

    if (xTaskCreate(button_task, "siot_button", 3072, NULL, 8, &s_task) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }
    err = siot_hal_gpio_edge_subscribe(s_pin, on_edge, NULL);
    if (err != ESP_OK) return err;
    xTaskNotifyGive(s_task);
    return ESP_OK;
}
