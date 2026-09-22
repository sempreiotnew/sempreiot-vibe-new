/* siot_evbus on the linux target: subscribe, post, receive typed data. The
 * esp_event default loop runs in its own task; we poll for delivery. */
#include <string.h>

#include "unity.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "siot_evbus.h"

static volatile int s_any_count, s_state_count;
static siot_evt_state_t s_last_state;
static void *s_last_ctx;

static void on_any(siot_evt_id_t id, const void *data, void *ctx)
{
    (void)data; (void)ctx;
    if (id >= 0 && id < SIOT_EVT_MAX) s_any_count++;
}

static void on_state(siot_evt_id_t id, const void *data, void *ctx)
{
    TEST_ASSERT_EQUAL(SIOT_EVT_STATE_CHANGED, id);
    s_last_state = *(const siot_evt_state_t *)data;
    s_last_ctx = ctx;
    s_state_count++;
}

static void wait_until(volatile int *counter, int value)
{
    for (int i = 0; i < 200 && *counter < value; i++) vTaskDelay(pdMS_TO_TICKS(5));
    TEST_ASSERT_EQUAL(value, *counter);
}

TEST_CASE("evbus: init, subscribe by id and ANY, post typed data, unsubscribe", "[evbus]")
{
    TEST_ASSERT_EQUAL(ESP_OK, siot_evbus_init());
    TEST_ASSERT_EQUAL(ESP_OK, siot_evbus_init()); /* idempotent */

    int ctx = 42;
    siot_evbus_sub_t sub_any, sub_state;
    s_any_count = s_state_count = 0;
    TEST_ASSERT_EQUAL(ESP_OK, siot_evbus_subscribe(SIOT_EVT_ANY, on_any, NULL, &sub_any));
    TEST_ASSERT_EQUAL(ESP_OK, siot_evbus_subscribe(SIOT_EVT_STATE_CHANGED, on_state, &ctx, &sub_state));

    const siot_evt_state_t st = {.prev = SIOT_STATE_JOINING, .next = SIOT_STATE_ONLINE};
    TEST_ASSERT_EQUAL(ESP_OK, siot_evbus_post(SIOT_EVT_STATE_CHANGED, &st, sizeof(st)));
    TEST_ASSERT_EQUAL(ESP_OK, siot_evbus_post(SIOT_EVT_BUTTON_TAP, NULL, 0));
    wait_until(&s_any_count, 2);
    wait_until(&s_state_count, 1);
    TEST_ASSERT_EQUAL(SIOT_STATE_JOINING, s_last_state.prev);
    TEST_ASSERT_EQUAL(SIOT_STATE_ONLINE, s_last_state.next);
    TEST_ASSERT_EQUAL_PTR(&ctx, s_last_ctx);

    TEST_ASSERT_EQUAL(ESP_OK, siot_evbus_unsubscribe(sub_state));
    TEST_ASSERT_EQUAL(ESP_OK, siot_evbus_post(SIOT_EVT_STATE_CHANGED, &st, sizeof(st)));
    wait_until(&s_any_count, 3);
    TEST_ASSERT_EQUAL(1, s_state_count);
    TEST_ASSERT_EQUAL(ESP_OK, siot_evbus_unsubscribe(sub_any));

    TEST_ASSERT_EQUAL(ESP_ERR_INVALID_ARG, siot_evbus_post(SIOT_EVT_MAX, NULL, 0));
    TEST_ASSERT_EQUAL(ESP_ERR_INVALID_ARG, siot_evbus_subscribe(SIOT_EVT_MAX, on_any, NULL, NULL));
    TEST_ASSERT_EQUAL_STRING("STATE_CHANGED", siot_evt_name(SIOT_EVT_STATE_CHANGED));
    TEST_ASSERT_EQUAL_STRING("?", siot_evt_name(SIOT_EVT_MAX));
}
