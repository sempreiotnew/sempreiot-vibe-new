# siot_hal_serial — the board's tablet-facing serial peripheral (UART0 or
# native USB-Serial-JTAG, Kconfig choice). Layer 1. From pocs/board/main/serial_link.c.
idf_component_register(SRCS "src/siot_hal_serial.c"
                       INCLUDE_DIRS "include"
                       PRIV_REQUIRES esp_driver_uart esp_driver_usb_serial_jtag siot_board_def)
