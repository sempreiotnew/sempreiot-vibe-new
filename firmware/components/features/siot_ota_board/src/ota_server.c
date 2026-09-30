/* ota_server — the image a unit pulls (protocol §13.4):
 *   GET http://192.168.4.1:8070/fw/node.bin   (leaf.bin)
 * Plain HTTP on the installation network, the whole file, chunked. Runs only
 * while a rollout is rolling or paused. */
#include <stdio.h>
#include <string.h>

#include "esp_http_server.h"
#include "esp_log.h"

#include "ota_internal.h"

static const char *TAG = "siot_ota_http";

#define SEND_BUF 4096

static httpd_handle_t s_server;

static esp_err_t handle_fw(httpd_req_t *req)
{
    uint8_t family = 0;
    if (strcmp(req->uri, "/fw/node.bin") == 0) family = SAFR_FAMILY_NODE;
    else if (strcmp(req->uri, "/fw/leaf.bin") == 0) family = SAFR_FAMILY_LEAF;
    char path[24];
    FILE *f = NULL;
    if (family != 0) {
        ota_path_for(family, "bin", path);
        f = fopen(path, "rb");
    }
    if (f == NULL) {
        ESP_LOGW(TAG, "GET %s: nothing to serve", req->uri);
        return httpd_resp_send_err(req, HTTPD_404_NOT_FOUND, "no such image");
    }
    char *buf = malloc(SEND_BUF);
    if (buf == NULL) {
        fclose(f);
        return httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "no memory");
    }
    httpd_resp_set_type(req, "application/octet-stream");
    size_t sent = 0, n;
    esp_err_t err = ESP_OK;
    while ((n = fread(buf, 1, SEND_BUF, f)) > 0) {
        err = httpd_resp_send_chunk(req, buf, (ssize_t)n);
        if (err != ESP_OK) break; /* the unit went away: it asks again */
        sent += n;
    }
    fclose(f);
    free(buf);
    if (err == ESP_OK) err = httpd_resp_send_chunk(req, NULL, 0);
    ESP_LOGI(TAG, "GET %s: %u B %s", req->uri, (unsigned)sent, err == ESP_OK ? "sent" : "interrupted");
    return err;
}

esp_err_t ota_server_start(void)
{
    if (s_server != NULL) return ESP_OK;
    httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
    cfg.server_port = OTA_HTTP_PORT;
    cfg.ctrl_port = 32769;          /* the provisioning / admin server owns the default one */
    cfg.uri_match_fn = httpd_uri_match_wildcard;
    cfg.lru_purge_enable = true;
    cfg.max_open_sockets = 3;       /* one unit at a time pulls (§13.6) */
    cfg.stack_size = 6144;
    esp_err_t err = httpd_start(&s_server, &cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "start: %s", esp_err_to_name(err));
        s_server = NULL;
        return err;
    }
    const httpd_uri_t route = {.uri = "/fw/*", .method = HTTP_GET, .handler = handle_fw};
    err = httpd_register_uri_handler(s_server, &route);
    if (err != ESP_OK) {
        httpd_stop(s_server);
        s_server = NULL;
        return err;
    }
    ESP_LOGW(TAG, "serving " OTA_FW_MOUNT " on port %d", OTA_HTTP_PORT);
    return ESP_OK;
}

void ota_server_stop(void)
{
    if (s_server == NULL) return;
    httpd_stop(s_server);
    s_server = NULL;
    ESP_LOGW(TAG, "stopped");
}
