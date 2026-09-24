#include "node_button.h"

#include "driver/gpio.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "prov_store.h"

static const char *TAG = "node_button";

#define GPIO_BUTTON             21
#define DEBOUNCE_PERIOD_MS      10
#define DEBOUNCE_SAMPLES        3
#define LONG_PRESS_MS           5000  /* factory reset, blueprint "any time" */
#define DOUBLE_PRESS_WINDOW_MS  500   /* 2nd press must start within this */

static TaskHandle_t s_task;
static node_button_event_cb_t s_on_short;
static node_button_event_cb_t s_on_double;

static void IRAM_ATTR gpio_isr_handler(void *arg)
{
    BaseType_t hp_task_woken = pdFALSE;
    vTaskNotifyGiveFromISR(s_task, &hp_task_woken);
    portYIELD_FROM_ISR(hp_task_woken);
}

static void factory_reset(void)
{
    ESP_LOGW(TAG, "button held >= %d s -> factory reset (erase siot_inst)",
             LONG_PRESS_MS / 1000);
    siot_store_erase_installation();
    esp_restart();
}

static void button_task(void *arg)
{
    uint8_t stable = 1, candidate = 1, count = DEBOUNCE_SAMPLES;
    bool    down = false;
    int64_t down_at_ms = 0;
    bool    long_fired = false;
    /* Pending single press, waiting to see if a second one arrives soon
     * enough to promote it to a double press. */
    bool    pending_single = false;
    int64_t pending_deadline_ms = 0;

    stable = candidate = (uint8_t)gpio_get_level(GPIO_BUTTON);
    down = (stable == 0);
    if (down) down_at_ms = esp_timer_get_time() / 1000;

    for (;;) {
        const uint8_t raw = (uint8_t)gpio_get_level(GPIO_BUTTON);
        if (raw != candidate) {
            candidate = raw;
            count = 1;
        } else if (count < DEBOUNCE_SAMPLES) {
            count++;
        }

        bool changed = false;
        if (count >= DEBOUNCE_SAMPLES && stable != candidate) {
            stable = candidate;
            changed = true;
        }

        const int64_t now_ms = esp_timer_get_time() / 1000;
        const bool pressed = (stable == 0); /* active low, pull-up */

        if (pressed && !down) { /* press edge */
            down = true;
            down_at_ms = now_ms;
            long_fired = false;
        } else if (pressed && down && !long_fired &&
                   now_ms - down_at_ms >= LONG_PRESS_MS) {
            long_fired = true;
            factory_reset(); /* reboots -- does not return */
        } else if (!pressed && down) { /* release edge */
            down = false;
            if (!long_fired) {
                if (pending_single && now_ms <= pending_deadline_ms) {
                    pending_single = false;
                    ESP_LOGI(TAG, "double press -> alarm");
                    if (s_on_double) s_on_double();
                } else {
                    pending_single = true;
                    pending_deadline_ms = now_ms + DOUBLE_PRESS_WINDOW_MS;
                }
            }
        }

        /* A pending single press that timed out with no second press
         * fires as a plain short press (MANUAL_TEST). */
        if (pending_single && !down && now_ms > pending_deadline_ms) {
            pending_single = false;
            ESP_LOGI(TAG, "short press -> manual test");
            if (s_on_short) s_on_short();
        }

        (void)changed;

        const bool settling = count < DEBOUNCE_SAMPLES;
        const bool waiting_double = pending_single && !down;
        const TickType_t wait =
            (settling || down || waiting_double) ? pdMS_TO_TICKS(DEBOUNCE_PERIOD_MS)
                                                 : portMAX_DELAY;
        ulTaskNotifyTake(pdTRUE, wait);
    }
}

void node_button_start(node_button_event_cb_t on_short_press,
                       node_button_event_cb_t on_double_press)
{
    s_on_short = on_short_press;
    s_on_double = on_double_press;

    const gpio_config_t cfg = {
        .pin_bit_mask = 1ULL << GPIO_BUTTON,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_ANYEDGE,
    };
    ESP_ERROR_CHECK(gpio_config(&cfg));

    xTaskCreate(button_task, "node_button", 3072, NULL, 10, &s_task);

    ESP_ERROR_CHECK(gpio_install_isr_service(0));
    ESP_ERROR_CHECK(gpio_isr_handler_add(GPIO_BUTTON, gpio_isr_handler, NULL));
    xTaskNotifyGive(s_task);
}
