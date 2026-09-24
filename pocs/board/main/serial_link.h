/*
 * Tablet-facing SAFR link (POC-BRIEF.md §4.2): "USB-Serial-JTAG driver on S3,
 * or UART0 via bridge chip" per §0 (still unfilled — this assumes native
 * USB-Serial-JTAG on esp32s3, matching pocs/autoconnect/pocs/patinha).
 *
 * All serial I/O is behind this tiny API on purpose: if the real board turns
 * out to need the UART0+bridge path instead, only serial_link.c changes
 * (swap usb_serial_jtag_* calls for uart_* calls, same shape as
 * mocked-device/main/mocked-device.c's UART0 setup) — nothing else in this
 * project touches the peripheral directly.
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "freertos/FreeRTOS.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Installs the driver. CONFIG_ESP_CONSOLE_NONE=y (sdkconfig.defaults) keeps
 * the ESP-IDF console off this peripheral — call this once at boot, after
 * that nothing may printf/ESP_LOG here. */
void serial_link_init(void);

void serial_link_send(const uint8_t *frame, size_t len);

/* Blocking read of whatever is available within `ticks_to_wait`; returns the
 * number of bytes read (0 on timeout). */
size_t serial_link_recv(uint8_t *buf, size_t buf_len, TickType_t ticks_to_wait);

#ifdef __cplusplus
}
#endif
