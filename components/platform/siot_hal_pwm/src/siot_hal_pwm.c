#include "siot_hal_pwm.h"

#include "driver/ledc.h"

#define PWM_MODE    LEDC_LOW_SPEED_MODE
#define PWM_TIMER   LEDC_TIMER_0
#define PWM_RES     LEDC_TIMER_8_BIT
#define PWM_FREQ_HZ 5000

static size_t s_count;
static bool   s_active_low;

esp_err_t siot_hal_pwm_init(const int *pins, size_t count, bool active_low)
{
    if (pins == NULL || count == 0 || count > SIOT_HAL_PWM_CHANNELS_MAX) return ESP_ERR_INVALID_ARG;

    const ledc_timer_config_t timer = {
        .speed_mode      = PWM_MODE,
        .timer_num       = PWM_TIMER,
        .duty_resolution = PWM_RES,
        .freq_hz         = PWM_FREQ_HZ,
        .clk_cfg         = LEDC_AUTO_CLK,
    };
    esp_err_t err = ledc_timer_config(&timer);
    if (err != ESP_OK) return err;

    for (size_t i = 0; i < count; i++) {
        if (pins[i] < 0) return ESP_ERR_INVALID_ARG;
        const ledc_channel_config_t ch = {
            .gpio_num   = pins[i],
            .speed_mode = PWM_MODE,
            .channel    = (ledc_channel_t)(LEDC_CHANNEL_0 + i),
            .timer_sel  = PWM_TIMER,
            .duty       = active_low ? SIOT_HAL_PWM_DUTY_MAX : 0,
            .hpoint     = 0,
        };
        err = ledc_channel_config(&ch);
        if (err != ESP_OK) return err;
    }
    s_count = count;
    s_active_low = active_low;
    return ESP_OK;
}

esp_err_t siot_hal_pwm_set(size_t idx, uint8_t duty)
{
    if (idx >= s_count) return ESP_ERR_INVALID_ARG;
    const uint32_t d = s_active_low ? (uint32_t)(SIOT_HAL_PWM_DUTY_MAX - duty) : duty;
    const ledc_channel_t ch = (ledc_channel_t)(LEDC_CHANNEL_0 + idx);
    esp_err_t err = ledc_set_duty(PWM_MODE, ch, d);
    if (err == ESP_OK) err = ledc_update_duty(PWM_MODE, ch);
    return err;
}
