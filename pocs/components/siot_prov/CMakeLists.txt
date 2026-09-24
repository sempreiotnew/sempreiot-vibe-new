idf_component_register(SRCS "prov_store.c"
                             "prov_crypto.c"
                             "prov_http.c"
                             "wifi_softap.c"
                       INCLUDE_DIRS "include"
                       REQUIRES nvs_flash esp_wifi esp_netif esp_event
                                esp_http_server mbedtls json esp_hw_support
                                freertos)
