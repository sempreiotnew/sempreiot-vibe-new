# siot_provisioning — setup network (SoftAP + HTTP contract) + envelope crypto.
# Layer 2 (net). Ported from pocs/components/siot_prov.
# On the linux host target only the crypto is built (test/host checks it
# against the app's vectors); the SoftAP/HTTP side needs the Wi-Fi stack.
idf_build_get_property(target IDF_TARGET)
if(${target} STREQUAL "linux")
    idf_component_register(SRCS "src/prov_crypto.c"
                           INCLUDE_DIRS "include"
                           PRIV_REQUIRES mbedtls)
else()
    idf_component_register(SRCS "src/prov_crypto.c" "src/prov_softap.c" "src/prov_http.c"
                                "src/siot_provisioning.c"
                           INCLUDE_DIRS "include"
                           REQUIRES siot_config
                           PRIV_REQUIRES mbedtls json esp_wifi esp_netif esp_event esp_http_server
                                         esp_hw_support esp_timer
                                         siot_identity siot_version siot_evbus siot_util)
endif()
