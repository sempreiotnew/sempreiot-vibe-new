/* Digital input monitor: ACOK, BOOST, CHG, TAMPER, RST/TESTE.
 *
 * Prints ONE dashboard line on the serial console and redraws it in place
 * (carriage return, no newline) only when a debounced input changes.
 *
 * GPIO  Name       Pull  0 (LOW)                 1 (HIGH)
 *  5    ACOK       up    AC present              no AC
 *  6    BOOST      up    battery consuming       not consuming
 *  7    CHG        up    battery charging        not charging
 * 11    TAMPER     up    tamper OK               device removed
 * 21    RST/TESTE  up    pressed                 released
 *                        short press  -> TEST
 *                        hold >= 5 s  -> FACTORY RESET request (reported only)
 *
 * Wake-up is interrupt driven (any edge). After an edge the task samples
 * every DEBOUNCE_PERIOD_MS until every input has been stable for
 * DEBOUNCE_SAMPLES consecutive samples, then blocks again until the next
 * edge. While the button is held the task keeps sampling so it can time the
 * long press.
 */
#include <stdio.h>
#include <string.h>
#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "driver/ledc.h"
#include "esp_log.h"
#include "esp_timer.h"

static const char *TAG = "patinha";

/* ---- Pin map ------------------------------------------------------------ */
#define GPIO_ACOK       5
#define GPIO_BOOST      6
#define GPIO_CHG        7
#define GPIO_TAMPER     11
#define GPIO_BUTTON     21

/* ---- Debounce / timing -------------------------------------------------- */
#define DEBOUNCE_PERIOD_MS      10      /* sample interval while active     */
#define DEBOUNCE_SAMPLES        3       /* stable samples before accepting  */
#define LONG_PRESS_MS           5000    /* RST/TESTE hold for factory reset */
#define HOLD_REPORT_MS          1000    /* refresh hold time on the line    */

/* ---- RGB LED (PWM) ------------------------------------------------------ */
#define LED_R_GPIO      14
#define LED_G_GPIO      47
#define LED_B_GPIO      48
#define LED_ACTIVE_LOW  0               /* 1 if common-anode (driven low)   */
#define LED_MODE        LEDC_LOW_SPEED_MODE
#define LED_TIMER       LEDC_TIMER_0
#define LED_RES         LEDC_TIMER_8_BIT
#define LED_FREQ_HZ     5000
#define LED_ON_DUTY     255

typedef struct { ledc_channel_t ch; int gpio; } led_t;
static const led_t leds[] = {
    { LEDC_CHANNEL_0, LED_R_GPIO },
    { LEDC_CHANNEL_1, LED_G_GPIO },
    { LEDC_CHANNEL_2, LED_B_GPIO },
};
#define LED_COUNT (sizeof(leds) / sizeof(leds[0]))

static void led_set_rgb(bool r, bool g, bool b)
{
    const bool on[LED_COUNT] = { r, g, b };
    for (size_t i = 0; i < LED_COUNT; i++) {
        uint32_t duty = on[i] ? LED_ON_DUTY : 0;
        if (LED_ACTIVE_LOW) duty = LED_ON_DUTY - duty;
        ESP_ERROR_CHECK(ledc_set_duty(LED_MODE, leds[i].ch, duty));
        ESP_ERROR_CHECK(ledc_update_duty(LED_MODE, leds[i].ch));
    }
}

static void led_init(void)
{
    ledc_timer_config_t timer = {
        .speed_mode      = LED_MODE,
        .timer_num       = LED_TIMER,
        .duty_resolution = LED_RES,
        .freq_hz         = LED_FREQ_HZ,
        .clk_cfg         = LEDC_AUTO_CLK,
    };
    ESP_ERROR_CHECK(ledc_timer_config(&timer));
    for (size_t i = 0; i < LED_COUNT; i++) {
        ledc_channel_config_t ch = {
            .gpio_num   = leds[i].gpio,
            .speed_mode = LED_MODE,
            .channel    = leds[i].ch,
            .timer_sel  = LED_TIMER,
            .duty       = 0,
            .hpoint     = 0,
        };
        ESP_ERROR_CHECK(ledc_channel_config(&ch));
    }
    led_set_rgb(false, false, false);
}

/* ---- LED pattern engine (non-blocking, 50 ms esp_timer tick) ------------
 * Priority: reset armed (WHITE solid) > short press (BLUE single blink)
 *           > tamper OK / LOW (GREEN slow blink) > off.
 * The monitor task only writes the flags below; the timer renders them.  */
#define LED_TICK_MS         50
#define BLUE_HALF_TICKS     5       /* 250 ms on / 250 ms off              */
#define BLUE_BLINKS         1
#define BLUE_TOTAL_TICKS    (BLUE_BLINKS * 2 * BLUE_HALF_TICKS)
#define GREEN_HALF_TICKS    10      /* 500 ms on / 500 ms off              */

static volatile bool    led_reset_armed;    /* WHITE while long press held  */
static volatile bool    led_tamper_ok;      /* GREEN blink while TAMPER LOW */
static volatile uint8_t led_blue_ticks;     /* BLUE blink ticks remaining   */

static void led_tick(void *arg)
{
    static uint32_t green_phase;            /* restarts on each TAMPER LOW  */
    static bool     prev_tamper_ok;
    static uint8_t  last = 0xFF;
    uint8_t rgb;                            /* bit2=R bit1=G bit0=B         */
    bool    tamper_ok = led_tamper_ok;

    /* Phase restart on the HIGH->LOW edge so the first half is always ON:
     * a short tamper pulse is then visible instead of landing in an OFF half. */
    if (tamper_ok && !prev_tamper_ok) green_phase = 0;
    prev_tamper_ok = tamper_ok;

    if (led_reset_armed) {
        rgb = 0b111;
    } else if (led_blue_ticks) {
        led_blue_ticks--;
        rgb = ((led_blue_ticks / BLUE_HALF_TICKS) & 1) ? 0b001 : 0;
    } else if (tamper_ok) {
        rgb = ((green_phase / GREEN_HALF_TICKS) & 1) ? 0 : 0b010;
        green_phase++;
    } else {
        rgb = 0;
    }
    if (rgb != last) {
        last = rgb;
        led_set_rgb(rgb & 0b100, rgb & 0b010, rgb & 0b001);
    }
}

static void led_engine_start(void)
{
    const esp_timer_create_args_t args = {
        .callback = led_tick,
        .name     = "led_tick",
    };
    esp_timer_handle_t t;
    ESP_ERROR_CHECK(esp_timer_create(&args, &t));
    ESP_ERROR_CHECK(esp_timer_start_periodic(t, LED_TICK_MS * 1000));
}

/* ---- Input table -------------------------------------------------------- */
typedef struct {
    int         gpio;
    const char *name;
    const char *low_meaning;
    const char *high_meaning;
} input_def_t;

static const input_def_t inputs[] = {
    { GPIO_ACOK,   "ACOK",      "AC present",        "NO AC"           },
    { GPIO_BOOST,  "BOOST",     "battery consuming", "not consuming"   },
    { GPIO_CHG,    "CHG",       "charging",          "not charging"    },
    { GPIO_TAMPER, "TAMPER",    "tamper OK",         "TAMPER REMOVED"  },
    { GPIO_BUTTON, "RST/TESTE", "pressed",           "released"        },
};
#define INPUT_COUNT (sizeof(inputs) / sizeof(inputs[0]))
#define TAMPER_IDX  3
#define BUTTON_IDX  4

/* Per-input debounce state */
typedef struct {
    uint8_t stable;     /* accepted level                       */
    uint8_t candidate;  /* last raw level seen                  */
    uint8_t count;      /* consecutive samples == candidate     */
} input_state_t;

static input_state_t   state[INPUT_COUNT];
static TaskHandle_t    monitor_task_handle;

/* ---- ISR: any edge on any monitored pin wakes the monitor task ---------- */
static void IRAM_ATTR gpio_isr_handler(void *arg)
{
    BaseType_t hp_task_woken = pdFALSE;
    vTaskNotifyGiveFromISR(monitor_task_handle, &hp_task_woken);
    portYIELD_FROM_ISR(hp_task_woken);
}

/* ---- Dashboard ---------------------------------------------------------- */
/* Fixed-width fields so the overwritten line never leaves stale characters.
 * "\x1b[K" erases to end of line for the variable-length event field.       */
static void dashboard_draw(const char *event)
{
    int64_t now_ms = esp_timer_get_time() / 1000;

    printf("\r[%6" PRId64 ".%03" PRId64 "s]", now_ms / 1000, now_ms % 1000);
    for (size_t i = 0; i < INPUT_COUNT; i++) {
        printf(" | %s(%d)=%-4s", inputs[i].name, inputs[i].gpio,
               state[i].stable ? "HIGH" : "LOW");
    }
    printf(" | %s\x1b[K", event ? event : "");
    fflush(stdout);
}

static void legend_print(void)
{
    printf("\n--- GPIO input monitor (pull-ups enabled, debounce %d x %d ms) ---\n",
           DEBOUNCE_SAMPLES, DEBOUNCE_PERIOD_MS);
    for (size_t i = 0; i < INPUT_COUNT; i++) {
        printf("  %-9s GPIO%-2d  LOW=%-18s HIGH=%s\n", inputs[i].name,
               inputs[i].gpio, inputs[i].low_meaning, inputs[i].high_meaning);
    }
    printf("  RST/TESTE: short press = TEST, hold >= %d s = FACTORY RESET\n",
           LONG_PRESS_MS / 1000);
    printf("  LED: WHITE = long press armed | BLUE blink = short press | GREEN blink = TAMPER LOW\n"
           "  Line below is redrawn in place only when an input changes.\n\n");
}

/* ---- Monitor task ------------------------------------------------------- */
static void monitor_task(void *arg)
{
    char    event[64] = "ready";
    bool    button_down       = false;
    int64_t button_down_at_ms = 0;
    int64_t last_hold_report  = 0;
    bool    long_press_fired  = false;

    /* Seed debounce state with the current pin levels. */
    for (size_t i = 0; i < INPUT_COUNT; i++) {
        uint8_t lvl = (uint8_t)gpio_get_level(inputs[i].gpio);
        state[i].stable = state[i].candidate = lvl;
        state[i].count  = DEBOUNCE_SAMPLES;
    }
    led_tamper_ok = (state[TAMPER_IDX].stable == 0);
    button_down   = (state[BUTTON_IDX].stable == 0);
    if (button_down) button_down_at_ms = esp_timer_get_time() / 1000;

    legend_print();
    dashboard_draw(event);

    for (;;) {
        bool changed  = false;
        bool settling = false;

        for (size_t i = 0; i < INPUT_COUNT; i++) {
            uint8_t raw = (uint8_t)gpio_get_level(inputs[i].gpio);
            input_state_t *s = &state[i];

            if (raw != s->candidate) {
                s->candidate = raw;
                s->count = 1;
            } else if (s->count < DEBOUNCE_SAMPLES) {
                s->count++;
            }

            if (s->count >= DEBOUNCE_SAMPLES && s->stable != s->candidate) {
                s->stable = s->candidate;
                changed = true;
                snprintf(event, sizeof event, "%s -> %s (%s)", inputs[i].name,
                         s->stable ? "HIGH" : "LOW",
                         s->stable ? inputs[i].high_meaning : inputs[i].low_meaning);
            }
            if (s->count < DEBOUNCE_SAMPLES) settling = true;
        }

        /* TAMPER LOW (device on base) -> slow GREEN blink. */
        led_tamper_ok = (state[TAMPER_IDX].stable == 0);

        /* Button press/hold/release logic on the debounced level. */
        int64_t now_ms = esp_timer_get_time() / 1000;
        bool pressed = (state[BUTTON_IDX].stable == 0);

        if (pressed && !button_down) {                 /* press edge   */
            button_down       = true;
            button_down_at_ms = now_ms;
            last_hold_report  = now_ms;
            long_press_fired  = false;
        } else if (pressed && button_down) {           /* still held   */
            int64_t held = now_ms - button_down_at_ms;
            if (!long_press_fired && held >= LONG_PRESS_MS) {
                long_press_fired = true;
                led_reset_armed = true;                 /* WHITE = reset armed */
                snprintf(event, sizeof event,
                         "RST/TESTE LONG PRESS %d s -> FACTORY RESET request [LED WHITE]",
                         LONG_PRESS_MS / 1000);
                changed = true;
            } else if (!long_press_fired && now_ms - last_hold_report >= HOLD_REPORT_MS) {
                last_hold_report = now_ms;
                snprintf(event, sizeof event, "RST/TESTE holding %" PRId64 " s",
                         held / 1000);
                changed = true;
            }
        } else if (!pressed && button_down) {          /* release edge */
            button_down = false;
            if (long_press_fired) {
                led_reset_armed = false;                /* released: LED off */
                snprintf(event, sizeof event, "RST/TESTE released after long press [LED OFF]");
            } else {
                led_blue_ticks = BLUE_TOTAL_TICKS;      /* BLUE single blink */
                snprintf(event, sizeof event,
                         "RST/TESTE SHORT PRESS (%" PRId64 " ms) -> TEST [LED BLUE blink]",
                         now_ms - button_down_at_ms);
            }
            changed = true;
        }

        if (changed) dashboard_draw(event);

        /* Keep sampling while something is settling or the button is held;
         * otherwise sleep until the next GPIO edge (notification is latched,
         * so an edge between the last sample and this call is not lost). */
        TickType_t wait = (settling || button_down) ? pdMS_TO_TICKS(DEBOUNCE_PERIOD_MS)
                                                    : portMAX_DELAY;
        ulTaskNotifyTake(pdTRUE, wait);
    }
}

/* ---- Init --------------------------------------------------------------- */
static void inputs_configure(void)
{
    uint64_t mask = 0;
    for (size_t i = 0; i < INPUT_COUNT; i++) mask |= 1ULL << inputs[i].gpio;

    gpio_config_t cfg = {
        .pin_bit_mask = mask,
        .mode         = GPIO_MODE_INPUT,
        .pull_up_en   = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_ANYEDGE,
    };
    ESP_ERROR_CHECK(gpio_config(&cfg));
}

static void inputs_enable_interrupts(void)
{
    ESP_ERROR_CHECK(gpio_install_isr_service(0));
    for (size_t i = 0; i < INPUT_COUNT; i++) {
        ESP_ERROR_CHECK(gpio_isr_handler_add(inputs[i].gpio, gpio_isr_handler, NULL));
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "GPIO input monitor: ACOK=%d BOOST=%d CHG=%d TAMPER=%d RST/TESTE=%d",
             GPIO_ACOK, GPIO_BOOST, GPIO_CHG, GPIO_TAMPER, GPIO_BUTTON);

    /* Order matters:
     * 1. Configure pins (pull-ups active) so the task seeds real levels.
     * 2. Create the task so the ISR has a valid handle.
     * 3. Enable interrupts, then notify once so any edge that happened
     *    between seeding and ISR install is picked up by a resample.  */
    led_init();
    led_engine_start();
    inputs_configure();
    vTaskDelay(pdMS_TO_TICKS(DEBOUNCE_PERIOD_MS));   /* let pull-ups settle */
    xTaskCreate(monitor_task, "gpio_mon", 4096, NULL, 10, &monitor_task_handle);
    inputs_enable_interrupts();
    xTaskNotifyGive(monitor_task_handle);

    /* Keep IDF's "Returned from app_main()" log off the dashboard line. */
    esp_log_level_set("main_task", ESP_LOG_NONE);
}
