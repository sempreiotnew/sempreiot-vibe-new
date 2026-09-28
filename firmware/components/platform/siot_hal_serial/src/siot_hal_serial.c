#include "siot_hal_serial.h"

#include "freertos/FreeRTOS.h"
#include "sdkconfig.h"

#include "siot_board_def.h"

#define SERIAL_RX_BUF_SIZE 2048
#define SERIAL_TX_BUF_SIZE 4096

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
    const int n = uart_read_bytes(SERIAL_UART, buf, (uint32_t)buf_len, pdMS_TO_TICKS(timeout_ms));
    return n > 0 ? (size_t)n : 0;
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
#endif
