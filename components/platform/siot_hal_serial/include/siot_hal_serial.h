/* siot_hal_serial — raw byte stream to the tablet (brief §6.5): 115200 8N1 on
 * UART0, or native USB-Serial-JTAG, chosen by CONFIG_SIOT_SERIAL_LINK_*.
 * Uses the UART driver, never stdout/VFS (the LF→CRLF SAFR v1 bug).
 * Ported from pocs/board/main/serial_link.c; pins from siot_board_def. */
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SIOT_HAL_SERIAL_BAUD 115200

esp_err_t siot_hal_serial_init(void);

/* Writes all `len` bytes (blocking). */
esp_err_t siot_hal_serial_write(const uint8_t *buf, size_t len);

/* Reads what is available within `timeout_ms`; returns bytes read (0 on timeout). */
size_t siot_hal_serial_read(uint8_t *buf, size_t buf_len, uint32_t timeout_ms);

#ifdef __cplusplus
}
#endif
