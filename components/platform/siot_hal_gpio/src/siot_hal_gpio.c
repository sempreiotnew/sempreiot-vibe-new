#include "siot_hal_gpio.h"

#include "driver/gpio.h"
#include "esp_attr.h"

typedef struct {
    int pin;
    siot_hal_gpio_edge_cb_t cb;
    void *ctx;
} edge_sub_t;

#define EDGE_SUBS_MAX 4
static edge_sub_t s_subs[EDGE_SUBS_MAX];
static bool s_isr_service_installed;

esp_err_t siot_hal_gpio_input_init(int pin, bool pull_up)
{
    if (pin < 0) return ESP_ERR_INVALID_ARG;
    const gpio_config_t cfg = {
        .pin_bit_mask = 1ULL << pin,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = pull_up ? GPIO_PULLUP_ENABLE : GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    return gpio_config(&cfg);
}

int siot_hal_gpio_read(int pin)
{
    if (pin < 0) return -1;
    return gpio_get_level((gpio_num_t)pin);
}

static void IRAM_ATTR edge_isr(void *arg)
{
    const edge_sub_t *sub = arg;
    sub->cb(sub->pin, sub->ctx);
}

esp_err_t siot_hal_gpio_edge_subscribe(int pin, siot_hal_gpio_edge_cb_t cb, void *ctx)
{
    if (pin < 0 || cb == NULL) return ESP_ERR_INVALID_ARG;
    edge_sub_t *slot = NULL;
    for (int i = 0; i < EDGE_SUBS_MAX; i++) {
        if (s_subs[i].cb == NULL) { slot = &s_subs[i]; break; }
    }
    if (slot == NULL) return ESP_ERR_NO_MEM;

    if (!s_isr_service_installed) {
        const esp_err_t err = gpio_install_isr_service(0);
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err;
        s_isr_service_installed = true;
    }
    slot->pin = pin;
    slot->cb = cb;
    slot->ctx = ctx;
    esp_err_t err = gpio_set_intr_type((gpio_num_t)pin, GPIO_INTR_ANYEDGE);
    if (err == ESP_OK) err = gpio_isr_handler_add((gpio_num_t)pin, edge_isr, slot);
    if (err != ESP_OK) slot->cb = NULL;
    return err;
}
