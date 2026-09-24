#include "siot_ui_led.h"

#include <stddef.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"

#include "siot_board_def.h"
#include "siot_evbus.h"
#include "siot_hal_pwm.h"
#include "siot_safr.h"

static const char *TAG = "siot_ui_led";

/* ---- Pattern engine (non-blocking, 50 ms esp_timer tick) — from siot_led.c
 * WHITE_BLINK / BLUE_BLINK run at 1 Hz (500 ms on / 500 ms off);
 * GREEN_BLINK / RED_BLINK are a 250 ms flash every 5 s. */
#define LED_TICK_MS            50
#define BLINK_HALF_TICKS       10   /* 500 ms on / 500 ms off */
#define SLOW_PERIOD_TICKS     100   /* 5 s */
#define SLOW_ON_TICKS           5   /* 250 ms flash */
#define BREATHE_PERIOD_TICKS   60   /* 3 s up and down */
#define BREATHE_MAX_DUTY       64   /* ≤ 25 %: visible, not glaring, negligible current */

typedef struct { siot_led_pattern_t pattern; uint32_t ticks; } pulse_t;

/* Everything below is shared between the esp_timer task (tick) and the
 * esp_event task (bus handlers); guarded by s_mux. */
static portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;
static siot_led_pattern_t s_pattern = SIOT_LED_OFF;
static siot_led_pattern_t s_base = SIOT_LED_OFF;
static uint32_t s_ticks_remaining;   /* 0 = steady (base) pattern */
static uint32_t s_blink_phase;
static bool     s_identify;          /* the running transient is IDENTIFY */
static pulse_t  s_queue[SIOT_LED_PULSE_QUEUE];
static size_t   s_q_head, s_q_len;

static bool     s_is_board;
static uint8_t  s_state = SIOT_STATE_SETUP;
static uint8_t  s_level;
static bool     s_alarm;

static void led_set_rgb(bool r, bool g, bool b, uint8_t duty)
{
    siot_hal_pwm_set(0, r ? duty : 0);
    siot_hal_pwm_set(1, g ? duty : 0);
    siot_hal_pwm_set(2, b ? duty : 0);
}

/* Triangle wave 0 → BREATHE_MAX_DUTY → 0 over BREATHE_PERIOD_TICKS. */
static uint8_t breathe_duty(uint32_t phase)
{
    const uint32_t t = phase % BREATHE_PERIOD_TICKS;
    const uint32_t half = BREATHE_PERIOD_TICKS / 2;
    const uint32_t up = t < half ? t : BREATHE_PERIOD_TICKS - t;
    return (uint8_t)(up * BREATHE_MAX_DUTY / half);
}

static void pattern_to_rgb(siot_led_pattern_t p, uint32_t phase, bool *r, bool *g, bool *b, uint8_t *duty)
{
    const bool on = ((phase / BLINK_HALF_TICKS) & 1) == 0;
    const bool slow_on = (phase % SLOW_PERIOD_TICKS) < SLOW_ON_TICKS;
    *r = *g = *b = false;
    *duty = SIOT_HAL_PWM_DUTY_MAX;
    switch (p) {
    case SIOT_LED_WHITE_BLINK:     *r = on; *g = on; *b = on; break;
    case SIOT_LED_WHITE_SOLID:     *r = true; *g = true; *b = true; break;
    case SIOT_LED_GREEN_BLINK:     *g = slow_on; break;
    case SIOT_LED_GREEN_SOLID:     *g = true; break;
    case SIOT_LED_MAGENTA_SOLID:   *r = true; *b = true; break;
    case SIOT_LED_MAGENTA_BLINK:   *r = slow_on; *b = slow_on; break;
    case SIOT_LED_RED_SOLID:       *r = true; break;
    case SIOT_LED_RED_BLINK:       *r = slow_on; break;
    case SIOT_LED_BLUE_BLINK:      *b = on; break;
    case SIOT_LED_BLUE_SOLID:      *b = true; break;
    case SIOT_LED_CYAN_SOLID:      *g = true; *b = true; break;
    case SIOT_LED_YELLOW_SOLID:    *r = true; *g = true; break;
    case SIOT_LED_WHITE_BREATHE:   *r = *g = *b = true; *duty = breathe_duty(phase); break;
    case SIOT_LED_OFF:
    default: break;
    }
}

static uint32_t ms_to_ticks(uint32_t ms)
{
    return (ms + LED_TICK_MS - 1) / LED_TICK_MS;
}

/* s_mux held. Starts a transient now. */
static void start_transient(siot_led_pattern_t p, uint32_t ticks)
{
    s_pattern = p;
    s_ticks_remaining = ticks;
    s_blink_phase = 0; /* a blinking transient starts in its "on" half */
}

/* s_mux held. Pops the next queued pulse or falls back to the base. */
static void transient_done(void)
{
    s_identify = false;
    if (s_q_len > 0) {
        const pulse_t next = s_queue[s_q_head];
        s_q_head = (s_q_head + 1) % SIOT_LED_PULSE_QUEUE;
        s_q_len--;
        start_transient(next.pattern, next.ticks);
        return;
    }
    s_pattern = s_base;
    s_ticks_remaining = 0;
    /* Resume the base pattern in its "off" part so a pulse is not
     * immediately followed by a green/white flash. */
    s_blink_phase = BLINK_HALF_TICKS;
}

static void led_tick(void *arg)
{
    (void)arg;
    static uint8_t last = 0xFF;

    portENTER_CRITICAL(&s_mux);
    if (s_ticks_remaining > 0 && --s_ticks_remaining == 0) transient_done();
    const siot_led_pattern_t p = s_pattern;
    const uint32_t phase = s_blink_phase++;
    portEXIT_CRITICAL(&s_mux);

    bool r, g, b;
    uint8_t duty;
    pattern_to_rgb(p, phase, &r, &g, &b, &duty);
    const uint8_t rgb = (uint8_t)((r << 2) | (g << 1) | b);
    static uint8_t last_duty = 0xFF;
    if (rgb != last || duty != last_duty) {
        last = rgb;
        last_duty = duty;
        led_set_rgb(r, g, b, duty);
    }
}

void siot_ui_led_set(siot_led_pattern_t pattern, uint32_t duration_ms)
{
    portENTER_CRITICAL(&s_mux);
    if (duration_ms == 0) {
        s_base = pattern;
        if (s_ticks_remaining == 0) { /* nothing transient: show it now */
            s_pattern = pattern;
            s_blink_phase = 0;
        }
    } else {
        s_q_len = 0; /* an explicit transient wins over queued pulses */
        s_identify = false;
        start_transient(pattern, ms_to_ticks(duration_ms));
    }
    portEXIT_CRITICAL(&s_mux);
}

siot_led_pattern_t siot_ui_led_get_base(void)
{
    return s_base;
}

void siot_ui_led_pulse(siot_led_pattern_t pattern, uint32_t duration_ms, bool fold)
{
    const uint32_t ticks = ms_to_ticks(duration_ms);
    portENTER_CRITICAL(&s_mux);
    if (s_identify) {
        portEXIT_CRITICAL(&s_mux);
        return; /* IDENTIFY owns the LED */
    }
    if (s_ticks_remaining == 0) {
        start_transient(pattern, ticks);
    } else if (fold && s_q_len == 0 && s_pattern == pattern && s_ticks_remaining <= ticks) {
        /* same short pulse still lit: merge */
    } else if (fold && s_q_len > 0 &&
               s_queue[(s_q_head + s_q_len - 1) % SIOT_LED_PULSE_QUEUE].pattern == pattern &&
               s_queue[(s_q_head + s_q_len - 1) % SIOT_LED_PULSE_QUEUE].ticks == ticks) {
        /* identical pulse already last in line: merge */
    } else if (s_q_len < SIOT_LED_PULSE_QUEUE) {
        s_queue[(s_q_head + s_q_len) % SIOT_LED_PULSE_QUEUE] = (pulse_t){pattern, ticks};
        s_q_len++;
    } /* else: queue full, dropped */
    portEXIT_CRITICAL(&s_mux);
}

void siot_ui_led_comm_blink(void)
{
    siot_ui_led_pulse(SIOT_LED_BLUE_SOLID, SIOT_LED_TICK_MS, true);
}

/* ---- traffic → pulse (system reference §3.7) --------------------------- */

static bool is_message(uint8_t msg_type)
{
    switch (msg_type) {
    case SAFR_MSG_EVENT:
    case SAFR_MSG_ACK:
    case SAFR_MSG_COMMAND:
    case SAFR_MSG_TIME_SYNC:
        return true;
    default: /* HEARTBEAT, TOPOLOGY, NAME_ANNOUNCE, EVENT_LOG_*, INSTALLATION */
        return false;
    }
}

/* One pulse per frame this unit puts on a link. */
static void on_tx(uint8_t msg_type)
{
    if (is_message(msg_type)) siot_ui_led_pulse(SIOT_LED_BLUE_SOLID, SIOT_LED_MSG_MS, false);
    else siot_ui_led_comm_blink();
}

/* ---- state → base pattern (brief §9 table) --------------------------- */

static siot_led_pattern_t pattern_for_state(void)
{
    if (s_alarm) return SIOT_LED_RED_SOLID;
    switch (s_state) {
    case SIOT_STATE_UNPROVISIONED_FACTORY: return SIOT_LED_RED_BLINK;
    case SIOT_STATE_SETUP:                 return SIOT_LED_WHITE_BLINK; /* the ONLY white blink */
    case SIOT_STATE_JOINING:
    case SIOT_STATE_OFFLINE:               return SIOT_LED_WHITE_BREATHE; /* configured, finding the network */
    case SIOT_STATE_ONLINE:
    case SIOT_STATE_DEGRADED:
        if (s_is_board) return SIOT_LED_MAGENTA_BLINK;
        return s_level == 1 ? SIOT_LED_GREEN_BLINK : SIOT_LED_OFF;
    case SIOT_STATE_FACTORY_RESET:
    default:                               return SIOT_LED_OFF;
    }
}

/* Lifecycle §6: link quality → colour. */
static siot_led_pattern_t rssi_pattern(int8_t rssi)
{
    if (rssi >= SIOT_LED_SURVEY_GOOD_DBM) return SIOT_LED_GREEN_SOLID;
    if (rssi >= SIOT_LED_SURVEY_WEAK_DBM) return SIOT_LED_YELLOW_SOLID;
    return SIOT_LED_RED_SOLID;
}

static void apply_state(void)
{
    const siot_led_pattern_t p = pattern_for_state();
    if (p != s_base) siot_ui_led_set(p, 0);
}

static void on_event(siot_evt_id_t id, const void *data, void *ctx)
{
    (void)ctx;
    switch (id) {
    case SIOT_EVT_STATE_CHANGED:
        s_state = ((const siot_evt_state_t *)data)->next;
        apply_state();
        break;
    case SIOT_EVT_MESH_LEVEL:
        s_level = ((const siot_evt_level_t *)data)->level;
        apply_state();
        break;
    case SIOT_EVT_ALARM_SET:
        s_alarm = true;
        apply_state();
        break;
    case SIOT_EVT_ALARM_CLEARED:
        s_alarm = false;
        apply_state();
        break;
    case SIOT_EVT_IDENTIFY: {
        uint32_t s = ((const siot_evt_identify_t *)data)->seconds;
        if (s == 0) s = SIOT_LED_IDENTIFY_DEFAULT_S;
        siot_ui_led_set(SIOT_LED_BLUE_BLINK, s * 1000);
        portENTER_CRITICAL(&s_mux);
        s_identify = true;
        portEXIT_CRITICAL(&s_mux);
        break;
    }
    case SIOT_EVT_SAFR_TX:
        on_tx(((const siot_evt_frame_t *)data)->msg_type);
        break;
    case SIOT_EVT_ACK_RECEIVED: /* the tablet confirmed a frame this unit sent */
        siot_ui_led_pulse(SIOT_LED_CYAN_SOLID, SIOT_LED_MSG_MS, false);
        break;
    case SIOT_EVT_SURVEY_HEARD: /* passive unit: colour of the probe it heard */
        siot_ui_led_set(rssi_pattern(((const siot_evt_rssi_t *)data)->rssi), SIOT_LED_SURVEY_HEARD_MS);
        break;
    case SIOT_EVT_SURVEY_ANSWER: /* emitter: one pulse per answering unit */
        siot_ui_led_pulse(rssi_pattern(((const siot_evt_rssi_t *)data)->rssi), SIOT_LED_SURVEY_ANSWER_MS, false);
        siot_ui_led_pulse(SIOT_LED_OFF, SIOT_LED_SURVEY_ANSWER_MS / 2, false); /* gap between blinks */
        break;
    case SIOT_EVT_SURVEY_RESULT: { /* end of the window: nobody answered = one red pulse */
        const siot_evt_survey_t *r = data;
        if (r->count == 0) siot_ui_led_pulse(SIOT_LED_RED_SOLID, SIOT_LED_SURVEY_ANSWER_MS, false);
        break;
    }
    default:
        break;
    }
}

esp_err_t siot_ui_led_init(bool is_board)
{
    s_is_board = is_board;
    const siot_board_def_t *bd = siot_board_def();
    const int pins[3] = {bd->led_r, bd->led_g, bd->led_b};
    esp_err_t err = siot_hal_pwm_init(pins, 3, bd->led_active_low);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "pwm init: %s", esp_err_to_name(err));
        return err;
    }
    led_set_rgb(false, false, false, 0);

    const esp_timer_create_args_t args = {
        .callback = led_tick,
        .name     = "siot_led_tick",
    };
    esp_timer_handle_t t;
    err = esp_timer_create(&args, &t);
    if (err == ESP_OK) err = esp_timer_start_periodic(t, LED_TICK_MS * 1000);
    if (err != ESP_OK) return err;

    return siot_evbus_subscribe(SIOT_EVT_ANY, on_event, NULL, NULL);
}
