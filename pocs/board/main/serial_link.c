#include "serial_link.h"

#include "esp_check.h"
#include "sdkconfig.h"

#define SERIAL_RX_BUF_SIZE 2048
#define SERIAL_TX_BUF_SIZE 4096

#if CONFIG_SIOT_SERIAL_LINK_UART0
/* UART0 behind the devkit's USB-UART bridge chip, same path as
 * mocked-device/main/mocked-device.c. CONFIG_ESP_CONSOLE_NONE keeps the
 * app's logs off this port; only the ROM's boot banner precedes the SAFR
 * stream, and the tablet's reframer resyncs on SOF. Pins stay at the ROM
 * defaults (U0TXD_GPIO_NUM 43 / U0RXD_GPIO_NUM 44 on the S3), which is
 * what the bridge chip is wired to. */
#include "driver/uart.h"
#include "soc/uart_pins.h"   /* U0TXD_GPIO_NUM 43 / U0RXD_GPIO_NUM 44 on the S3 */

#define SERIAL_UART      UART_NUM_0
#define SERIAL_BAUD      115200

void serial_link_init(void)
{
    const uart_config_t cfg = {
        .baud_rate = SERIAL_BAUD,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    ESP_ERROR_CHECK(uart_driver_install(SERIAL_UART, SERIAL_RX_BUF_SIZE,
                                        SERIAL_TX_BUF_SIZE, 0, NULL, 0));
    ESP_ERROR_CHECK(uart_param_config(SERIAL_UART, &cfg));
    /* Explicit pins (docs/spec/definition-central.md "UART": 43 = U0_TXD,
     * 44 = U0_RXD) rather than UART_PIN_NO_CHANGE, so the route does not
     * depend on whatever the ROM left configured before app start. */
    ESP_ERROR_CHECK(uart_set_pin(SERIAL_UART, U0TXD_GPIO_NUM, U0RXD_GPIO_NUM,
                                 UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));
}

void serial_link_send(const uint8_t *frame, size_t len)
{
    uart_write_bytes(SERIAL_UART, frame, len);
}

size_t serial_link_recv(uint8_t *buf, size_t buf_len, TickType_t ticks_to_wait)
{
    const int n = uart_read_bytes(SERIAL_UART, buf, (uint32_t)buf_len, ticks_to_wait);
    return n > 0 ? (size_t)n : 0;
}

#else /* CONFIG_SIOT_SERIAL_LINK_USB_SERIAL_JTAG */
#include "driver/usb_serial_jtag.h"

void serial_link_init(void)
{
    usb_serial_jtag_driver_config_t cfg = {
        .rx_buffer_size = SERIAL_RX_BUF_SIZE,
        .tx_buffer_size = SERIAL_TX_BUF_SIZE,
    };
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&cfg));
}

void serial_link_send(const uint8_t *frame, size_t len)
{
    usb_serial_jtag_write_bytes(frame, len, portMAX_DELAY);
}

size_t serial_link_recv(uint8_t *buf, size_t buf_len, TickType_t ticks_to_wait)
{
    const int n = usb_serial_jtag_read_bytes(buf, buf_len, ticks_to_wait);
    return n > 0 ? (size_t)n : 0;
}
#endif
