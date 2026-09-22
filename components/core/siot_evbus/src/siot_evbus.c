#include "siot_evbus.h"

#include <stdlib.h>

#include "freertos/FreeRTOS.h"

ESP_EVENT_DEFINE_BASE(SIOT_EVENT);

struct siot_evbus_sub {
    siot_evbus_handler_t handler;
    void *ctx;
    int32_t id;
    esp_event_handler_instance_t instance;
};

static const char *const EVT_NAMES[SIOT_EVT_MAX] = {
    [SIOT_EVT_BOOT_DONE]         = "BOOT_DONE",
    [SIOT_EVT_STATE_CHANGED]     = "STATE_CHANGED",
    [SIOT_EVT_BUTTON_TAP]        = "BUTTON_TAP",
    [SIOT_EVT_BUTTON_DOUBLE_TAP] = "BUTTON_DOUBLE_TAP",
    [SIOT_EVT_BUTTON_HOLD]       = "BUTTON_HOLD",
    [SIOT_EVT_LINK_UP]           = "LINK_UP",
    [SIOT_EVT_LINK_DOWN]         = "LINK_DOWN",
    [SIOT_EVT_MESH_LEVEL]        = "MESH_LEVEL",
    [SIOT_EVT_PROVISIONED]       = "PROVISIONED",
    [SIOT_EVT_FACTORY_RESET]     = "FACTORY_RESET",
    [SIOT_EVT_IDENTIFY]          = "IDENTIFY",
    [SIOT_EVT_ALARM_SET]         = "ALARM_SET",
    [SIOT_EVT_ALARM_CLEARED]     = "ALARM_CLEARED",
    [SIOT_EVT_SAFR_TX]           = "SAFR_TX",
    [SIOT_EVT_SAFR_RX]           = "SAFR_RX",
    [SIOT_EVT_ACK_RECEIVED]      = "ACK_RECEIVED",
    [SIOT_EVT_ACK_TIMEOUT]       = "ACK_TIMEOUT",
    [SIOT_EVT_TIME_SYNCED]       = "TIME_SYNCED",
};

/* esp_event -> typed handler. `handler_arg` is our subscription record. */
static void trampoline(void *handler_arg, esp_event_base_t base, int32_t id, void *event_data)
{
    (void)base;
    const struct siot_evbus_sub *sub = handler_arg;
    sub->handler((siot_evt_id_t)id, event_data, sub->ctx);
}

esp_err_t siot_evbus_init(void)
{
    const esp_err_t err = esp_event_loop_create_default();
    if (err == ESP_ERR_INVALID_STATE) return ESP_OK; /* already created */
    return err;
}

esp_err_t siot_evbus_post(siot_evt_id_t id, const void *data, size_t size)
{
    if (id < 0 || id >= SIOT_EVT_MAX) return ESP_ERR_INVALID_ARG;
    return esp_event_post(SIOT_EVENT, (int32_t)id, data, size,
                          pdMS_TO_TICKS(SIOT_EVBUS_POST_TIMEOUT_MS));
}

esp_err_t siot_evbus_subscribe(int32_t id, siot_evbus_handler_t handler, void *ctx,
                               siot_evbus_sub_t *out)
{
    if (handler == NULL) return ESP_ERR_INVALID_ARG;
    if (id != SIOT_EVT_ANY && (id < 0 || id >= SIOT_EVT_MAX)) return ESP_ERR_INVALID_ARG;

    struct siot_evbus_sub *sub = calloc(1, sizeof(*sub));
    if (sub == NULL) return ESP_ERR_NO_MEM;
    sub->handler = handler;
    sub->ctx = ctx;
    sub->id = id;

    const esp_err_t err = esp_event_handler_instance_register(SIOT_EVENT, id, trampoline, sub,
                                                              &sub->instance);
    if (err != ESP_OK) {
        free(sub);
        return err;
    }
    if (out != NULL) *out = sub;
    return ESP_OK;
}

esp_err_t siot_evbus_unsubscribe(siot_evbus_sub_t sub)
{
    if (sub == NULL) return ESP_ERR_INVALID_ARG;
    const esp_err_t err = esp_event_handler_instance_unregister(SIOT_EVENT, sub->id, sub->instance);
    free(sub);
    return err;
}

const char *siot_evt_name(siot_evt_id_t id)
{
    if (id < 0 || id >= SIOT_EVT_MAX || EVT_NAMES[id] == NULL) return "?";
    return EVT_NAMES[id];
}
