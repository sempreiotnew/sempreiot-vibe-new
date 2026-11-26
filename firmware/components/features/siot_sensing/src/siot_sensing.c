/* The mains unit's side of siot_sensing: one reading per second, the rules,
 * and the unit's own EVENTs through siot_netcore. The unit never sleeps, so
 * the sensor's interrupt pin is not needed to detect anything; it is watched
 * and logged (the DTR test, brief §10.1 part A). */
#include "siot_sensing.h"

#include "sdkconfig.h"

#include "driver/gpio.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "siot_netcore.h"
#include "siot_safr.h"
#include "siot_sensing_rules.h"
#include "siot_sensor.h"

static const char *TAG = "sensing";

#define LOG_EVERY_S   30
#define REARM_EVERY_S 60

static siot_sensing_rules_t s_rules;
/* What the frames carry, written by the sampling task and read by netcore's
 * task: single aligned words, no lock. */
static volatile int16_t s_temp_x10 = (int16_t)SAFR_NA_I16;
static volatile uint8_t s_humidity = SAFR_NA_U8;
static volatile uint8_t s_fault_flags;

static uint32_t now_s(void) { return (uint32_t)(esp_timer_get_time() / 1000000); }

static void env_hook(int16_t *temp_x10, uint8_t *humidity, uint8_t *fault_flags, void *ctx)
{
    (void)ctx;
    *temp_x10 = s_temp_x10;
    *humidity = s_humidity;
    *fault_flags = s_fault_flags;
}

static void act(uint32_t acts, const siot_sensor_env_t *e)
{
    const int t10 = e->ok ? (int)(e->temp_c100 / 10) : 0;
    if (acts & SIOT_SENSE_ACT_FAULT_SET) {
        ESP_LOGE(TAG, "SENSOR_FAULT: the temperature sensor does not answer");
        siot_netcore_raise_event(SAFR_EVT_TROUBLE, SAFR_EC_SENSOR_FAULT, SAFR_FC_TEMP_SENSOR);
    }
    if (acts & SIOT_SENSE_ACT_FAULT_CLEAR) {
        ESP_LOGW(TAG, "the temperature sensor answers again: RESTORE");
        siot_netcore_raise_event(SAFR_EVT_OK, SAFR_EC_RESTORE, SAFR_FC_TEMP_SENSOR);
    }
    if (acts & SIOT_SENSE_ACT_HEAT_ALARM) {
        ESP_LOGE(TAG, "HEAT_ALARM: %d.%d C (fixed, >= 57.0 C)", t10 / 10, t10 % 10);
        siot_netcore_raise_event(SAFR_EVT_ALARM, SAFR_EC_HEAT_ALARM, 0);
    }
    if (acts & SIOT_SENSE_ACT_RISE_ALARM) {
        ESP_LOGE(TAG, "HEAT_RISE_ALARM: 8.0 C or more within 60 s, now %d.%d C", t10 / 10, t10 % 10);
        siot_netcore_raise_event(SAFR_EVT_ALARM, SAFR_EC_HEAT_RISE, 0);
    }
    if (acts & SIOT_SENSE_ACT_HEAT_RESTORE) {
        ESP_LOGW(TAG, "temperature back below 54.0 C for 60 s: RESTORE (the alarm stays latched until RESET)");
        siot_netcore_raise_event(SAFR_EVT_OK, SAFR_EC_RESTORE, 0);
    }
    if (acts & SIOT_SENSE_ACT_WET_SET) {
        ESP_LOGE(TAG, "SENSOR_WET: humidity %ld.%02ld %%", (long)(e->rh_c100 / 100), (long)(e->rh_c100 % 100));
        siot_netcore_raise_event(SAFR_EVT_TROUBLE, SAFR_EC_SENSOR_WET, SAFR_FC_SENSOR_WET);
    }
    if (acts & SIOT_SENSE_ACT_WET_CLEAR) {
        ESP_LOGW(TAG, "humidity back below 95 %%: RESTORE");
        siot_netcore_raise_event(SAFR_EVT_OK, SAFR_EC_RESTORE, SAFR_FC_SENSOR_WET);
    }
}

/* The interrupt pin, seen from a unit that is awake: active low, held by the
 * sensor until its status register is read. */
static void watch_int_pin(void)
{
    static int s_last = 1;
    const int pin = siot_sensor_int_pin();
    if (pin < 0) return;
    const int level = gpio_get_level((gpio_num_t)pin);
    if (level == s_last) return;
    s_last = level;
    if (level == 0) {
        const uint8_t st = siot_sensor_int_status(); /* releases the pin */
        ESP_LOGW(TAG, "sensor interrupt: GPIO %d went LOW, status 0x%02X%s; pin after the read: %d", pin, st,
                 (st & SIOT_SENSOR_INT_TH) ? " (temperature-high)" : " (NOT temperature-high?)",
                 gpio_get_level((gpio_num_t)pin));
        s_last = gpio_get_level((gpio_num_t)pin);
    } else {
        ESP_LOGI(TAG, "sensor interrupt: GPIO %d released", pin);
    }
}

static void sensing_task(void *arg)
{
    (void)arg;
    uint32_t last_log = 0, last_arm = 0;
    TickType_t wake = xTaskGetTickCount();
    for (;;) {
        vTaskDelayUntil(&wake, pdMS_TO_TICKS(1000));
        const uint32_t t = now_s();
        siot_sensor_env_t e;
        siot_sensor_env_read(&e);
        const uint32_t acts = siot_sensing_rules_sample(&s_rules, t, SIOT_SENSE_TICK, e.ok, e.temp_c100, e.rh_c100);

        /* the frames first, so an event raised below carries this reading */
        if (e.ok) {
            s_temp_x10 = (int16_t)((e.temp_c100 + (e.temp_c100 >= 0 ? 5 : -5)) / 10);
            const int32_t rh = (e.rh_c100 + 50) / 100;
            s_humidity = (uint8_t)(rh < 0 ? 0 : rh > 100 ? 100 : rh);
        } else {
            s_temp_x10 = (int16_t)SAFR_NA_I16;
            s_humidity = SAFR_NA_U8;
        }
        s_fault_flags = (uint8_t)((siot_sensing_rules_fault(&s_rules) ? SAFR_FLT_TEMP_SENSOR : 0) |
                                  (siot_sensing_rules_wet(&s_rules) ? SAFR_FLT_SENSOR_WET : 0));
        if (acts) act(acts, &e);

        watch_int_pin();
#if CONFIG_SIOT_SENSING_DTR_TEST
        if (e.ok && t - last_arm >= REARM_EVERY_S) {
            last_arm = t;
            int32_t arm = e.temp_c100 + SIOT_SENSE_WAKE_MARGIN_C100;
            if (arm > SIOT_SENSE_HEAT_FIXED_C100) arm = SIOT_SENSE_HEAT_FIXED_C100;
            const uint8_t code = siot_sensing_th_code_floor(arm);
            const int32_t at = siot_sensing_th_code_c100(code);
            ESP_LOGW(TAG, "DTR test: threshold re-armed at code %u = %ld.%02ld C (reading %ld.%02ld C + 4.0): %s", code,
                     (long)(at / 100), (long)(at % 100), (long)(e.temp_c100 / 100), (long)(e.temp_c100 % 100),
                     esp_err_to_name(siot_sensor_heat_arm(code)));
        }
#else
        (void)last_arm;
#endif
        if (t - last_log >= LOG_EVERY_S) {
            last_log = t;
            if (e.ok) {
                ESP_LOGI(TAG, "%ld.%02ld C, %ld.%02ld %%RH%s%s", (long)(e.temp_c100 / 100), (long)(e.temp_c100 % 100),
                         (long)(e.rh_c100 / 100), (long)(e.rh_c100 % 100),
                         siot_sensing_rules_heat_alarm(&s_rules) ? " [HEAT ALARM]" : "",
                         siot_sensing_rules_wet(&s_rules) ? " [WET]" : "");
            } else {
                ESP_LOGW(TAG, "no reading%s", siot_sensing_rules_fault(&s_rules) ? " [SENSOR FAULT]" : "");
            }
        }
    }
}

esp_err_t siot_sensing_init(void)
{
    const esp_err_t err = siot_sensor_init();
    if (err != ESP_OK) return err;
    if (!siot_sensor_env_present()) return ESP_ERR_NOT_SUPPORTED;
    siot_sensing_rules_init(&s_rules, false, now_s());
    siot_netcore_set_env_hook(env_hook, NULL);
    ESP_LOGI(TAG, "heat and humidity rules on (%s): 57.0 C fixed, 8.0 C in 60 s, 99.7 %%RH", siot_sensor_backend());
    return xTaskCreate(sensing_task, "sensing", 4096, NULL, 4, NULL) == pdPASS ? ESP_OK : ESP_ERR_NO_MEM;
}
