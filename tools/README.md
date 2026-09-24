# tools/ — shared by pocs/ and firmware/

## Words used by these tools

| Word | Meaning |
|---|---|
| `<app>` | Which firmware image: `board` (the control unit, `firmware/apps/board`) or `node` (every AC device, `firmware/apps/node`). |
| `<port>` | The USB serial port of the unit on this Mac, e.g. `/dev/cu.usbserial-AO2Q33TK`. `ls /dev/cu.*` lists them. |
| unit | One physical ESP32-S3 device, board or node. |
| identity | The pair `id` + `pop` a unit is born with. `id` is its name (e.g. `dev-b`), `pop` is its secret. Both are printed on the sticker QR and stored in the unit's `nvs_factory` partition. |
| `<sticker-id>` / `<id>` | The `id` above; also the folder name `tools/stickers/<id>/` that holds that unit's files. When `flash.sh` gets no id it uses the chip's eFuse MAC as the id (12 hex, e.g. `5A4652000001`). |
| sticker | The folder `tools/stickers/<id>/`: `sticker.bin` (the identity as a flashable image), `sticker.json`/`.png` (the QR the installer app scans: `{id, mac, pop}`), `sticker.csv` (the source). |
| `nvs_factory` | The small read-only flash partition where the firmware reads the identity from. `idf.py flash` never writes it; `flash.sh` (or one `esptool write_flash`) does. |
| `nvs` | The ordinary settings partition: the installation code, name, zone, counters. Erased by a factory reset (button held 5 s) or `--erase`. |
| code / installation | The bundle the installer app pushes during provisioning (`system_id`, Wi-Fi SSID/PSK, SAFR key, channel, mesh id). Stored in `nvs`. |
| provisioning / setup mode | A unit with no code raises the Wi-Fi network `SIOT-SETUP-<id>` (password = `pop`, LED white blink) and waits for the app. |
| `--flash 4mb\|8mb` | Board only: size of the flash chip. Bench devkits are 4 MB; the product board is 8 MB (default). |
| `--bench` | Board only: text console on UART0 so logs and panics are visible. Never on a unit wired to the tablet. |
| `--erase` | Wipe the whole flash before writing: the unit forgets its code and comes back in setup mode. The identity is written again from the sticker, so it survives. |
| variant / build dir | Each flag combination builds in its own folder (`build`, `build-4mb`, `build-4mb-bench`, `build-8mb-bench`) so switching is just a flag. |
| MAC | The chip's Wi-Fi address (e.g. `5A:46:52:00:00:01`). Read from hardware, printed on the sticker, never flashed. |
| POC | The round-1 prototype firmware in `pocs/`. It kept the identity in `nvs`; Phase 1 moved it to `nvs_factory`, which is why old units need `recover_sticker.py` once. |

| Tool | What it does |
|---|---|
| `make_sticker.py` | One unit's factory identity: `{id, pop}` → `stickers/<id>/sticker.csv` + `sticker.bin` (image of the `nvs_factory` partition, 0x8000) + `sticker.json` / `sticker.png` (the QR: `{id, mac, pop}`). |
| `recover_sticker.py` | `recover_sticker.py <port>` — reads the `{id, pop}` a unit already holds (POC `nvs` or Phase 1 `nvs_factory`) and its MAC, then regenerates `stickers/<id>/` with the same identity. For the round-1 units whose ids were never written down. |
| `flash.sh` | `flash.sh <board\|node> <port> [<sticker-id>] [--flash 4mb\|8mb] [--bench] [--erase]` — the one command per unit: reads the chip's MAC, creates `stickers/<MAC>/` on first use (random `pop`, QR) or reuses it, then writes bootloader + partition table + otadata + app + `nvs_factory` from the variant directory `firmware/build.sh` made with the same flags. Give a `<sticker-id>` only to flash an identity made by hand (`make_sticker.py`) or recovered from a POC unit (`recover_sticker.py`). |
| `pinmap/pinmap.yaml`, `pinmap/gen_board_def.py` | The pin map; generates `siot_board_def` at configure time. Edit the YAML, never the C. |
| `failover_timer.py`, `capture-safr.sh` | Bench measurement helpers (POC round 1). |

Bench flow — build once, then one command per unit:

```bash
source ~/.espressif/tools/activate_idf_v5.5.2.sh
firmware/build.sh node                                          # or: board --flash 4mb --bench
tools/flash.sh node  /dev/cu.usbserial-XXXX --erase             # id = chip MAC; sticker created/reused
tools/flash.sh board /dev/cu.usbserial-YYYY --flash 4mb --bench --erase
```

The unit boots into setup mode (white blink, network `SIOT-SETUP-<MAC>`); the QR for the installer
app is `tools/stickers/<MAC>/sticker.json` / `.png`. To keep a POC unit's old id instead:
`python3 tools/recover_sticker.py <port>` once, then `tools/flash.sh node <port> <old-id> --erase`.

`--mac` is read off the unit (`esptool.py read_mac`); it is only printed on the sticker, never
written to flash. The POC projects under `pocs/` used a 0x6000 `nvs` partition for the same
namespace: pass `--nvs-size 0x6000` when flashing a POC build.
