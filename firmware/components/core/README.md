# core/ — layer 0

Pure C. No `driver/*.h`, no `nvs.h`, no `esp_wifi.h`; only `mbedtls`, FreeRTOS primitives (via a thin
port shim so the linux target links) and `esp_log`. Everything here is covered by `test/host`.

Phase 1 components: `siot_safr` (SAFR v3 codec, CCM, CRC, counters, replay, dedupe, dispatcher —
ported from `pocs/components/safr`, `LEN ≤ 250`), `siot_evbus` (event bus), `siot_version` (reads
`../../VERSION` at build time), `siot_util` (byte helpers, mac/hex, ring buffer).
