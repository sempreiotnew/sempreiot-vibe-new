# siot_safr — SAFR v3: codec + CCM + CRC (ported from pocs/components/safr),
# per-sender counters, replay check, dedupe, dispatcher, stats. Layer 0.
# mbedtls builds for the linux target; the mutex lives behind src/safr_port.h.
idf_component_register(SRCS "src/safr_frame.c" "src/safr_product.c" "src/siot_safr.c"
                       INCLUDE_DIRS "include"
                       PRIV_REQUIRES mbedtls)
