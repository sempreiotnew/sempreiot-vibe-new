#include "siot_sensor.h"

#include "sdkconfig.h"

#include "esp_timer.h"

#include "sensor_backend.h"

#define NA_U16 0xFFFF
#define NA_I16 0x7FFF
#define NA_U8  0xFF

/* What both backends put in the frames: tenths of a degree and whole percent,
 * rounded to nearest. The rules never use these — they take the full reading. */
static void env_to_reading(const siot_sensor_env_t *e, siot_sensor_reading_t *out)
{
    out->smoke_raw = NA_U16;
    if (!e->ok) {
        out->temp_x10 = NA_I16;
        out->humidity = NA_U8;
        out->valid = false;
        return;
    }
    out->temp_x10 = (int16_t)((e->temp_c100 + (e->temp_c100 >= 0 ? 5 : -5)) / 10);
    int32_t rh = (e->rh_c100 + 50) / 100;
    if (rh < 0) rh = 0;
    if (rh > 100) rh = 100;
    out->humidity = (uint8_t)rh;
    out->valid = true;
}

#if CONFIG_SIOT_SENSOR_MOCK

esp_err_t siot_sensor_init(void) { return ESP_OK; }

bool siot_sensor_env_present(void) { return true; }

/* The scripted scenarios of Kconfig SIOT_SENSOR_MOCK_SCENARIO: a function of
 * the time since boot only, so a unit that restarts replays it. */
bool siot_sensor_env_read(siot_sensor_env_t *out)
{
    const int32_t base = (int32_t)CONFIG_SIOT_SENSOR_MOCK_TEMP_X10 * 10;
    const int64_t s = esp_timer_get_time() / 1000000 - CONFIG_SIOT_SENSOR_MOCK_SCENARIO_START_S;
    int32_t t = base, rh = 4500;
    if (s >= 0) {
        switch (CONFIG_SIOT_SENSOR_MOCK_SCENARIO) {
        case 1: { /* +0.1 °C/s (slower than the rate-of-rise rule) up to 60 °C, 30 s there, down */
            const int32_t top = 6000;
            const int64_t up_s = top > base ? (top - base) / 10 : 0;
            if (s < up_s) t = base + (int32_t)s * 10;
            else if (s < up_s + 30) t = top;
            else if (s < 2 * up_s + 30) t = top - (int32_t)(s - up_s - 30) * 10;
            break;
        }
        case 2: /* +10 °C in 40 s, 30 s there, down in 40 s */
            if (s < 40) t = base + (int32_t)s * 25;
            else if (s < 70) t = base + 1000;
            else if (s < 110) t = base + 1000 - (int32_t)(s - 70) * 25;
            break;
        case 3: /* saturated for 60 s */
            if (s < 60) rh = 10000;
            break;
        default:
            break;
        }
    }
    out->ok = true;
    out->temp_c100 = t;
    out->rh_c100 = rh;
    return true;
}

void siot_sensor_read(siot_sensor_reading_t *out)
{
    siot_sensor_env_t e;
    siot_sensor_env_read(&e);
    env_to_reading(&e, out);
    out->smoke_raw = 120; /* clean air, arbitrary scale */
}

esp_err_t siot_sensor_heat_arm(uint8_t th_code) { (void)th_code; return ESP_OK; }
uint8_t   siot_sensor_int_status(void) { return 0; }
int       siot_sensor_int_pin(void) { return -1; }

uint8_t siot_sensor_battery_pct(void) { return (uint8_t)CONFIG_SIOT_SENSOR_MOCK_BATTERY_PCT; }

const char *siot_sensor_backend(void) { return "mock"; }

#else /* the real sensors: HDC2080 today; smoke and battery ADC still to come */

esp_err_t siot_sensor_init(void)
{
    const esp_err_t err = hdc2080_init();
    return err == ESP_ERR_NOT_FOUND ? ESP_OK : err; /* a model without the sensor is not an error */
}

bool siot_sensor_env_present(void) { return hdc2080_present(); }

bool siot_sensor_env_read(siot_sensor_env_t *out) { return hdc2080_read(out); }

void siot_sensor_read(siot_sensor_reading_t *out)
{
    siot_sensor_env_t e = {.ok = false};
    if (hdc2080_present()) hdc2080_read(&e);
    env_to_reading(&e, out);
}

esp_err_t siot_sensor_heat_arm(uint8_t th_code) { return hdc2080_arm(th_code); }
uint8_t   siot_sensor_int_status(void) { return hdc2080_int_status(); }
int       siot_sensor_int_pin(void) { return hdc2080_int_pin(); }

uint8_t siot_sensor_battery_pct(void) { return NA_U8; } /* the battery ADC is not read yet */

const char *siot_sensor_backend(void) { return hdc2080_present() ? "hdc2080" : "none"; }

#endif
