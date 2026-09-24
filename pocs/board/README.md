# board — round 1 board firmware

Implements the board's normal-mode behaviour (POC-BRIEF.md §4.2): raises the
installation network, bridges SAFR frames between the tablet (serial) and
the mesh root (TCP), and performs the board's root duties (ACK, forward,
RAM-ring journal, HEARTBEAT/TOPOLOGY compatibility shim, the v3.1
GET_INSTALLATION/INSTALLATION/NAME_ANNOUNCE additions). Setup mode (raising
`SIOT-SETUP-<id>` and the HTTP provisioning contract) is `pocs/components/siot_prov`,
reused unchanged — this project only wires it up in `board_main.c`.

## Scope

**In:** normal-mode SoftAP (`net_ssid`/`net_psk`/`channel`), TCP listener
`192.168.4.1:5340`, tablet-facing SAFR serial link, root duties (ACK
LINK_CHECK/TIME_SYNC/COMMAND, forward both directions, RAM journal +
EVENT_LOG_REQ/DATA, HEARTBEAT/TOPOLOGY shim with LAYER=0), `GET_INSTALLATION`
(0x10) → `INSTALLATION` (0x09).

**Out (POC-BRIEF §2):** ESP-NOW/battery detectors, flash journal (RAM ring
only), OTA, cloud/MQTT, viewer app, `SET_CHANNEL`, siren cause-and-effect,
certification hardware, `SET_INSTALLATION` (0x11, Case B).

## Hardware assumption

Same as `pocs/autoconnect`/`pocs/patinha`: esp32s3, tablet link over native
USB-Serial-JTAG. POC-BRIEF.md §0 is still unfilled — if the real board uses
UART0 + an external bridge chip instead, only `main/serial_link.c` needs to
change (swap `usb_serial_jtag_*` calls for `uart_*` calls); everything else
talks to the tablet only through `serial_link.h`'s three functions.

Not compiled — no ESP-IDF toolchain is available in the environment this was
written in (same situation `pocs/autoconnect`'s README documents). Written
and reviewed by hand against `mocked-device/main/{mocked-device.c,mesh_sim.c}`
and `docs/safr/protocol-safr-v3.md`; build it as the first step before flashing.

## `/enroll` → board RAM (resolved after this project was first written)

`POST /enroll` (`prov_http.c`'s `handle_enroll`) now parses the
`[{mac, id, name, zone}]` array and persists MAC+NAME+ZONE via two new
`siot_prov` functions, `siot_store_save_enrolled`/`siot_store_load_enrolled`
(NVS "siot_inst", keys `enrolled_n`/`enrolled`) — additive to `prov_store.h`,
no existing signature changed. It's saved immediately on `/enroll` rather
than held in RAM, so it survives regardless of whether `/enroll` or
`/provision` (and its reboot) happens first. `board_main.c`'s normal-mode
boot now calls `siot_store_load_enrolled()` right after `root_duties_init()`
(which zeroes `board_state_t`) to populate `s_board.enrolled[]`, so
`INSTALLATION`'s ENROLLED_COUNT reflects the real list.

## Design choice not explicit in POC-BRIEF.md §4.2

For LINK_CHECK/TIME_SYNC/COMMAND downlink frames, the brief says both "ACK
... with SRC_MAC = board MAC" and "forward tablet downlink to TCP" — read
together as: the board ACKs *every* one of these locally (proving the
central↔board leg works) **and** forwards the same raw frame into the mesh
unchanged, so the addressed AC device also receives and acts on it (e.g. a
node sets its RTC from TIME_SYNC, or reacts to SILENCE/TEST/RESET/IDENTIFY).
The two new v3.1 exceptions are `GET_INSTALLATION` (answered locally with
`INSTALLATION`, never forwarded — it's addressed to the board itself, not
the mesh) and `EVENT_LOG_REQ` (answered locally from the board's own RAM
journal, since the board journals every uplink EVENT it forwards; no
separate ACK — the `EVENT_LOG_DATA` reply is the confirmation, spec §7.8).

## Factory-reset button (added after this project was first written)

The board unit was initially missing the "button held >= 5 s at any time ->
erase and re-enter setup mode" rule (blueprint §2-§3 / POC-BRIEF §4.1, which
lives under the *shared* `siot_prov` section, so it applies to the board too,
not just AC nodes). `board_button.c`/`.h` port the same GPIO21
debounce/long-press pattern `pocs/node/main/node_button.c` uses, minus the
short/double-press logic (the board has no MANUAL_TEST/alarm concept of its
own). Wired via `board_button_start()` in both the setup-mode and normal-mode
branches of `app_main`, same as `node.c` does.

## `siot_led`

Wired for the two moments `board_main.c` itself controls: `SIOT_LED_WHITE_BLINK`
before entering setup mode, and a 3 s `SIOT_LED_GREEN_SOLID` boot flash right
after normal mode loads a stored installation ("installed", blueprint LED
spec). Nothing inside `siot_prov` itself was touched (out of scope for this
project) — its own internal setup-mode states aren't independently
LED-driven beyond that initial white blink.
