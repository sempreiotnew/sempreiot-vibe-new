#include "prov_http.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_random.h"
#include "freertos/FreeRTOS.h"
#include "freertos/timers.h"
#include "mbedtls/base64.h"

#include "prov_crypto.h"
#include "prov_store.h"

static const char *TAG = "siot_http";

#define REQ_BODY_MAX 2048
#define FW_VERSION "1.0.0"

static siot_factory_id_t s_factory;
static siot_role_t s_role;
static siot_prov_done_cb_t s_on_done;

static siot_prov_state_t s_state = SIOT_PROV_IDLE;
static const char *s_detail = NULL;
static uint8_t s_nonce[16];
static bool s_have_nonce = false;
static siot_installation_t s_pending; /* built by /provision, saved on success */
static bool s_status_polled = false;
static TimerHandle_t s_reboot_timer = NULL;

static void mac_to_str(const uint8_t mac[6], char out[18])
{
    snprintf(out, 18, "%02X:%02X:%02X:%02X:%02X:%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

static const char *state_str(siot_prov_state_t s)
{
    switch (s) {
    case SIOT_PROV_IDLE: return "idle";
    case SIOT_PROV_IDENTIFIED: return "identified";
    case SIOT_PROV_STORED: return "stored";
    case SIOT_PROV_JOINING: return "joining";
    case SIOT_PROV_ONLINE: return "online";
    case SIOT_PROV_FAILED: return "failed";
    }
    return "idle";
}

static esp_err_t send_json(httpd_req_t *req, int status, cJSON *body)
{
    char status_line[32];
    snprintf(status_line, sizeof(status_line), "%d", status);
    httpd_resp_set_status(req, status_line);
    httpd_resp_set_type(req, "application/json");
    char *out = cJSON_PrintUnformatted(body);
    esp_err_t err = httpd_resp_send(req, out, HTTPD_RESP_USE_STRLEN);
    cJSON_free(out);
    cJSON_Delete(body);
    return err;
}

static esp_err_t send_ok(httpd_req_t *req, int status, cJSON *extra)
{
    cJSON *body = extra ? extra : cJSON_CreateObject();
    cJSON_AddBoolToObject(body, "ok", true);
    return send_json(req, status, body);
}

static esp_err_t send_err(httpd_req_t *req, int status, const char *error)
{
    cJSON *body = cJSON_CreateObject();
    cJSON_AddBoolToObject(body, "ok", false);
    cJSON_AddStringToObject(body, "error", error);
    return send_json(req, status, body);
}

/* Reads the whole request body (bounded by REQ_BODY_MAX) and parses it as
 * JSON. Caller owns the returned cJSON*; NULL on any failure (already
 * responded with an error in that case). */
static cJSON *read_json_body(httpd_req_t *req)
{
    if (req->content_len <= 0 || req->content_len >= REQ_BODY_MAX) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "bad body");
        return NULL;
    }
    static char buf[REQ_BODY_MAX];
    int received = 0;
    while (received < req->content_len) {
        int r = httpd_req_recv(req, buf + received, req->content_len - received);
        if (r <= 0) {
            httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "read error");
            return NULL;
        }
        received += r;
    }
    buf[received] = '\0';
    cJSON *json = cJSON_Parse(buf);
    if (!json) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "bad json");
        return NULL;
    }
    return json;
}

// ── GET /info ────────────────────────────────────────────────────────────

static esp_err_t handle_info(httpd_req_t *req)
{
    esp_fill_random(s_nonce, sizeof(s_nonce));
    s_have_nonce = true;

    char mac_str[18];
    mac_to_str(s_factory.mac, mac_str);
    char nonce_hex[33];
    for (int i = 0; i < 16; i++) snprintf(&nonce_hex[i * 2], 3, "%02x", s_nonce[i]);

    cJSON *body = cJSON_CreateObject();
    cJSON_AddStringToObject(body, "id", s_factory.id);
    cJSON_AddStringToObject(body, "mac", mac_str);
    cJSON_AddStringToObject(body, "model", s_factory.model);
    cJSON_AddStringToObject(body, "fw", FW_VERSION);
    cJSON_AddStringToObject(body, "state", state_str(s_state));
    cJSON_AddStringToObject(body, "nonce", nonce_hex);
    return send_json(req, 200, body);
}

// ── POST /identify ───────────────────────────────────────────────────────

static esp_err_t handle_identify(httpd_req_t *req)
{
    cJSON *json = read_json_body(req);
    if (!json) return ESP_OK;

    const cJSON *id = cJSON_GetObjectItem(json, "id");
    const cJSON *proof = cJSON_GetObjectItem(json, "proof");
    bool ok = false;

    if (s_have_nonce && cJSON_IsString(id) && cJSON_IsString(proof) &&
        strcmp(id->valuestring, s_factory.id) == 0) {
        char expected[65];
        siot_crypto_proof(s_factory.pop, s_nonce, sizeof(s_nonce), expected);
        ok = strcmp(expected, proof->valuestring) == 0;
    }
    cJSON_Delete(json);

    if (!ok) {
        ESP_LOGW(TAG, "identify: proof_mismatch");
        return send_err(req, 403, "proof_mismatch");
    }
    s_state = SIOT_PROV_IDENTIFIED;
    ESP_LOGI(TAG, "identified OK");
    return send_ok(req, 200, NULL);
}

// ── POST /provision ──────────────────────────────────────────────────────

static bool parse_code_json(const cJSON *code, siot_installation_t *out)
{
    const cJSON *system_id = cJSON_GetObjectItem(code, "system_id");
    const cJSON *net_ssid = cJSON_GetObjectItem(code, "net_ssid");
    const cJSON *net_psk = cJSON_GetObjectItem(code, "net_psk");
    const cJSON *safr_psk_hex = cJSON_GetObjectItem(code, "safr_psk_hex");
    const cJSON *channel = cJSON_GetObjectItem(code, "channel");
    const cJSON *mesh_id = cJSON_GetObjectItem(code, "mesh_id");

    if (!cJSON_IsNumber(system_id) || !cJSON_IsString(net_ssid) ||
        !cJSON_IsString(net_psk) || !cJSON_IsString(safr_psk_hex) ||
        !cJSON_IsNumber(channel) || !cJSON_IsNumber(mesh_id) ||
        strlen(safr_psk_hex->valuestring) != 32) {
        return false;
    }

    memset(out, 0, sizeof(*out));
    out->system_id = (uint16_t)system_id->valuedouble;
    strlcpy(out->net_ssid, net_ssid->valuestring, sizeof(out->net_ssid));
    strlcpy(out->net_psk, net_psk->valuestring, sizeof(out->net_psk));
    out->channel = (uint8_t)channel->valuedouble;
    out->mesh_id = (uint8_t)mesh_id->valuedouble;
    for (int i = 0; i < 16; i++) {
        unsigned int b;
        if (sscanf(&safr_psk_hex->valuestring[i * 2], "%2x", &b) != 1) return false;
        out->safr_psk[i] = (uint8_t)b;
    }
    return true;
}

static void reboot_timer_cb(TimerHandle_t t)
{
    (void)t;
    ESP_LOGI(TAG, "normal-mode boot (30s elapsed or /status already polled)");
    if (s_on_done) s_on_done(&s_pending);
}

static esp_err_t handle_provision(httpd_req_t *req)
{
    if (s_state == SIOT_PROV_IDLE) {
        return send_err(req, 409, "not_identified");
    }

    cJSON *json = read_json_body(req);
    if (!json) return ESP_OK;

    const cJSON *envelope = cJSON_GetObjectItem(json, "envelope");
    const cJSON *name = cJSON_GetObjectItem(json, "name");
    const cJSON *zone = cJSON_GetObjectItem(json, "zone");
    bool bad = !cJSON_IsString(envelope) || !s_have_nonce;

    if (!bad) {
        size_t raw_len = 0;
        mbedtls_base64_decode(NULL, 0, &raw_len,
                               (const uint8_t *)envelope->valuestring,
                               strlen(envelope->valuestring));
        uint8_t *raw = malloc(raw_len);
        size_t decoded_len = 0;
        bad = !raw || mbedtls_base64_decode(raw, raw_len, &decoded_len,
                                             (const uint8_t *)envelope->valuestring,
                                             strlen(envelope->valuestring)) != 0;

        if (!bad) {
            uint8_t key[16];
            siot_crypto_derive_key(s_factory.pop, s_nonce, sizeof(s_nonce), key);

            uint8_t plaintext[512];
            size_t plaintext_len = 0;
            int ret = siot_crypto_decrypt_envelope(
                key, raw, decoded_len, s_factory.id,
                plaintext, sizeof(plaintext) - 1, &plaintext_len);
            bad = ret != 0;

            if (!bad) {
                plaintext[plaintext_len] = '\0';
                cJSON *code = cJSON_Parse((const char *)plaintext);
                bad = !code || !parse_code_json(code, &s_pending);
                if (code) cJSON_Delete(code);
                if (!bad) {
                    if (cJSON_IsString(name)) {
                        strlcpy(s_pending.name, name->valuestring,
                                sizeof(s_pending.name));
                    }
                    if (cJSON_IsString(zone)) {
                        strlcpy(s_pending.zone, zone->valuestring,
                                sizeof(s_pending.zone));
                    }
                    bad = siot_store_save_installation(&s_pending) != ESP_OK;
                }
            }
        }
        if (raw) free(raw);
    }
    cJSON_Delete(json);

    if (bad) {
        ESP_LOGW(TAG, "provision: bad_envelope");
        return send_err(req, 400, "bad_envelope");
    }

    ESP_LOGI(TAG, "provisioned: system_id=%u name=%s zone=%s",
             s_pending.system_id, s_pending.name, s_pending.zone);
    esp_err_t send_result = send_ok(req, 202, NULL);

    /* Spec: code is stored regardless of what the mesh does next. Board/node
     * normal-mode behaviour (raising the installation AP, joining Mesh-Lite)
     * is out of scope here — this POC proves the setup-network cycle only. */
    s_state = SIOT_PROV_STORED;
    s_detail = NULL;
    s_status_polled = false;
    if (s_reboot_timer) xTimerStart(s_reboot_timer, 0);
    return send_result;
}

// ── POST /enroll (board only) ────────────────────────────────────────────

static bool parse_mac_str(const char *s, uint8_t mac[6])
{
    unsigned int b[6];
    if (sscanf(s, "%2x:%2x:%2x:%2x:%2x:%2x",
               &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) != 6) {
        return false;
    }
    for (int i = 0; i < 6; i++) mac[i] = (uint8_t)b[i];
    return true;
}

static esp_err_t handle_enroll(httpd_req_t *req)
{
    if (s_role != SIOT_ROLE_BOARD) {
        return send_err(req, 404, "not_a_board");
    }
    cJSON *json = read_json_body(req);
    if (!json) return ESP_OK;

    int count = cJSON_IsArray(json) ? cJSON_GetArraySize(json) : 0;

    /* Persisted to NVS immediately (not just held in RAM) so it survives
     * whichever order /enroll and /provision arrive in, and the reboot into
     * normal mode either one can trigger. board's normal-mode boot reads it
     * back via siot_store_load_enrolled(). */
    static siot_enrolled_entry_t list[SIOT_MAX_ENROLLED];
    size_t stored = 0;
    for (int i = 0; i < count && stored < SIOT_MAX_ENROLLED; i++) {
        const cJSON *item = cJSON_GetArrayItem(json, i);
        const cJSON *mac = cJSON_GetObjectItem(item, "mac");
        const cJSON *name = cJSON_GetObjectItem(item, "name");
        const cJSON *zone = cJSON_GetObjectItem(item, "zone");
        if (!cJSON_IsString(mac)) continue;

        siot_enrolled_entry_t *e = &list[stored];
        memset(e, 0, sizeof(*e));
        if (!parse_mac_str(mac->valuestring, e->mac)) continue;
        if (cJSON_IsString(name)) {
            strlcpy(e->name, name->valuestring, sizeof(e->name));
        }
        if (cJSON_IsString(zone)) {
            strlcpy(e->zone, zone->valuestring, sizeof(e->zone));
        }
        stored++;
    }
    cJSON_Delete(json);

    if (stored > 0) {
        esp_err_t err = siot_store_save_enrolled(list, stored);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "enroll: siot_store_save_enrolled failed: %s",
                     esp_err_to_name(err));
        }
    }
    ESP_LOGI(TAG, "enroll: count=%d stored=%d", count, (int)stored);

    cJSON *body = cJSON_CreateObject();
    cJSON_AddNumberToObject(body, "count", count);
    return send_ok(req, 200, body);
}

// ── GET /status ───────────────────────────────────────────────────────────

static esp_err_t handle_status(httpd_req_t *req)
{
    if (s_state == SIOT_PROV_STORED && !s_status_polled) {
        s_status_polled = true;
        /* "reboot ... after /status has been polled at least once": fire the
         * normal-mode transition on this first poll, ahead of the 30s cap. */
        if (s_reboot_timer) xTimerStop(s_reboot_timer, 0);
        reboot_timer_cb(NULL);
    }

    cJSON *body = cJSON_CreateObject();
    cJSON_AddStringToObject(body, "state", state_str(s_state));
    if (s_detail) {
        cJSON_AddStringToObject(body, "detail", s_detail);
    } else {
        cJSON_AddNullToObject(body, "detail");
    }
    return send_json(req, 200, body);
}

// ── wiring ────────────────────────────────────────────────────────────────

void siot_http_start(const siot_factory_id_t *factory, siot_role_t role,
                      siot_prov_done_cb_t on_done)
{
    s_factory = *factory;
    s_role = role;
    s_on_done = on_done;
    s_reboot_timer = xTimerCreate("siot_reboot", pdMS_TO_TICKS(30000), pdFALSE,
                                   NULL, reboot_timer_cb);

    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.uri_match_fn = httpd_uri_match_wildcard;

    httpd_handle_t server = NULL;
    ESP_ERROR_CHECK(httpd_start(&server, &config));

    static const httpd_uri_t routes[] = {
        {.uri = "/info", .method = HTTP_GET, .handler = handle_info},
        {.uri = "/identify", .method = HTTP_POST, .handler = handle_identify},
        {.uri = "/provision", .method = HTTP_POST, .handler = handle_provision},
        {.uri = "/enroll", .method = HTTP_POST, .handler = handle_enroll},
        {.uri = "/status", .method = HTTP_GET, .handler = handle_status},
    };
    for (size_t i = 0; i < sizeof(routes) / sizeof(routes[0]); i++) {
        ESP_ERROR_CHECK(httpd_register_uri_handler(server, &routes[i]));
    }
    ESP_LOGI(TAG, "provisioning server up on port %d", config.server_port);
}
