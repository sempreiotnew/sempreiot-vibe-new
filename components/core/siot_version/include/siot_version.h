/* siot_version — the firmware version, from firmware/VERSION (brief §2).
 *
 * Consumers: /info.fw (provisioning), INSTALLATION, the console `id` command,
 * the OTA manifest later. Layer 0 (core): no IDF dependencies.
 */
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* The contents of firmware/VERSION, e.g. "0.1.0-dev". */
const char *siot_version_string(void);

/* Short git commit of the firmware repo at configure time, "-dirty" appended
 * when the tree had uncommitted changes; "nogit" when not built from a
 * checkout. */
const char *siot_version_build_id(void);

/* "<version>+<build id>", e.g. "0.1.0-dev+7a1bb585". */
const char *siot_version_full(void);

#ifdef __cplusplus
}
#endif
