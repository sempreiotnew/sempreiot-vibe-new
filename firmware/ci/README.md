# ci/

`check.sh` is the gate for every commit (run it before pushing; CI runs the same script):

1. `idf.py build` for `apps/board` and `apps/node` (esp32s3, ESP-IDF v5.5.2 only);
2. fails if `sempreiot-node.bin` exceeds 1.75 MB (OTA blueprint §1.1);
3. builds `test/host` for the linux target and runs the Unity tests (non-zero exit on any failure).

```bash
firmware/ci/check.sh                      # uses ~/.espressif/tools/activate_idf_v5.5.2.sh
IDF_ACTIVATE=/opt/idf/activate.sh firmware/ci/check.sh
```

Nightly: `test/hil` on the bench rig (Phase 1 step 5). Toolchain pinned to ESP-IDF v5.5.2.
