/* Private: what a temperature / humidity backend gives siot_sensor.c. */
#pragma once

#include "siot_sensor.h"

esp_err_t hdc2080_init(void);          /* ESP_ERR_NOT_FOUND: this model has no sensor bus */
bool      hdc2080_present(void);
bool      hdc2080_read(siot_sensor_env_t *out);
esp_err_t hdc2080_arm(uint8_t th_code);
uint8_t   hdc2080_int_status(void);
int       hdc2080_int_pin(void);
