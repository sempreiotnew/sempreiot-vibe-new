# Signed & Secure Firmware — how-to (ESP32-S3, IDF v5.5.2)

Command reference for `docs/ota/ota-and-production-blueprint-v1.md` §6 ("Security stages"). Every
command and Kconfig symbol below was checked against the installed IDF v5.5.2 source
(`$IDF_PATH/components/bootloader/Kconfig.projbuild`, `$IDF_PATH/docs/en/security/*.rst`) and
live `--help` output, not recalled from memory — per this repo's CLAUDE.md rule that headers/docs
beat guesses. Target chip is **esp32s3** everywhere below, confirmed from `pocs/board/sdkconfig`
and `pocs/node/sdkconfig` (`CONFIG_IDF_TARGET="esp32s3"`).

**I have not run any of these commands or touched any project file.** This is a reference doc
only; `idf.py` isn't currently runnable in this sandbox (its Python venv is missing —
`$IDF_TOOLS_PATH/python/v5.5.2/venv` doesn't exist here), so nothing below has been executed
end-to-end. Try each step yourself and adjust if the installed toolchain behaves differently.

---

## 0. Note on `ota-and-production-blueprint-v1.md` §1.3/§6

That doc's security config block originally had some original-ESP32 (not S3) language and one
real bug — an unusable Kconfig line (`CONFIG_SECURE_SIGNED_ON_BOOT_NO_SECURE_BOOT`, which
depends on the ECDSA-V1 scheme that only exists on the original ESP32, not S3). Already fixed
directly in that file: `CONFIG_SECURE_SIGNED_APPS_RSA_SCHEME` (was misspelled), the invalid
`ON_BOOT_NO_SECURE_BOOT` line removed, `idf.py set-target esp32s3`, and the key-rotation note
corrected to S3's real 3 revocable key-digest slots. See §3 below for what Stage 1 actually
enforces on S3 as a result of that fix.

---

## 1. What each stage actually gets you on S3

| | Stage 1 — signed apps, no HW enforcement (now) | Stage 2 — Secure Boot V2 + Flash Encryption (production) |
|---|---|---|
| App images | RSA-3072 signed at build time | Same, RSA-3072 (S3 has no ECC secure-boot option — no chip choice to make here) |
| OTA updates | Signature checked in software (`esp_ota_ops`/`esp_image_format` APIs) before accepting an update | Same check, now backed by eFuse-verified bootloader |
| A directly UART-flashed (`idf.py flash`) image | **Not checked** — nothing on-chip enforces this yet | Bootloader refuses anything not signed by the burned-in key digest |
| Flash contents | Plaintext | Encrypted in place (app, bootloader, partition table, `otadata` always; other partitions only if flagged `encrypted`, see §6) |
| Reversible? | Yes, plain Kconfig options | **No.** eFuses burned on first boot after enabling; Release mode additionally disables UART reflashing permanently |

So Stage 1 is real (it stops a spoofed OTA payload from network attackers, per the Kconfig help
text at `Kconfig.projbuild:603-604`) but it does **not** stop someone with a USB cable from
flashing arbitrary firmware — only Stage 2 closes that.

---

## 2. Partition table (4 MB node — from blueprint §1.1, unchanged here)

```csv
# Name,        Type, SubType,  Offset,   Size,     Flags
nvs,           data, nvs,      0x9000,   0x6000,
otadata,       data, ota,      0xF000,   0x2000,
phy_init,      data, phy,      0x11000,  0x1000,
ota_0,         app,  ota_0,    0x20000,  0x1E0000,
ota_1,         app,  ota_1,    0x200000, 0x1E0000,
nvs_factory,   data, nvs,      0x3E0000, 0x8000,
coredump,      data, coredump, 0x3E8000, 0x10000,
# 0x3F8000–0x400000 spare (32 KB)
```

Save this as `partitions_node.csv` in the node project, and in `sdkconfig.defaults`:

```
CONFIG_PARTITION_TABLE_CUSTOM=y
CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="partitions_node.csv"
```

The board's 8 MB table (blueprint §1.2) follows the same pattern with bigger `ota_0`/`ota_1` and
the extra `fw_store` partition — everything in this doc applies to it unchanged except sizes.

`app`, `bootloader`, `partition_table`, and `otadata` are **always** encrypted once flash
encryption is on, regardless of any flag (`partition-tables.rst:230-241`). `nvs` and
`nvs_factory` are **not**, unless you add the flag yourself — see §6.

---

## 3. Stage 1 — signed apps, no hardware enforcement (do this now)

**Kconfig** (`idf.py menuconfig` → *Security features*, or put these lines directly in
`sdkconfig.defaults`):

```
CONFIG_SECURE_SIGNED_APPS_NO_SECURE_BOOT=y
CONFIG_SECURE_SIGNED_APPS_RSA_SCHEME=y
CONFIG_SECURE_SIGNED_ON_UPDATE_NO_SECURE_BOOT=y
CONFIG_SECURE_BOOT_BUILD_SIGNED_BINARIES=y
CONFIG_SECURE_BOOT_SIGNING_KEY="keys/sempreiot_signing_key.pem"
```

(No `CONFIG_SECURE_SIGNED_ON_BOOT_NO_SECURE_BOOT` — see §0.4.)

**Commands, in order:**

```bash
source ~/.espressif/tools/activate_idf_v5.5.2.sh
cd pocs/node          # or pocs/board

# 1. One-time: generate the company signing key (RSA-3072, the only scheme S3 supports)
mkdir -p keys
idf.py secure-generate-signing-key --version 2 --scheme rsa3072 keys/sempreiot_signing_key.pem
chmod 600 keys/sempreiot_signing_key.pem
echo "keys/" >> .gitignore   # never commit this file — losing it is recoverable here (dev key),
                              # but build the habit now for the production key later

# 2. Apply the Kconfig lines above (menuconfig, or edit sdkconfig.defaults + idf.py reconfigure)
idf.py reconfigure

# 3. Build — idf.py signs every app image automatically because
#    CONFIG_SECURE_BOOT_BUILD_SIGNED_BINARIES=y and a key path are both set
idf.py build

# 4. Confirm the output binary is actually signed
idf.py secure-verify-signature --version 2 --keyfile keys/sempreiot_signing_key.pem build/node.bin
# espsecure.py's --keyfile accepts the private key PEM directly for verification, no need to
# extract a separate public key file for this check.

# 5. Flash normally — Stage 1 doesn't change how you flash, only how updates are accepted later
idf.py -p <PORT> flash monitor
```

To later feed the public key to anything that only wants it (e.g. embedding in another build):

```bash
espsecure.py extract_public_key --version 2 --keyfile keys/sempreiot_signing_key.pem keys/sempreiot_signing_key.pub.pem
```

---

## 4. Stage 2 — Secure Boot V2 (RSA-3072) + Flash Encryption — production only

> **This is irreversible.** Read this whole section before running anything. Do dry runs on
> spare/bench boards first (the blueprint's own rule: "keep 5–10 stage-1 golden boards on the
> bench forever", §6). Do not do this on a board you need to keep re-flashing over USB.

### 4.1 What gets permanently burned, and when

- **Enabling `CONFIG_SECURE_BOOT`** burns the secure-boot key digest into eFuse on the *first
  boot* after flashing. From then on the bootloader will not boot an app/bootloader that isn't
  signed by that key (`secure-boot-v2.rst:434`). JTAG and the ROM BASIC interpreter are also
  disabled by default at this point (`Kconfig.projbuild:619`).
- **Flash Encryption, Development mode**: flash contents get encrypted on first boot too, but you
  can still `idf.py flash`/reflash over UART using the `encrypted-flash`/`encrypted-app-flash`
  targets (`flash-encryption.rst:278-333, 501-513`). This is the mode to test the whole pipeline
  in before committing further.
- **Flash Encryption, Release mode**: same first-boot encryption, **plus** the bootloader burns
  `DIS_DOWNLOAD_MANUAL_ENCRYPT`, which permanently disables the UART bootloader's ability to
  write or decrypt flash at all (`flash-encryption.rst:519-521,536,555`). After this, **the only
  way to update the device is OTA** (through your already-verified signed-update path) —
  `idf.py flash` will never work on that unit again.
- Also permanent, independent of the above: once Secure Boot is on, eFuse key blocks can no
  longer be read-protected retroactively (`secure-boot-v2.rst:518-519`), and revoking a key
  digest slot cannot be undone — revoking all 3 slots can permanently brick the device
  (`secure-boot-v2.rst:769`).
- Enabling either feature disables the ROM USB-OTG stack, which kills USB serial-emulation/DFU
  reflashing over that port (`secure-boot-v2.rst:515-516`) — relevant since the board is
  USB-tethered to the tablet; make sure your recovery path doesn't depend on that port.

### 4.2 Kconfig (add on top of Stage 1's)

```
CONFIG_SECURE_BOOT=y
CONFIG_SECURE_BOOT_V2_ENABLED=y          # only option on S3 — it has no ECC secure-boot scheme
CONFIG_SECURE_FLASH_ENC_ENABLED=y
CONFIG_SECURE_FLASH_ENCRYPTION_MODE_DEVELOPMENT=y   # flip to _RELEASE only after a full dev-mode
                                                      # dry run passes on a bench unit
```

S3 also lets you choose the XTS-AES key size (`Kconfig.projbuild`, `SOC_FLASH_ENCRYPTION_XTS_AES_128`
and `_256` are both `1` on this chip — unlike some smaller chips that only support one):

```
CONFIG_SECURE_FLASH_ENCRYPTION_KEYSIZE_256=y   # default AES-128 is fine too; 256 costs a bit more RAM/time
```

### 4.3 Commands, in order (Development mode first)

```bash
source ~/.espressif/tools/activate_idf_v5.5.2.sh
cd pocs/node

# 1. Apply the Kconfig above (menuconfig or sdkconfig.defaults + reconfigure)
idf.py reconfigure

# 2. Build the secure-boot-enabled bootloader + signed app
idf.py build

# 3. Flash the bootloader FIRST. idf.py won't auto-flash it once secure boot is configured —
#    it builds it and prints the exact esptool.py write_flash command to run yourself:
idf.py bootloader
#    ...copy the printed command and run it, e.g.:
#    esptool.py -p <PORT> write_flash 0x0 build/bootloader/bootloader.bin

# 4. Flash the partition table + signed app normally
idf.py -p <PORT> flash

# 5. Power-cycle the board (reset). On THIS boot the bootloader burns the secure-boot key
#    digest and (if configured) the flash-encryption key eFuses, then encrypts flash in place.
#    Can take up to ~a minute for large partitions. If power is lost mid-way, it safely resumes
#    the process on the next boot — it does not brick (secure-boot-v2.rst:509).

# 6. Confirm what actually got burned
idf.py -p <PORT> efuse-summary
#    look for: SECURE_BOOT_EN, FLASH_CRYPT_CNT, and (Release mode only) DIS_DOWNLOAD_MANUAL_ENCRYPT

# 7. From now on, reflashing the app over UART on THIS board requires the encrypted variants:
idf.py -p <PORT> encrypted-app-flash monitor
#    (Release mode: this stops working entirely — see §4.1. That's expected, not a bug.)
```

Only switch `CONFIG_SECURE_FLASH_ENCRYPTION_MODE_RELEASE=y` and repeat this sequence on a
**production** unit once you've done a full OTA round-trip successfully on a Development-mode
bench unit — Release mode is the point of no return for USB reflashing.

---

## 5. NVS encryption — protecting `nvs_factory` (id/pop) and `nvs`

Flash encryption does **not** blanket-cover every partition — only `app`, `bootloader`,
`partition_table`, and `otadata` are encrypted unconditionally. A plain `data/nvs` partition
(your `nvs` and `nvs_factory` rows) is only encrypted if its `partitions.csv` row carries the
`encrypted` flag (`partition-tables.rst:234`):

```csv
nvs,           data, nvs,      0x9000,   0x6000,   encrypted
nvs_factory,   data, nvs,      0x3E0000, 0x8000,   encrypted
```

Once flagged, it's fully transparent — no code changes anywhere. `esp_partition_read`/`write`
auto-encrypt/decrypt for any partition marked `encrypted`, and the NVS API always sees plaintext
values regardless (`flash-encryption.rst:748-756`). This is why `prov_store.c`'s
`nvs_get_str(h, "pop", ...)` doesn't need to change at all between Stage 1 and Stage 2 — it's the
same calls either way.

There's a separate, stricter "NVS Encryption" feature (`CONFIG_NVS_ENCRYPTION`, a dedicated
`nvs_keys` partition, `idf.py secure-generate-nvs-partition-key` / `secure-encrypt-nvs-partition`)
that does per-entry XTS encryption independent of whole-flash encryption. It exists if you ever
want NVS protected *without* enabling full flash encryption, but given this project is already
doing full flash encryption at Stage 2, the plain `encrypted` flag above is the simpler, correct
answer — you don't need this extra feature.

---

## 6. Quick reference — every command in order

```bash
source ~/.espressif/tools/activate_idf_v5.5.2.sh
cd pocs/node

# --- Stage 1 (now) ---
mkdir -p keys
idf.py secure-generate-signing-key --version 2 --scheme rsa3072 keys/sempreiot_signing_key.pem
chmod 600 keys/sempreiot_signing_key.pem
idf.py reconfigure          # after setting the Stage-1 Kconfig lines, §3
idf.py build
idf.py secure-verify-signature --version 2 --keyfile keys/sempreiot_signing_key.pem build/node.bin
idf.py -p <PORT> flash monitor

# --- Stage 2 (production units only, irreversible — bench-test in Development mode first) ---
idf.py reconfigure          # after setting the Stage-2 Kconfig lines, §4.2
idf.py build
idf.py bootloader           # then run the esptool.py write_flash command it prints
idf.py -p <PORT> flash
# power-cycle the board here — eFuses burn on this boot
idf.py -p <PORT> efuse-summary
idf.py -p <PORT> encrypted-app-flash monitor   # Development mode only; Release mode disables this
```

---

## 7. Before you ever flip Release mode on a real unit

- Full dev-mode dry run (Stage 2, Development flash-encryption) on a bench board, including a
  real OTA update round-trip, before touching a production unit.
- Back up the private signing key (`keys/sempreiot_signing_key.pem`) somewhere offline — per the
  blueprint's own §2 rule, losing it means no more updates for any fielded unit, ever.
- Confirm the OTA path (blueprint §3–4) is actually working end to end first — Release mode
  removes your USB fallback permanently, so OTA needs to already be the proven recovery path,
  not still under development.
