#include "test_support.h"

#include <string.h>

#include "unity.h"

#include "siot_util.h"

const uint8_t TV_PSK[16] = {0x25, 0x11, 0x8B, 0xA1, 0xDD, 0x19, 0xB8, 0x45,
                            0x09, 0xDF, 0x36, 0xE9, 0x41, 0x6B, 0x8D, 0xBE};
const uint8_t TV_SRC_MAC[6]   = {0x5A, 0x46, 0x52, 0x00, 0x00, 0x01};
const uint8_t TS_OTHER_MAC[6] = {0x5A, 0x46, 0x52, 0x00, 0x00, 0x99};

static int64_t s_now_ms;

void    ts_clock_set(int64_t ms)     { s_now_ms = ms; }
void    ts_clock_advance(int64_t ms) { s_now_ms += ms; }
int64_t ts_clock_now(void)           { return s_now_ms; }

uint8_t ts_tx_frame[SAFR_MAX_FRAME];
size_t  ts_tx_len;
uint8_t ts_tx_dst[6];
int     ts_tx_calls;

void ts_tx_sink(const uint8_t *frame, size_t len, const uint8_t dst_mac[6], void *ctx)
{
    (void)ctx;
    TEST_ASSERT_TRUE(len <= SAFR_MAX_FRAME);
    memcpy(ts_tx_frame, frame, len);
    ts_tx_len = len;
    memcpy(ts_tx_dst, dst_mac, 6);
    ts_tx_calls++;
}

void ts_safr_init(const uint8_t src_mac[6], uint16_t boot_ctr)
{
    siot_safr_config_t cfg = {
        .system_id = TV_SYSTEM_ID,
        .boot_ctr = boot_ctr,
        .now_ms = ts_clock_now,
        .allow_plaintext = false,
    };
    memcpy(cfg.safr_psk, TV_PSK, 16);
    memcpy(cfg.src_mac, src_mac, 6);
    TEST_ASSERT_EQUAL(ESP_OK, siot_safr_init(&cfg));
    siot_safr_set_level(0);
    siot_safr_set_tx(ts_tx_sink, NULL);
    ts_tx_len = 0;
    ts_tx_calls = 0;
}

size_t ts_unhex(const char *hex, uint8_t *out, size_t out_sz)
{
    const int n = siot_hex_decode(hex, out, out_sz);
    TEST_ASSERT_TRUE_MESSAGE(n > 0, "bad hex fixture");
    return (size_t)n;
}
