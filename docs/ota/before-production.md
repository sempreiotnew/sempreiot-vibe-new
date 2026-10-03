# Before production — what is relaxed for the bench, and must be restored

_Started 2026-09-29. One page, so nothing that was loosened to make testing possible is forgotten.
Every item names **what** is relaxed, **why**, **where it is switched**, and **how it is caught** if
someone forgets. The machine check is `firmware/ci/check.sh`: it lists every item below that is still
relaxed as a warning on every run, and **`firmware/ci/check.sh --release` fails** while any is._

**Rule for whoever changes the code:** relaxing anything for the bench means, in the same change, a
row in the table below **and** a line in the production gate of `firmware/ci/check.sh`. Restoring it
means removing both.

---

## The list

| # | What is relaxed today | Why | Where it is switched | Production value | Caught by |
|---|---|---|---|---|---|
| **1** | **The version rule is OFF.** A unit must install an image only when its version is **newer** than the one it runs (protocol §13.2). Today the board takes any version: the same one again, an older one. | Requested 2026-09-29 for the bench: the same test image must be pushable over and over. | `CONFIG_SIOT_OTA_TEST_ANY_VERSION` (`firmware/components/features/siot_ota_board/Kconfig`), **default `y`** | **`n`** — then change the default in the Kconfig to `n`, so a fresh build is safe by itself | `ci/check.sh --release`; the board logs `TEST BUILD: this board accepts ANY firmware version` at every boot and at every push it takes that way |
| 2 | `FORCE` (the tablet asking for a downgrade) can be honoured | Bench: take a board back to an older image | `CONFIG_SIOT_OTA_ALLOW_FORCE`, default `n`; on the tablet the FORCE switch exists only in a debug build or with `--dart-define=OTA_ALLOW_FORCE=true` | `n`, and a release APK built without the define | `ci/check.sh --release` |
| 3 | An image can be built to fail its self-test | Bench check O4 (the rollback) | `CONFIG_SIOT_OTA_SELFTEST_FAIL`, default `n`; only `tools/ota_test_images.sh` turns it on, in its own build directory | `n` | `ci/check.sh --release` |
| 4 | An image can be built unsigned | A bench unit flashed by cable | `SIOT_UNSIGNED=1` in the environment (`tools/cmake/siot_signing.cmake`) | never set | `ci/check.sh` (every run, not only `--release`): an unsigned image fails it |
| 5 | **The images are signed with the development key** | There is no production key yet | `~/.sempreiot/keys/sempreiot_dev_signing_key.pem` (`docs/ota/signing-key.md`) | the production key, made on a machine that is not a developer laptop, backed up in two places; every production unit flashed once with images signed by it | `ci/check.sh --release` compares the fingerprint of the key in use with the development key's |
| 6 | The version is a pre-release (`0.1.0-dev`) | Nothing was released yet | `firmware/VERSION` | a release number from the git tag (OTA brief decision 12) | `ci/check.sh --release` |
| 7 | **No hardware security:** anyone with a cable can flash any image or read the flash | Stage 1 is reversible, stage 2 burns eFuses | Secure Boot V2 + flash encryption (`docs/ota/secure-signed-firmware-howto.md` §4) | on, production units only | not automated — OTA blueprint Phase 6 |
| 8 | **The update PIN is asked only once per app session.** Every action that starts something on the units (Atualizar, Tentar de novo, Continuar, Retomar) needs the Master or Nível 4 PIN; on the bench it is asked on the first one and not again until the app restarts (Pausar / Cancelar never ask). Each start is in the audit trail with who did it | Requested 2026-10-02: typing the PIN on every bench run is too slow; the decision for production is the user's, later | `otaPinOncePerSession` in `mobile/sempreiot_central_app/lib/features/central/application/ota_pin_policy.dart` | `false` — the PIN on every start (or what the user decides) | `ci/check.sh --release` |

## When the version rule comes back (item 1)

The same rule will exist in the node and the leaf when they learn to update (OTA brief step 2 and 4).
The test switch must then cover them too, **as the same option**, so that one line turns the rule back
on everywhere. When it is turned on:

1. `CONFIG_SIOT_OTA_TEST_ANY_VERSION=n`, and the Kconfig default changed to `n`.
2. Delete the generated `sdkconfig` of every build directory (it remembers the old value) and build.
3. `firmware/ci/check.sh --release` must pass.
4. Bench: pushing the version the board already runs is refused with "not newer" (check O11).
5. Remove row 1 from this page and its line from the production gate.
