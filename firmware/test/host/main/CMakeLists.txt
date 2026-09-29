idf_component_register(SRCS "test_main.c"
                            "test_util.c"
                            "test_safr_codec.c"
                            "test_vectors.c"
                            "test_replay_dedupe.c"
                            "test_dispatch.c"
                            "test_evbus.c"
                            "test_prov_crypto.c"
                            "test_setup_channel.c"
                            "test_link_reasm.c"
                            "test_leaf_proto.c"
                            "test_ota_proto.c"
                            "test_support.c"
                       INCLUDE_DIRS "."
                       PRIV_REQUIRES unity mbedtls siot_safr siot_util siot_evbus siot_version siot_provisioning siot_link siot_leaf_proto siot_ota_proto
                       # TEST_CASE registers through a constructor in an otherwise
                       # unreferenced object: force every object of this archive in.
                       WHOLE_ARCHIVE)
