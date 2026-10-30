# siot_link — link_iface + backends (brief §6.2): link_mesh_node (Mesh-Lite +
# root TCP client), link_mesh_board (installation AP + TCP server),
# link_serial (tablet). Layer 2 (net). Phase 2 adds link_espnow beside them.
# On the linux host only the frame reassembler is built (test/host).
idf_build_get_property(target IDF_TARGET)
if(${target} STREQUAL "linux")
    idf_component_register(SRCS "src/link_core.c"
                           INCLUDE_DIRS "include"
                           REQUIRES siot_safr)
else()
    set(srcs "src/link_core.c" "src/link_serial.c" "src/link_mesh_board.c")
    set(priv_reqs esp_wifi esp_netif esp_event lwip esp_timer esp_hw_support
                  siot_hal_serial siot_identity siot_util siot_evbus)
    if(CONFIG_MESH_LITE_ENABLE)
        # The node image only: the mesh_lite / iot_bridge managed components
        # exist in apps/node (idf_component.yml), not in apps/board.
        list(APPEND srcs "src/link_mesh_node.c" "src/link_mesh_scan_shim.c")
    endif()
    idf_component_register(SRCS ${srcs}
                           INCLUDE_DIRS "include"
                           REQUIRES siot_safr siot_config
                           PRIV_REQUIRES ${priv_reqs})
    if(CONFIG_MESH_LITE_ENABLE)
        # Mesh-Lite 1.0.2 fills a 32-byte wifi_scan_config_t; v5.5.2's is 44
        # bytes and the all-channel parent scan got a garbage channel bitmap
        # (empty scan, every node a root). link_mesh_scan_shim.c rebuilds the
        # struct. -u keeps the wrapper object in the link whatever the
        # archive order; the ELF check in the fix commit proves the call
        # lands on it.
        target_link_libraries(${COMPONENT_LIB} INTERFACE
                              "-Wl,--wrap=esp_wifi_scan_start"
                              "-Wl,-u,__wrap_esp_wifi_scan_start")
    endif()
    # Requirements are collected before sdkconfig exists, so a CONFIG_-gated
    # PRIV_REQUIRES is silently dropped; this links the managed components
    # whenever they are part of the build (node), and nothing on the board.
    idf_component_optional_requires(PRIVATE espressif__mesh_lite espressif__iot_bridge)
endif()
