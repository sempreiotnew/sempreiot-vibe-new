/* siot_sensing — a unit that measures: the heat and humidity rules of protocol
 * §7.1.6 run on the unit's own sensor (docs/phases-development/
 * phase5-heat-humidity-sensing-brief.md). The rules themselves, and every
 * number, are in siot_sensing_rules.h. */
#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Mains unit (node image), after siot_netcore_start(): starts the sensor and
 * the 1 s sampling task. ESP_ERR_NOT_SUPPORTED when this model has no
 * temperature / humidity sensor — nothing is then reported or judged. */
esp_err_t siot_sensing_init(void);

#ifdef __cplusplus
}
#endif
