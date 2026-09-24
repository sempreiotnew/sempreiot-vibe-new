/* The board's setup channel on the USB link (spec §3.1 v3.2, lifecycle §4.1):
 * SAFR frames under SYSTEM_ID 0x0000 keyed from this board's own sticker
 * (HKDF of id + pop). Two uses:
 *
 *   SETUP (no code)   the tablet writes the code: COMMAND SET_INSTALLATION
 *                     → validate → siot_config_save_code → ACK → reboot (Case B)
 *   provisioned       the tablet pulls the code: COMMAND GET_CODE → CODE
 *                     (the only way the code ever leaves the board over USB)
 *
 * Replay: the setup channel keeps its own last (BOOT_CTR, MSG_CTR) per boot
 * of the tablet's encoder; a frame not strictly newer is ignored.
 */
#include <string.h>

#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"

#include "coord_internal.h"
#include "siot_config.h"
#include "siot_identity.h"
#include "siot_link.h"
#include "siot_provisioning.h"
#include "siot_safr.h"
#include "siot_util.h"

static const char *TAG = "siot_setup";

static uint8_t  s_key[16];
static bool     s_key_ready;
static uint16_t s_tx_boot_ctr;
static uint32_t s_tx_msg_ctr;
static uint16_t s_tx_msg_id;
static uint16_t s_rx_boot_ctr;
static uint32_t s_rx_msg_ctr;
static bool     s_rx_seen;
static esp_timer_handle_t s_reboot_timer;

static void ensure_key(void)
{
    if (s_key_ready) return;
    const siot_identity_t *id = siot_identity_get();
    siot_prov_derive_setup_key(id->id, id->pop, s_key);
    s_tx_boot_ctr = siot_config_boot_ctr();
    s_key_ready = true;
}

static bool replay(const siot_safr_frame_t *f)
{
    if (s_rx_seen && f->boot_ctr == s_rx_boot_ctr && f->msg_ctr <= s_rx_msg_ctr) return true;
    s_rx_seen = true;
    s_rx_boot_ctr = f->boot_ctr;
    s_rx_msg_ctr = f->msg_ctr;
    return false;
}

static void send_setup(uint8_t msg_type, const uint8_t dst[6], const uint8_t *payload, size_t plen)
{
    uint8_t frame[SAFR_MAX_FRAME];
    s_tx_msg_id = (uint16_t)(s_tx_msg_id + 1);
    s_tx_msg_ctr++;
    const size_t n = siot_safr_build_frame_with(0x0000, s_key, frame, msg_type, s_tx_msg_id,
                                                siot_identity_get()->mac, dst, SAFR_TTL_MAX, 0, 0,
                                                s_tx_boot_ctr, s_tx_msg_ctr, payload, plen);
    if (n == 0) {
        ESP_LOGE(TAG, "build type 0x%02X failed", msg_type);
        return;
    }
    const esp_err_t err = siot_link_send(SIOT_LINK_SERIAL, dst, frame, n);
    if (err != ESP_OK) ESP_LOGW(TAG, "serial send: %s", esp_err_to_name(err));
}

static void send_ack(const siot_safr_frame_t *f, uint8_t status, uint8_t detail)
{
    const uint8_t p[4] = {(uint8_t)(f->msg_id >> 8), (uint8_t)f->msg_id, status, detail};
    send_setup(SAFR_MSG_ACK, f->src_mac, p, sizeof(p));
}

/* SET_INSTALLATION ARGS / CODE layout (spec §7.6 / §7.13). */
static size_t encode_code(const siot_installation_t *c, uint8_t *out)
{
    size_t off = 0;
    siot_put_u16(&out[off], c->system_id);
    off += 2;
    out[off++] = c->channel;
    out[off++] = c->mesh_id;
    const size_t s = strnlen(c->net_ssid, SIOT_SSID_MAX_LEN);
    out[off++] = (uint8_t)s;
    memcpy(&out[off], c->net_ssid, s);
    off += s;
    const size_t p = strnlen(c->net_psk, SIOT_PSK_MAX_LEN);
    out[off++] = (uint8_t)p;
    memcpy(&out[off], c->net_psk, p);
    off += p;
    memcpy(&out[off], c->safr_psk, SIOT_SAFR_PSK_LEN);
    off += SIOT_SAFR_PSK_LEN;
    const size_t n = strnlen(c->name, SIOT_NAME_MAX_LEN);
    out[off++] = (uint8_t)n;
    memcpy(&out[off], c->name, n);
    off += n;
    return off;
}

static bool decode_code(const uint8_t *a, size_t alen, siot_installation_t *out)
{
    size_t off = 0;
    memset(out, 0, sizeof(*out));
    if (alen < 4) return false;
    out->system_id = siot_get_u16(&a[off]);
    off += 2;
    out->channel = a[off++];
    out->mesh_id = a[off++];
    if (off >= alen) return false;
    size_t s = a[off++];
    if (s == 0 || s > SIOT_SSID_MAX_LEN || off + s > alen) return false;
    memcpy(out->net_ssid, &a[off], s);
    off += s;
    if (off >= alen) return false;
    size_t p = a[off++];
    if (p < 8 || p > SIOT_PSK_MAX_LEN || off + p > alen) return false;
    memcpy(out->net_psk, &a[off], p);
    off += p;
    if (off + SIOT_SAFR_PSK_LEN > alen) return false;
    memcpy(out->safr_psk, &a[off], SIOT_SAFR_PSK_LEN);
    off += SIOT_SAFR_PSK_LEN;
    if (off >= alen) return false;
    size_t n = a[off++];
    if (n > SIOT_NAME_MAX_LEN || off + n != alen) return false;
    memcpy(out->name, &a[off], n);
    if (out->system_id == 0) return false;
    if (out->channel != 1 && out->channel != 6 && out->channel != 11) return false;
    if (out->mesh_id == 0) out->mesh_id = (out->system_id & 0xFF) ? (out->system_id & 0xFF) : 1;
    return true;
}

static void reboot_cb(void *arg)
{
    (void)arg;
    ESP_LOGW(TAG, "code stored by the tablet (Case B) — rebooting into normal mode");
    esp_restart();
}

/* One frame on the serial link that did not pass the installation key. */
bool coord_setup_handle(const uint8_t *frame, size_t len, bool provisioned)
{
    if (len < SAFR_MIN_FRAME || siot_get_u16(&frame[7]) != 0x0000) return false;
    ensure_key();
    siot_safr_frame_t f;
    const siot_safr_parse_result_t r = siot_safr_parse_frame_with(0x0000, s_key, frame, len, &f);
    if (r != SIOT_SAFR_PARSE_OK) {
        ESP_LOGW(TAG, "setup-channel frame rejected: %d (wrong pop?)", (int)r);
        return true;
    }
    if (!(f.flags & SAFR_F_ENC) || f.msg_type != SAFR_MSG_COMMAND || f.payload_len < 2) return true;
    if (replay(&f)) return true;
    const uint8_t cmd = f.payload[0];
    const size_t alen = f.payload[1];
    if (f.payload_len < 2 + alen) {
        send_ack(&f, SAFR_ACK_ERROR, SAFR_ACK_D_BAD_ARGS);
        return true;
    }
    switch (cmd) {
    case SAFR_CMD_LINK_CHECK:
        send_ack(&f, SAFR_ACK_OK, SAFR_ACK_D_NONE);
        return true;

    case SAFR_CMD_SET_INSTALLATION: {
        if (provisioned) {
            send_ack(&f, SAFR_ACK_ERROR, SAFR_ACK_D_NOT_SETUP_MODE);
            return true;
        }
        siot_installation_t inst;
        if (!decode_code(&f.payload[2], alen, &inst)) {
            send_ack(&f, SAFR_ACK_ERROR, SAFR_ACK_D_BAD_ARGS);
            return true;
        }
        const esp_err_t err = siot_config_save_code(&inst);
        ESP_LOGW(TAG, "SET_INSTALLATION: system_id=0x%04X ssid=%s ch=%u name=%s -> %s",
                 inst.system_id, inst.net_ssid, inst.channel, inst.name, esp_err_to_name(err));
        send_ack(&f, err == ESP_OK ? SAFR_ACK_OK : SAFR_ACK_ERROR,
                 err == ESP_OK ? SAFR_ACK_D_NONE : SAFR_ACK_D_REFUSED);
        if (err == ESP_OK) {
            if (s_reboot_timer == NULL) {
                const esp_timer_create_args_t targs = {.callback = reboot_cb, .name = "setup_reboot"};
                esp_timer_create(&targs, &s_reboot_timer);
            }
            if (s_reboot_timer) esp_timer_start_once(s_reboot_timer, 1000 * 1000);
        }
        return true;
    }

    case SAFR_CMD_GET_CODE: {
        if (!provisioned) {
            send_ack(&f, SAFR_ACK_ERROR, SAFR_ACK_D_REFUSED);
            return true;
        }
        uint8_t p[SAFR_MAX_PAYLOAD];
        const size_t plen = encode_code(siot_config_code(), p);
        ESP_LOGW(TAG, "GET_CODE: tablet proved the sticker — sending the code over USB");
        send_setup(SAFR_MSG_CODE, f.src_mac, p, plen);
        return true;
    }

    default:
        send_ack(&f, SAFR_ACK_ERROR, SAFR_ACK_D_REFUSED);
        return true;
    }
}

/* Board in SETUP: only the setup channel listens on USB. */
static void on_setup_rx(siot_link_kind_t kind, const uint8_t *frame, size_t len, void *ctx)
{
    (void)ctx;
    if (kind != SIOT_LINK_SERIAL) return;
    if (!coord_setup_handle(frame, len, false)) {
        ESP_LOGD(TAG, "frame on the installation key while in setup: ignored");
    }
}

esp_err_t siot_coordinator_setup_channel_start(void)
{
    if (!siot_identity_valid()) return ESP_ERR_INVALID_STATE;
    ensure_key();
    esp_err_t err = siot_link_serial_init();
    if (err != ESP_OK) return err;
    siot_link_set_rx(on_setup_rx, NULL);
    err = siot_link_start(SIOT_LINK_SERIAL);
    if (err == ESP_OK) ESP_LOGI(TAG, "setup channel listening on USB (SET_INSTALLATION, Case B)");
    return err;
}
