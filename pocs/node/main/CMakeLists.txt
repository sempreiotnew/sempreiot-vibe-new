idf_component_register(SRCS "node.c"
                            "node_button.c"
                            "node_mesh.c"
                            "node_safr.c"
                       INCLUDE_DIRS "."
                       REQUIRES nvs_flash esp_timer driver esp_wifi esp_hw_support
                                lwip esp_event esp_netif safr siot_prov siot_led mesh_lite iot_bridge)
