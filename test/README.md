# test/

- `host/` — one ESP-IDF project for the **linux** target (`idf.py --preview set-target linux`), Unity
  test runner. Covers `components/core` end to end: SAFR build/parse round-trip, Appendix A vectors
  V1–V3 byte-exact, CRC check value 0x29B1, replay window, dedupe, dispatcher; provisioning crypto
  against the shared `vectors.json`; config defaults; netcore state machine with a fake link.
  Runs in CI on every commit.
- `hil/` — hardware-in-the-loop: `phase1.py` drives 3–4 boards over UART plus the tablet's serial log
  and asserts the Phase 1 exit checklist (brief §12). Built on `tools/failover_timer.py`. Runs nightly
  on the bench rig; becomes the base of the factory test later.
