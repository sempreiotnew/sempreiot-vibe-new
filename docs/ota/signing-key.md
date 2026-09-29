# The firmware signing key — where it is, how to replace it

_2026-09-29. Stage 1 of `ota-and-production-blueprint-v1.md` §6 (OTA brief decision 8). Commands and
behaviour below were run and read on ESP-IDF v5.5.2; the source lines are named so they can be
re-checked. Command reference for the later stages: `secure-signed-firmware-howto.md`._

---

## 1. What it is, in one paragraph

Every SempreIoT firmware image (board, node, leaf) is **signed** at build time with a private key.
A unit that receives an update checks the signature and **refuses a file that was not signed by the
key it trusts**, or that was changed on the way. The private key exists in one place, outside the
repository. Whoever holds it can make firmware every unit accepts — treat it like the master key of
every installation.

## 2. Where the key is

| What | Where |
|---|---|
| **Development key (in use today)** | `~/.sempreiot/keys/sempreiot_dev_signing_key.pem` on the build machine (created 2026-09-29, folder `700`, file `600`) |
| Its fingerprint (SHA-256 of the public key — safe to write down) | `797d2b255eccdd8d274b2844a2377170786413362566aa856a3437bc83f0ac82` |
| Type | RSA-3072, Secure Boot V2 format — the only scheme an ESP32-S3 supports |
| Another location | set `SIOT_SIGNING_KEY=/path/to/key.pem` in the environment (CI, a second machine) |
| In the repository | **never.** `.gitignore` refuses `*.pem`, `*.key` and `sempreiot_signing_key*` |
| Backup | **not made yet — do it** (§5). One copy on one laptop is one disk failure away from §6 |
| Production key | does not exist yet. It is made with the factory station (OTA blueprint Phase 5 / 6), on a machine that is not a developer laptop, and is never the development key |

`firmware/tools/signing_key.sh status` prints the path in use, whether the file is there and its
fingerprint. If the fingerprint it prints is not the one in this table, this document is out of date
or the machine has another key.

## 3. How the build uses it

- `firmware/tools/cmake/siot_signing.cmake` is included by the three `apps/*/CMakeLists.txt`. It finds
  the key (`SIOT_SIGNING_KEY`, else the path above), writes the five signing options with the key's
  absolute path into `build*/sdkconfig.signing` and appends that file to `SDKCONFIG_DEFAULTS`. No path
  is typed into a versioned file; `idf.py build` and `firmware/build.sh` behave the same.
- Options set (checked in `$IDF_PATH/components/bootloader/Kconfig.projbuild`):
  `SECURE_SIGNED_APPS_NO_SECURE_BOOT`, `SECURE_SIGNED_APPS_RSA_SCHEME`,
  `SECURE_SIGNED_ON_UPDATE_NO_SECURE_BOOT`, `SECURE_BOOT_BUILD_SIGNED_BINARIES`,
  `SECURE_BOOT_SIGNING_KEY`.
- Output: `sempreiot-<app>-unsigned.bin` and the signed `sempreiot-<app>.bin` (4 096 bytes longer: the
  signature sector). **Only the signed file is ever flashed or released.**
- **No key on the machine → the build stops** and says what to do. It never falls back to an unsigned
  image by itself.
- `SIOT_UNSIGNED=1 firmware/build.sh node` builds an unsigned image on purpose, for a bench unit
  flashed by cable. A unit that runs a signed image refuses it over OTA.
- An `sdkconfig` made before 2026-09-29 does not have the options: delete it (it is generated, not
  versioned) and build again. Done on this machine for all six build directories; the only
  differences were the signing options and new options at their defaults.

Check an image: `firmware/tools/signing_key.sh verify firmware/apps/node/build/sempreiot-node.bin`
→ `Signature block 0 verification successful using the supplied key (RSA)`.

## 4. What stage 1 protects, and what it does not

| | Stage 1 (now) |
|---|---|
| An update offered over the mesh, the installation Wi-Fi or the tablet's USB link | **checked**: signature verified before the image is accepted (`esp_ota_ops` / `esp_image_format`) |
| An image flashed with a cable (`flash.sh`, `esptool`) | **not checked** — nothing in the chip enforces it yet. Anyone with physical access and a cable can flash anything |
| Reading the flash with a cable | not protected (no flash encryption yet) |
| Reversible | yes — these are build options, nothing is burned into the chip |

Closing the cable gap is Secure Boot V2 + flash encryption (stage 2, production only, **irreversible**:
eFuses are burned). That is OTA blueprint Phase 6, not this step.

**Which key does a unit trust?** The key that signed the image **it is running now** — there is no
key stored anywhere else in stage 1 (`secure_boot_signatures_app.c`, `get_secure_boot_key_digests`:
"Take trusted digest key(s) from running app"). And only **the first signature** of an image counts:
with `SECURE_SIGNED_ON_UPDATE_NO_SECURE_BOOT` the verifier looks at signature block 0 only
(`secure_boot_num_blocks = 1`, same file). Two consequences, both used below:

1. A unit flashed by cable with an image signed by key A accepts, over OTA, only images signed by A.
2. **A key cannot be replaced over OTA in stage 1.** Signing an image with two keys does not help:
   the second signature is never read.

## 5. Back it up (do this once, now)

```bash
source ~/.espressif/tools/activate_idf_v5.5.2.sh
firmware/tools/signing_key.sh backup /Volumes/<an encrypted disk or vault you control>
```

Not in the repository, not in a chat, not in an e-mail, not in a cloud folder shared with anyone who
should not be able to sign firmware. Write where the copy is in the table of §2.

Giving the key to a second developer or to CI: copy the file to the same path on that machine
(`chmod 600`), or anywhere and set `SIOT_SIGNING_KEY`. `signing_key.sh status` must print the same
fingerprint on both.

## 6. Replacing or regenerating the key

Use this when the key is **lost**, when it **may have leaked** (a laptop stolen, the file sent
somewhere it should not have been), or when moving from the development key to the production key.

```bash
source ~/.espressif/tools/activate_idf_v5.5.2.sh
firmware/tools/signing_key.sh new        # the old file is kept beside the new one, dated
firmware/tools/signing_key.sh backup <dir>
firmware/build.sh board && firmware/build.sh node && firmware/build.sh leaf
tools/flash.sh <board|node|leaf> <port> <sticker-id>     # EVERY unit, by cable, once
```

Then update the fingerprint and the date in §2 of this file, in the same change.

What it costs, plainly:

| Situation | What happens |
|---|---|
| The key is **lost**, units in the field run images signed with it | they can never be updated over OTA again: nobody can sign an image they accept. Each unit is flashed by cable once with an image signed by the new key. They keep working meanwhile — signing affects updates, not operation |
| The key **leaked** | same procedure, and quickly: until a unit is re-flashed it accepts images signed by whoever has the old key |
| Development key → production key | same procedure at the factory: production units are flashed once with images signed by the production key and never see the development key |
| The old key is **still available** and the units are reachable | it changes nothing: a unit trusts only the key of the image it runs (§4), so an image signed with the new key is refused, and a second signature is ignored. Cable, once |

A cable flash with `tools/flash.sh` keeps the unit's identity (`nvs_factory`: id, pop, model) and its
installation code; only the application is replaced.

**Why this is acceptable for now:** every unit today is on a bench within reach of a cable. **It stops
being acceptable when units are installed on a customer's ceiling** — before the first site, the
production key must exist, be backed up in two places, and the move to stage 2 (eFuse key slots: an
ESP32-S3 holds three key digests and can revoke one, which is what makes replacing a key possible
without a cable) must be planned. That is on the list of OTA blueprint Phase 6.

## 7. Checklist for whoever inherits this

- [ ] `signing_key.sh status` prints the fingerprint of §2.
- [ ] A backup exists and its place is written in §2.
- [ ] A build on a machine without the key stops with the message pointing here.
- [ ] `signing_key.sh verify` passes on the three release images.
- [ ] Bench check O1 of the OTA brief: a unit refuses an unsigned image and an image signed with
      another key **over OTA** (needs the push of step 1 to exist — not verified on hardware yet).
