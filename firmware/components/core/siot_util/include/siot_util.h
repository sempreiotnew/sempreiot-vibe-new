/* siot_util — small helpers shared by every layer (brief §2, core layer 0).
 *
 * put/get: big-endian, as everything on the SAFR wire is (spec §3). Ported
 * from the static put_u16/put_u32 in pocs/node/main/node_safr.c and
 * pocs/board/main/root_duties.c (identical bodies).
 * hex/mac: the formatting every component had its own copy of.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- big-endian byte order ------------------------------------------- */

static inline void siot_put_u16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)(v & 0xFF);
}

static inline void siot_put_u32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)(v & 0xFF);
}

static inline uint16_t siot_get_u16(const uint8_t *p)
{
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static inline uint32_t siot_get_u32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

/* ---- hex ------------------------------------------------------------- */

/* Lowercase hex, NUL-terminated. `out_sz` must be >= 2*len + 1; returns the
 * number of characters written (excluding the NUL), or 0 if `out` is too
 * small (then out[0] == '\0' when out_sz > 0). */
size_t siot_hex_encode(const uint8_t *in, size_t len, char *out, size_t out_sz);

/* Parses an even-length hex string (either case, no separators) into `out`.
 * Returns the number of bytes written, or -1 on odd length, bad character or
 * `out_sz` too small. */
int siot_hex_decode(const char *hex, uint8_t *out, size_t out_sz);

/* ---- MAC addresses --------------------------------------------------- */

#define SIOT_MAC_LEN     6
#define SIOT_MAC_STR_LEN 18 /* "AA:BB:CC:DD:EE:FF" + NUL */

/* "AA:BB:CC:DD:EE:FF" (uppercase) into `out[SIOT_MAC_STR_LEN]`. Returns out. */
char *siot_mac_to_str(const uint8_t mac[SIOT_MAC_LEN], char out[SIOT_MAC_STR_LEN]);

/* Parses "AA:BB:CC:DD:EE:FF" / "aa-bb-cc-dd-ee-ff" / "AABBCCDDEEFF". */
bool siot_mac_from_str(const char *s, uint8_t mac[SIOT_MAC_LEN]);

bool siot_mac_eq(const uint8_t a[SIOT_MAC_LEN], const uint8_t b[SIOT_MAC_LEN]);

/* FF:FF:FF:FF:FF:FF — SAFR broadcast / "to central" (spec §3). */
bool siot_mac_is_bcast(const uint8_t mac[SIOT_MAC_LEN]);

#ifdef __cplusplus
}
#endif
