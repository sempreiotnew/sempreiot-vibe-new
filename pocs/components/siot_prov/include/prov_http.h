/*
 * Setup-network HTTP provisioning server — pocs/POC-BRIEF.md §5.
 * Endpoints: GET /info, POST /identify, POST /provision, POST /enroll
 * (board only), GET /status. No /reset — that is a mock-only dev helper
 * (mocked-device-autoconnect/server.js), not part of the firmware contract.
 */
#pragma once

#include "prov_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Called once provisioning succeeds and normal-mode boot should happen
 * (spec: "reboot into normal mode after /status has been polled at least
 * once or after 30s"). Board/node-specific normal-mode behaviour is out of
 * scope for this component — the default implementation just esp_restart()s. */
typedef void (*siot_prov_done_cb_t)(const siot_installation_t *inst);

void siot_http_start(const siot_factory_id_t *factory, siot_role_t role,
                      siot_prov_done_cb_t on_done);

#ifdef __cplusplus
}
#endif
