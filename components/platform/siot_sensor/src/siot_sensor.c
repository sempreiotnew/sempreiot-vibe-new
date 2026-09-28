#include "siot_sensor.h"

#include "sdkconfig.h"

#if CONFIG_SIOT_SENSOR_MOCK

esp_err_t siot_sensor_init(void) { return ESP_OK; }

void siot_sensor_read(siot_sensor_reading_t *out)
{
    out->smoke_raw = 120;                              /* clean air, arbitrary scale */
    out->temp_x10  = (int16_t)CONFIG_SIOT_SENSOR_MOCK_TEMP_X10;
    out->humidity  = 45;
    out->valid     = true;
}

uint8_t siot_sensor_battery_pct(void) { return (uint8_t)CONFIG_SIOT_SENSOR_MOCK_BATTERY_PCT; }

const char *siot_sensor_backend(void) { return "mock"; }

#else
#error "siot_sensor: only the mock backend exists (CONFIG_SIOT_SENSOR_MOCK); the ADPD188BI/HDC2080 backend is the sensing phase"
#endif
