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
                  siot_hal_serial siot_identity siot_util)
    if(CONFIG_MESH_LITE_ENABLE)
        # The node image only: the mesh_lite / iot_bridge managed components
        # exist in apps/node (idf_component.yml), not in apps/board.
        list(APPEND srcs "src/link_mesh_node.c")
    endif()
    idf_component_register(SRCS ${srcs}
                           INCLUDE_DIRS "include"
                           REQUIRES siot_safr siot_config
                           PRIV_REQUIRES ${priv_reqs})
    # Requirements are collected before sdkconfig exists, so a CONFIG_-gated
    # PRIV_REQUIRES is silently dropped; this links the managed components
    # whenever they are part of the build (node), and nothing on the board.
    idf_component_optional_requires(PRIVATE espressif__mesh_lite espressif__iot_bridge)
endif()
