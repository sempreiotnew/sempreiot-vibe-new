/* PRODUCT ‖ HW_REV ‖ FW_LEN ‖ FW — the v3.5 tail of NAME_ANNOUNCE (spec §7.11)
 * and of a DEVICE_TABLE entry (§7.12). Pure: host-tested. */
#include <string.h>

#include "siot_safr.h"

size_t siot_safr_put_product(uint8_t *p, uint16_t product, uint8_t hw_rev, const char *fw)
{
    const size_t fw_len = fw ? strnlen(fw, SAFR_FW_MAX_LEN) : 0;
    p[0] = (uint8_t)(product >> 8);
    p[1] = (uint8_t)(product & 0xFF);
    p[2] = hw_rev;
    p[3] = (uint8_t)fw_len;
    if (fw_len) memcpy(&p[4], fw, fw_len);
    return 4 + fw_len;
}

size_t siot_safr_get_product(const uint8_t *p, size_t len, uint16_t *product, uint8_t *hw_rev,
                             char fw[SAFR_FW_MAX_LEN + 1])
{
    *product = SAFR_PRODUCT_UNKNOWN;
    *hw_rev = 0;
    fw[0] = '\0';
    if (len < 4) return 0;
    const size_t fw_len = p[3];
    if (fw_len > SAFR_FW_MAX_LEN || 4 + fw_len > len) return 0;
    *product = (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
    *hw_rev = p[2];
    memcpy(fw, &p[4], fw_len);
    fw[fw_len] = '\0';
    return 4 + fw_len;
}
