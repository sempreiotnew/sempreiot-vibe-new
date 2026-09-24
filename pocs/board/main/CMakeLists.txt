# "driver" pulls in the legacy usb_serial_jtag/uart driver headers on most
# IDF 5.x releases; on a newer IDF where usb_serial_jtag was split into its
# own component, add "esp_driver_usb_serial_jtag" here too.
idf_component_register(SRCS "board_main.c"
                             "board_button.c"
                             "serial_link.c"
                             "tcp_link.c"
                             "root_duties.c"
                             "installation_msg.c"
                       INCLUDE_DIRS "."
                       REQUIRES safr siot_prov siot_led nvs_flash esp_wifi
                                esp_netif esp_event lwip esp_timer driver
                                esp_hw_support)
