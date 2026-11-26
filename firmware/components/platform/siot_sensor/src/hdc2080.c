/* HDC2080 temperature / humidity sensor (TI SNAS678C, docs/datasheets/hdc2080.pdf).
 *
 * How it is run (docs/phases-development/phase5-heat-humidity-sensing-brief.md §5.1):
 *   - auto measurement, 1 sample per second, 14 bit both: the sensor converts by
 *     itself, also while a battery unit sleeps; a read only fetches the result;
 *   - interrupt: TEMPERATURE-HIGH ONLY (see siot_sensor.h for why), latched until
 *     register 0x04 is read, ACTIVE LOW — the ESP32-S3 has one ext1 wake level
 *     for all its pins (no SOC_PM_SUPPORT_EXT1_WAKEUP_MODE_PER_PIN) and the
 *     button already wakes on low;
 *   - every register is volatile: the configuration is read back on a schedule
 *     and a sensor that lost it fails that reading (→ SENSOR_FAULT upstream)
 *     and is configured again.
 *
 * The level shifter (PCA9306, pin i2c_en) is opened around EVERY exchange and
 * closed after, on every unit: the final product needs it, the 3.3 V
 * development unit has nothing on that pin (brief §9).
 */
#include "sensor_backend.h"

#include "sdkconfig.h"

#if !CONFIG_SIOT_SENSOR_MOCK

#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "esp_log.h"
#include "esp_rom_sys.h"

#include "siot_board_def.h"

static const char *TAG = "hdc2080";

#define REG_DATA        0x00 /* T low, T high, RH low, RH high — LSB first, one read */
#define REG_INT_STATUS  0x04
#define REG_INT_ENABLE  0x07
#define REG_TH          0x0B /* temperature threshold high, 8 bit */
#define REG_CONFIG      0x0E
#define REG_MEAS        0x0F
#define REG_ID          0xFC /* manufacturer low, high, device low, high */

#define INT_ENABLE_TH_ONLY 0x40 /* TH_ENABLE; DRDY, TL, HH, HL off */
/* AMM = 101 (1 Hz), heater off, DRDY/INT_EN = 1, INT_POL = 0 (active low), INT_MODE = 0 (latched) */
#define CONFIG_VALUE       0x54
#define CONFIG_SOFT_RESET  0x80
#define MEAS_14BIT_BOTH    0x00 /* 14 bit T, 14 bit RH, humidity + temperature */
#define MEAS_TRIGGER       0x01 /* starts the conversions (and the auto mode) */

#define TH_CODE_57C        151  /* 56.83 °C: the last step at or below 57.0 °C */
#define I2C_HZ             100000
#define XFER_TIMEOUT_MS    50
#define SHIFTER_SETTLE_US  1000
#define POWER_UP_US        3000 /* datasheet §8.5.2: ready at most 3 ms after power-up / reset */
#define READBACK_EVERY     30   /* readings between two configuration read-backs */

static const uint8_t ADDRS[] = {0x40, 0x41}; /* ADDR to GND or open / ADDR to VDD */

static i2c_master_bus_handle_t s_bus;
static i2c_master_dev_handle_t s_dev;
static int     s_en_pin = SIOT_PIN_NONE;
static int     s_int_pin = SIOT_PIN_NONE;
static bool    s_present;      /* the model has a sensor bus */
static bool    s_found;        /* an HDC2080 answered with its identity */
static uint8_t s_th_code = TH_CODE_57C;
static uint8_t s_since_readback;

static void bus_open(void)
{
    if (s_en_pin == SIOT_PIN_NONE) return;
    gpio_set_level((gpio_num_t)s_en_pin, 1);
    esp_rom_delay_us(SHIFTER_SETTLE_US);
}

static void bus_close(void)
{
    if (s_en_pin != SIOT_PIN_NONE) gpio_set_level((gpio_num_t)s_en_pin, 0);
}

/* bus open */
static esp_err_t reg_write(uint8_t reg, uint8_t value)
{
    const uint8_t buf[2] = {reg, value};
    return i2c_master_transmit(s_dev, buf, sizeof(buf), XFER_TIMEOUT_MS);
}

/* bus open */
static esp_err_t reg_read(uint8_t reg, uint8_t *out, size_t len)
{
    return i2c_master_transmit_receive(s_dev, &reg, 1, out, len, XFER_TIMEOUT_MS);
}

/* bus open. The four registers this driver owns, as it wants them? */
static bool config_matches(void)
{
    uint8_t ie, th, cfg;
    if (reg_read(REG_INT_ENABLE, &ie, 1) != ESP_OK || reg_read(REG_TH, &th, 1) != ESP_OK ||
        reg_read(REG_CONFIG, &cfg, 1) != ESP_OK) {
        return false;
    }
    return ie == INT_ENABLE_TH_ONLY && th == s_th_code && (cfg & (uint8_t)~CONFIG_SOFT_RESET) == CONFIG_VALUE;
}

/* bus open */
static esp_err_t configure(void)
{
    esp_err_t err;
    if ((err = reg_write(REG_TH, s_th_code)) != ESP_OK) return err;
    if ((err = reg_write(REG_INT_ENABLE, INT_ENABLE_TH_ONLY)) != ESP_OK) return err;
    if ((err = reg_write(REG_CONFIG, CONFIG_VALUE)) != ESP_OK) return err;
    if ((err = reg_write(REG_MEAS, MEAS_14BIT_BOTH | MEAS_TRIGGER)) != ESP_OK) return err;
    uint8_t status;
    reg_read(REG_INT_STATUS, &status, 1); /* a stale latch from before: released */
    return ESP_OK;
}

/* bus open: an HDC2080 at `addr`? */
static bool identify(uint8_t addr)
{
    if (i2c_master_probe(s_bus, addr, XFER_TIMEOUT_MS) != ESP_OK) return false;
    const i2c_device_config_t dev = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = addr,
        .scl_speed_hz = I2C_HZ,
    };
    if (i2c_master_bus_add_device(s_bus, &dev, &s_dev) != ESP_OK) return false;
    uint8_t id[4];
    if (reg_read(REG_ID, id, sizeof(id)) == ESP_OK && id[0] == 0x49 && id[1] == 0x54 && id[2] == 0xD0 && id[3] == 0x07) {
        return true;
    }
    i2c_master_bus_rm_device(s_dev);
    s_dev = NULL;
    return false;
}

esp_err_t hdc2080_init(void)
{
    const siot_board_def_t *bd = siot_board_def();
    if (bd->i2c_sda == SIOT_PIN_NONE || bd->i2c_scl == SIOT_PIN_NONE) {
        ESP_LOGI(TAG, "model %s has no sensor bus: no temperature / humidity", bd->model);
        return ESP_ERR_NOT_FOUND;
    }
    s_present = true;
    s_en_pin = bd->i2c_en;
    s_int_pin = bd->sensor_int;

    if (s_en_pin != SIOT_PIN_NONE) {
        const gpio_config_t en = {.pin_bit_mask = 1ULL << s_en_pin, .mode = GPIO_MODE_OUTPUT};
        gpio_config(&en);
        gpio_set_level((gpio_num_t)s_en_pin, 0);
    }
    if (s_int_pin != SIOT_PIN_NONE) {
        /* Active low, push-pull at the sensor; the pull-up keeps the line idle
         * while the sensor's pin is still floating (before it is configured). */
        const gpio_config_t in = {.pin_bit_mask = 1ULL << s_int_pin, .mode = GPIO_MODE_INPUT,
                                  .pull_up_en = GPIO_PULLUP_ENABLE};
        gpio_config(&in);
    }

    const i2c_master_bus_config_t bus = {
        .i2c_port = -1,
        .sda_io_num = (gpio_num_t)bd->i2c_sda,
        .scl_io_num = (gpio_num_t)bd->i2c_scl,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true, /* the PCB has its own; these only help a bare breakout */
    };
    esp_err_t err = i2c_new_master_bus(&bus, &s_bus);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "I2C bus on SDA %d / SCL %d: %s", bd->i2c_sda, bd->i2c_scl, esp_err_to_name(err));
        return err;
    }

    bus_open();
    esp_rom_delay_us(POWER_UP_US);
    uint8_t addr = 0;
    for (size_t i = 0; i < sizeof(ADDRS) && !s_found; i++) {
        if (identify(ADDRS[i])) { s_found = true; addr = ADDRS[i]; }
    }
    if (!s_found) {
        bus_close();
        ESP_LOGE(TAG, "no HDC2080 at 0x40 or 0x41 (SDA %d, SCL %d, enable %d): SENSOR_FAULT", bd->i2c_sda,
                 bd->i2c_scl, s_en_pin);
        return ESP_OK; /* present but not answering: every read fails, the rules raise the fault */
    }
    /* A battery unit waking from deep sleep finds the sensor as it left it,
     * still measuring: leave it alone (a reconfiguration would also drop a
     * latched interrupt before anyone read it). Anything else: configure. */
    if (config_matches()) {
        ESP_LOGI(TAG, "HDC2080 at 0x%02X: configuration kept (1 Hz, TH only, threshold code %u)", addr, s_th_code);
    } else {
        err = configure();
        ESP_LOGI(TAG, "HDC2080 at 0x%02X: configured 1 Hz, 14 bit, interrupt = temperature-high only, active low,"
                      " threshold code %u, supply %d mV: %s", addr, s_th_code, CONFIG_SIOT_SENSOR_SUPPLY_MV,
                 esp_err_to_name(err));
    }
    bus_close();
    return ESP_OK;
}

bool hdc2080_present(void) { return s_present; }

int hdc2080_int_pin(void) { return s_found ? s_int_pin : SIOT_PIN_NONE; }

bool hdc2080_read(siot_sensor_env_t *out)
{
    out->ok = false;
    out->temp_c100 = 0;
    out->rh_c100 = 0;
    if (!s_found) return false;

    bus_open();
    if (++s_since_readback >= READBACK_EVERY) {
        s_since_readback = 0;
        if (!config_matches()) {
            const esp_err_t err = configure();
            bus_close();
            ESP_LOGE(TAG, "the sensor lost its configuration (power dip?): configured again (%s); this reading fails",
                     esp_err_to_name(err));
            return false;
        }
    }
    uint8_t d[4];
    const esp_err_t err = reg_read(REG_DATA, d, sizeof(d));
    bus_close();
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "read failed: %s", esp_err_to_name(err));
        return false;
    }
    const uint32_t t_raw = (uint32_t)d[0] | ((uint32_t)d[1] << 8);
    const uint32_t rh_raw = (uint32_t)d[2] | ((uint32_t)d[3] << 8);
    /* Datasheet eq. 2: T = raw / 2^16 × 165 − (40.5 + 0.08 × (VDD − 1.8 V)); eq. 3: RH = raw / 2^16 × 100.
     * In centi-units, rounded to nearest. 0.08 °C/V = 8 centi-°C per 1000 mV. */
    const int32_t supply_corr = (8 * ((int32_t)CONFIG_SIOT_SENSOR_SUPPLY_MV - 1800) + 500) / 1000;
    out->temp_c100 = (int32_t)((t_raw * 16500u + 32768u) >> 16) - 4050 - supply_corr;
    out->rh_c100 = (int32_t)((rh_raw * 10000u + 32768u) >> 16);
    out->ok = true;
    return true;
}

esp_err_t hdc2080_arm(uint8_t th_code)
{
    if (!s_found) return ESP_ERR_INVALID_STATE;
    if (th_code == s_th_code) return ESP_OK;
    bus_open();
    const esp_err_t err = reg_write(REG_TH, th_code);
    bus_close();
    if (err == ESP_OK) s_th_code = th_code;
    return err;
}

uint8_t hdc2080_int_status(void)
{
    if (!s_found) return 0;
    uint8_t status = 0;
    bus_open();
    const esp_err_t err = reg_read(REG_INT_STATUS, &status, 1);
    bus_close();
    return err == ESP_OK ? status : 0;
}

#endif /* !CONFIG_SIOT_SENSOR_MOCK */
