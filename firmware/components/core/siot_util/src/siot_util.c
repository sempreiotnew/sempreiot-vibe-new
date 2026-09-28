#include "siot_util.h"

#include <string.h>

static const char HEX_LC[] = "0123456789abcdef";
static const char HEX_UC[] = "0123456789ABCDEF";

static int hex_nibble(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

size_t siot_hex_encode(const uint8_t *in, size_t len, char *out, size_t out_sz)
{
    if (out_sz < 2 * len + 1) {
        if (out_sz > 0) out[0] = '\0';
        return 0;
    }
    for (size_t i = 0; i < len; i++) {
        out[2 * i]     = HEX_LC[in[i] >> 4];
        out[2 * i + 1] = HEX_LC[in[i] & 0x0F];
    }
    out[2 * len] = '\0';
    return 2 * len;
}

int siot_hex_decode(const char *hex, uint8_t *out, size_t out_sz)
{
    const size_t n = strlen(hex);
    if (n % 2 != 0 || n / 2 > out_sz) return -1;
    for (size_t i = 0; i < n / 2; i++) {
        const int hi = hex_nibble(hex[2 * i]);
        const int lo = hex_nibble(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) return -1;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    return (int)(n / 2);
}

char *siot_mac_to_str(const uint8_t mac[SIOT_MAC_LEN], char out[SIOT_MAC_STR_LEN])
{
    char *p = out;
    for (int i = 0; i < SIOT_MAC_LEN; i++) {
        *p++ = HEX_UC[mac[i] >> 4];
        *p++ = HEX_UC[mac[i] & 0x0F];
        *p++ = (i < SIOT_MAC_LEN - 1) ? ':' : '\0';
    }
    return out;
}

bool siot_mac_from_str(const char *s, uint8_t mac[SIOT_MAC_LEN])
{
    uint8_t tmp[SIOT_MAC_LEN];
    for (int i = 0; i < SIOT_MAC_LEN; i++) {
        const int hi = hex_nibble(s[0]);
        const int lo = hex_nibble(s[1]);
        if (hi < 0 || lo < 0) return false;
        tmp[i] = (uint8_t)((hi << 4) | lo);
        s += 2;
        if (i < SIOT_MAC_LEN - 1 && (*s == ':' || *s == '-')) s++;
    }
    if (*s != '\0') return false;
    memcpy(mac, tmp, SIOT_MAC_LEN);
    return true;
}

bool siot_mac_eq(const uint8_t a[SIOT_MAC_LEN], const uint8_t b[SIOT_MAC_LEN])
{
    return memcmp(a, b, SIOT_MAC_LEN) == 0;
}

bool siot_mac_is_bcast(const uint8_t mac[SIOT_MAC_LEN])
{
    for (int i = 0; i < SIOT_MAC_LEN; i++) {
        if (mac[i] != 0xFF) return false;
    }
    return true;
}
