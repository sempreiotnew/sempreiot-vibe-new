#include "siot_hal_serial.h"

#include "freertos/FreeRTOS.h"
#include "sdkconfig.h"

#include "siot_board_def.h"

/* RX holds one whole OTA chunk (4 KB of raw bytes + its frame, protocol
 * §13.3) so a busy moment in the reader never costs a byte at 921600. */
#define SERIAL_RX_BUF_SIZE 8192
#define SERIAL_TX_BUF_SIZE 4096

static uint32_t s_baud = SIOT_HAL_SERIAL_BAUD;

uint32_t siot_hal_serial_baud(void) { return s_baud; }

#if CONFIG_SIOT_SERIAL_LINK_UART0
#include "driver/uart.h"

#define SERIAL_UART UART_NUM_0

esp_err_t siot_hal_serial_init(void)
{
    const uart_config_t cfg = {
        .baud_rate = SIOT_HAL_SERIAL_BAUD,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    esp_err_t err = uart_driver_install(SERIAL_UART, SERIAL_RX_BUF_SIZE, SERIAL_TX_BUF_SIZE, 0, NULL, 0);
    if (err != ESP_OK) return err;
    err = uart_param_config(SERIAL_UART, &cfg);
    if (err != ESP_OK) return err;
    /* Explicit pins from the pin map rather than UART_PIN_NO_CHANGE, so the
     * route does not depend on what the ROM left configured. */
    const siot_board_def_t *bd = siot_board_def();
    return uart_set_pin(SERIAL_UART, bd->uart0_tx, bd->uart0_rx, UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE);
}

esp_err_t siot_hal_serial_write(const uint8_t *buf, size_t len)
{
    return uart_write_bytes(SERIAL_UART, buf, len) == (int)len ? ESP_OK : ESP_FAIL;
}

size_t siot_hal_serial_read(uint8_t *buf, size_t buf_len, uint32_t timeout_ms)
{
    /* What is there now, else wait for the first byte: never sit on a full
     * timeout while a frame is already in the buffer. */
    size_t avail = 0;
    uart_get_buffered_data_len(SERIAL_UART, &avail);
    if (avail > buf_len) avail = buf_len;
    const int n = avail ? uart_read_bytes(SERIAL_UART, buf, (uint32_t)avail, 0)
                        : uart_read_bytes(SERIAL_UART, buf, 1, pdMS_TO_TICKS(timeout_ms));
    return n > 0 ? (size_t)n : 0;
}

esp_err_t siot_hal_serial_set_baud(uint32_t baud)
{
    if (baud == s_baud) return ESP_OK;
    esp_err_t err = uart_wait_tx_done(SERIAL_UART, pdMS_TO_TICKS(500)); /* the ACK leaves at the old speed */
    if (err != ESP_OK) return err;
    err = uart_set_baudrate(SERIAL_UART, baud);
    if (err == ESP_OK) s_baud = baud;
    return err;
}

#else /* CONFIG_SIOT_SERIAL_LINK_USB_SERIAL_JTAG */
#include "driver/usb_serial_jtag.h"

esp_err_t siot_hal_serial_init(void)
{
    usb_serial_jtag_driver_config_t cfg = {
        .rx_buffer_size = SERIAL_RX_BUF_SIZE,
        .tx_buffer_size = SERIAL_TX_BUF_SIZE,
    };
    return usb_serial_jtag_driver_install(&cfg);
}

esp_err_t siot_hal_serial_write(const uint8_t *buf, size_t len)
{
    return usb_serial_jtag_write_bytes(buf, len, portMAX_DELAY) == (int)len ? ESP_OK : ESP_FAIL;
}

size_t siot_hal_serial_read(uint8_t *buf, size_t buf_len, uint32_t timeout_ms)
{
    const int n = usb_serial_jtag_read_bytes(buf, (uint32_t)buf_len, pdMS_TO_TICKS(timeout_ms));
    return n > 0 ? (size_t)n : 0;
}

esp_err_t siot_hal_serial_set_baud(uint32_t baud)
{
    s_baud = baud; /* USB CDC: no line speed; remembered so the caller sees what it asked */
    return ESP_OK;
}
#endif
