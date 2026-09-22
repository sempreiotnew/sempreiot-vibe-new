/* Setup-network HTTP contract — from pocs/components/siot_prov/prov_http.c.
 * Changes: fw = siot_version, storage via siot_config, hex/MAC via siot_util,
 * `epoch` is parsed and logged (nothing consumes it yet: the board's clock
 * comes from TIME_SYNC, brief §8). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_random.h"
#include "freertos/FreeRTOS.h"
#include "freertos/timers.h"
#include "mbedtls/base64.h"

#include "prov_internal.h"
#include "siot_config.h"
#include "siot_provisioning.h"
#include "siot_util.h"
#include "siot_version.h"

static const char *TAG = "siot_prov";

#define REQ_BODY_MAX     2048
#define REBOOT_AFTER_MS  30000

/* idle -> identified -> stored -> joining -> online | failed (POC-BRIEF §5) */
typedef enum { ST_IDLE, ST_IDENTIFIED, ST_STORED } prov_state_t;

static const siot_identity_t *s_id;
static bool s_is_board;
static prov_done_cb_t s_on_stored;

static prov_state_t s_state = ST_IDLE;
static uint8_t s_nonce[16];
static bool s_have_nonce;
static bool s_status_polled;
static TimerHandle_t s_reboot_timer;

static const char *state_str(prov_state_t s)
{
    switch (s) {
    case ST_IDENTIFIED: return "identified";
    case ST_STORED:     return "stored";
    case ST_IDLE:
    default:            return "idle";
    }
}

static esp_err_t send_json(httpd_req_t *req, int status, cJSON *body)
{
    char status_line[32];
    snprintf(status_line, sizeof(status_line), "%d", status);
    httpd_resp_set_status(req, status_line);
    httpd_resp_set_type(req, "application/json");
    char *out = cJSON_PrintUnformatted(body);
    const esp_err_t err = httpd_resp_send(req, out, HTTPD_RESP_USE_STRLEN);
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

/* Whole body (bounded) parsed as JSON; NULL after an error response. */
static cJSON *read_json_body(httpd_req_t *req)
{
    if (req->content_len <= 0 || req->content_len >= REQ_BODY_MAX) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "bad body");
        return NULL;
    }
    static char buf[REQ_BODY_MAX];
    int received = 0;
    while (received < req->content_len) {
        const int r = httpd_req_recv(req, buf + received, req->content_len - received);
        if (r <= 0) {
            httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "read error");
            return NULL;
        }
        received += r;
    }
    buf[received] = '\0';
    cJSON *json = cJSON_Parse(buf);
    if (!json) httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "bad json");
    return json;
}

/* ---- GET /info -------------------------------------------------------- */

static esp_err_t handle_info(httpd_req_t *req)
{
    esp_fill_random(s_nonce, sizeof(s_nonce));
    s_have_nonce = true;

    char mac_str[SIOT_MAC_STR_LEN];
    char nonce_hex[33];
    siot_mac_to_str(s_id->mac, mac_str);
    siot_hex_encode(s_nonce, sizeof(s_nonce), nonce_hex, sizeof(nonce_hex));

    cJSON *body = cJSON_CreateObject();
    cJSON_AddStringToObject(body, "id", s_id->id);
    cJSON_AddStringToObject(body, "mac", mac_str);
    cJSON_AddStringToObject(body, "model", s_id->model);
    cJSON_AddStringToObject(body, "fw", siot_version_string());
    cJSON_AddStringToObject(body, "state", state_str(s_state));
    cJSON_AddStringToObject(body, "nonce", nonce_hex);
    return send_json(req, 200, body);
}

/* ---- POST /identify --------------------------------------------------- */

static esp_err_t handle_identify(httpd_req_t *req)
{
    cJSON *json = read_json_body(req);
    if (!json) return ESP_OK;

    const cJSON *id = cJSON_GetObjectItem(json, "id");
    const cJSON *proof = cJSON_GetObjectItem(json, "proof");
    bool ok = false;
    if (s_have_nonce && cJSON_IsString(id) && cJSON_IsString(proof) &&
        strcmp(id->valuestring, s_id->id) == 0) {
        char expected[65];
        siot_prov_proof(s_id->pop, s_nonce, sizeof(s_nonce), expected);
        ok = strcmp(expected, proof->valuestring) == 0;
    }
    cJSON_Delete(json);

    if (!ok) {
        ESP_LOGW(TAG, "identify: proof_mismatch");
        return send_err(req, 403, "proof_mismatch");
    }
    s_state = ST_IDENTIFIED;
    ESP_LOGI(TAG, "identified");
    return send_ok(req, 200, NULL);
}

/* ---- POST /provision -------------------------------------------------- */

static bool parse_code_json(const cJSON *code, siot_installation_t *out)
{
    const cJSON *system_id = cJSON_GetObjectItem(code, "system_id");
    const cJSON *net_ssid = cJSON_GetObjectItem(code, "net_ssid");
    const cJSON *net_psk = cJSON_GetObjectItem(code, "net_psk");
    const cJSON *safr_psk_hex = cJSON_GetObjectItem(code, "safr_psk_hex");
    const cJSON *channel = cJSON_GetObjectItem(code, "channel");
    const cJSON *mesh_id = cJSON_GetObjectItem(code, "mesh_id");

    if (!cJSON_IsNumber(system_id) || !cJSON_IsString(net_ssid) || !cJSON_IsString(net_psk) ||
        !cJSON_IsString(safr_psk_hex) || !cJSON_IsNumber(channel) || !cJSON_IsNumber(mesh_id) ||
        strlen(safr_psk_hex->valuestring) != 2 * SIOT_SAFR_PSK_LEN) {
        return false;
    }
    memset(out, 0, sizeof(*out));
    out->system_id = (uint16_t)system_id->valuedouble;
    strlcpy(out->net_ssid, net_ssid->valuestring, sizeof(out->net_ssid));
    strlcpy(out->net_psk, net_psk->valuestring, sizeof(out->net_psk));
    out->channel = (uint8_t)channel->valuedouble;
    out->mesh_id = (uint8_t)mesh_id->valuedouble;
    return siot_hex_decode(safr_psk_hex->valuestring, out->safr_psk, SIOT_SAFR_PSK_LEN) ==
           SIOT_SAFR_PSK_LEN;
}

static void reboot_timer_cb(TimerHandle_t t)
{
    (void)t;
    ESP_LOGI(TAG, "normal-mode boot (30 s elapsed or /status polled)");
    if (s_on_stored) s_on_stored();
}

static esp_err_t handle_provision(httpd_req_t *req)
{
    if (s_state == ST_IDLE) return send_err(req, 409, "not_identified");

    cJSON *json = read_json_body(req);
    if (!json) return ESP_OK;

    const cJSON *envelope = cJSON_GetObjectItem(json, "envelope");
    const cJSON *name = cJSON_GetObjectItem(json, "name");
    const cJSON *zone = cJSON_GetObjectItem(json, "zone");
    const cJSON *epoch = cJSON_GetObjectItem(json, "epoch");
    siot_installation_t inst;
    bool bad = !cJSON_IsString(envelope) || !s_have_nonce;

    if (!bad) {
        const size_t env_len = strlen(envelope->valuestring);
        size_t raw_len = 0;
        mbedtls_base64_decode(NULL, 0, &raw_len, (const uint8_t *)envelope->valuestring, env_len);
        uint8_t *raw = malloc(raw_len);
        size_t decoded_len = 0;
        bad = !raw || mbedtls_base64_decode(raw, raw_len, &decoded_len,
                                            (const uint8_t *)envelope->valuestring, env_len) != 0;
        if (!bad) {
            uint8_t key[16];
            siot_prov_derive_key(s_id->pop, s_nonce, sizeof(s_nonce), key);

            uint8_t plaintext[512];
            size_t plaintext_len = 0;
            bad = siot_prov_decrypt_envelope(key, raw, decoded_len, s_id->id, plaintext,
                                             sizeof(plaintext) - 1, &plaintext_len) != 0;
            if (!bad) {
                plaintext[plaintext_len] = '\0';
                cJSON *code = cJSON_Parse((const char *)plaintext);
                bad = !code || !parse_code_json(code, &inst);
                if (code) cJSON_Delete(code);
            }
            if (!bad) {
                if (cJSON_IsString(name)) strlcpy(inst.name, name->valuestring, sizeof(inst.name));
                if (cJSON_IsString(zone)) strlcpy(inst.zone, zone->valuestring, sizeof(inst.zone));
                bad = siot_config_save_code(&inst) != ESP_OK;
            }
        }
        free(raw);
    }
    if (!bad && cJSON_IsNumber(epoch)) {
        ESP_LOGI(TAG, "installer epoch %u (not applied: clock comes from TIME_SYNC)",
                 (unsigned)epoch->valuedouble);
    }
    cJSON_Delete(json);

    if (bad) {
        ESP_LOGW(TAG, "provision: bad_envelope");
        return send_err(req, 400, "bad_envelope");
    }

    ESP_LOGI(TAG, "provisioned: system_id=%u ssid=%s ch=%u mesh=%u name=%s zone=%s",
             inst.system_id, inst.net_ssid, inst.channel, inst.mesh_id, inst.name, inst.zone);
    const esp_err_t send_result = send_ok(req, 202, NULL);

    s_state = ST_STORED;
    s_status_polled = false;
    if (s_reboot_timer) xTimerStart(s_reboot_timer, 0);
    return send_result;
}

/* ---- POST /enroll (board only) ---------------------------------------- */

static esp_err_t handle_enroll(httpd_req_t *req)
{
    if (!s_is_board) return send_err(req, 404, "not_a_board");
    cJSON *json = read_json_body(req);
    if (!json) return ESP_OK;

    const int count = cJSON_IsArray(json) ? cJSON_GetArraySize(json) : 0;
    /* Persisted immediately so it survives whichever order /enroll and
     * /provision arrive in, and the reboot either one triggers. */
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
        if (!siot_mac_from_str(mac->valuestring, e->mac)) continue;
        if (cJSON_IsString(name)) strlcpy(e->name, name->valuestring, sizeof(e->name));
        if (cJSON_IsString(zone)) strlcpy(e->zone, zone->valuestring, sizeof(e->zone));
        stored++;
    }
    cJSON_Delete(json);

    if (stored > 0) {
        const esp_err_t err = siot_config_save_enrolled(list, stored);
        if (err != ESP_OK) ESP_LOGW(TAG, "enroll: save failed: %s", esp_err_to_name(err));
    }
    ESP_LOGI(TAG, "enroll: count=%d stored=%d", count, (int)stored);

    cJSON *body = cJSON_CreateObject();
    cJSON_AddNumberToObject(body, "count", count);
    return send_ok(req, 200, body);
}

/* ---- GET /status ------------------------------------------------------ */

static esp_err_t handle_status(httpd_req_t *req)
{
    if (s_state == ST_STORED && !s_status_polled) {
        s_status_polled = true;
        /* "reboot after /status has been polled at least once": fire now,
         * ahead of the 30 s cap. */
        if (s_reboot_timer) xTimerStop(s_reboot_timer, 0);
        reboot_timer_cb(NULL);
    }
    cJSON *body = cJSON_CreateObject();
    cJSON_AddStringToObject(body, "state", state_str(s_state));
    cJSON_AddNullToObject(body, "detail");
    return send_json(req, 200, body);
}

/* ---- wiring ----------------------------------------------------------- */

esp_err_t prov_http_start(const siot_identity_t *id, bool is_board, prov_done_cb_t on_stored)
{
    s_id = id;
    s_is_board = is_board;
    s_on_stored = on_stored;
    s_reboot_timer = xTimerCreate("siot_reboot", pdMS_TO_TICKS(REBOOT_AFTER_MS), pdFALSE, NULL,
                                  reboot_timer_cb);
    if (s_reboot_timer == NULL) return ESP_ERR_NO_MEM;

    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.uri_match_fn = httpd_uri_match_wildcard;

    httpd_handle_t server = NULL;
    esp_err_t err = httpd_start(&server, &config);
    if (err != ESP_OK) return err;

    static const httpd_uri_t routes[] = {
        {.uri = "/info",      .method = HTTP_GET,  .handler = handle_info},
        {.uri = "/identify",  .method = HTTP_POST, .handler = handle_identify},
        {.uri = "/provision", .method = HTTP_POST, .handler = handle_provision},
        {.uri = "/enroll",    .method = HTTP_POST, .handler = handle_enroll},
        {.uri = "/status",    .method = HTTP_GET,  .handler = handle_status},
    };
    for (size_t i = 0; i < sizeof(routes) / sizeof(routes[0]); i++) {
        err = httpd_register_uri_handler(server, &routes[i]);
        if (err != ESP_OK) return err;
    }
    ESP_LOGI(TAG, "provisioning server up on port %d", config.server_port);
    return ESP_OK;
}
