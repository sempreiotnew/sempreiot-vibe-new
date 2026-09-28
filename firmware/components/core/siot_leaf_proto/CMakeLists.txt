# siot_leaf_proto — the leaf link's pure-C pieces (protocol §12): the 9-byte
# leaf ACK codec, parent selection, the outbox ring and the probe/miss policy.
# No IDF drivers: builds on the linux target and is covered by test/host.
idf_component_register(SRCS "src/siot_leaf_proto.c"
                       INCLUDE_DIRS "include"
                       REQUIRES siot_safr siot_util)
