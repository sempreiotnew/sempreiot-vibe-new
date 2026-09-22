# ci/

`build.yml`: for every commit — `idf.py build` for `apps/board` and `apps/node` (esp32s3), fail if the
node image exceeds 1.75 MB (OTA blueprint §1.1), build and run `test/host`. Nightly: `test/hil` on the
bench rig. Toolchain pinned to ESP-IDF v5.5.2.
