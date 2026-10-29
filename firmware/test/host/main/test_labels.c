/* Labels (protocol §14.2, v3.8): LABEL_TABLE pages and the SET_LABEL /
 * DEL_LABEL / SET_DEVICE_IDS parsers. Byte layouts asserted against the
 * document, so a change in one without the other fails here. */
#include <string.h>

#include "unity.h"

#include "siot_safr.h"

TEST_CASE("labels: LABEL_TABLE page layout", "[safr][labels]")
{
    siot_safr_label_t labels[3] = {{1, "Portões"}, {2, "Térreo"}, {7, "1º andar"}};
    uint8_t p[SAFR_MAX_PAYLOAD];
    uint8_t pages = 0;
    size_t n = siot_safr_label_table_encode(p, SAFR_LABEL_ZONE, 0x0102, labels, 3, 1, &pages);
    TEST_ASSERT_EQUAL(1, pages);
    /* KIND ‖ PAGE ‖ PAGE_COUNT ‖ TOTAL u16 ‖ REV u16 ‖ COUNT */
    TEST_ASSERT_EQUAL_HEX8(SAFR_LABEL_ZONE, p[0]);
    TEST_ASSERT_EQUAL(1, p[1]);
    TEST_ASSERT_EQUAL(1, p[2]);
    TEST_ASSERT_EQUAL(0, p[3]);
    TEST_ASSERT_EQUAL(3, p[4]);
    TEST_ASSERT_EQUAL_HEX8(0x01, p[5]);
    TEST_ASSERT_EQUAL_HEX8(0x02, p[6]);
    TEST_ASSERT_EQUAL(3, p[7]);
    /* first entry: ID u16 ‖ NAME_LEN ‖ NAME ("Portões" = 8 bytes UTF-8) */
    TEST_ASSERT_EQUAL(0, p[8]);
    TEST_ASSERT_EQUAL(1, p[9]);
    TEST_ASSERT_EQUAL(8, p[10]);
    TEST_ASSERT_EQUAL_MEMORY("Portões", &p[11], 8);
    TEST_ASSERT_EQUAL(8 + (3 + 8) + (3 + 7) + (3 + 9), n);

    /* an empty table is one page, TOTAL 0, COUNT 0 */
    n = siot_safr_label_table_encode(p, SAFR_LABEL_ADDRESS, 0, labels, 0, 1, &pages);
    TEST_ASSERT_EQUAL(1, pages);
    TEST_ASSERT_EQUAL(8, n);
    TEST_ASSERT_EQUAL_HEX8(SAFR_LABEL_ADDRESS, p[0]);
    TEST_ASSERT_EQUAL(0, p[4]);
    TEST_ASSERT_EQUAL(0, p[7]);
    /* page 0 and a page past the end encode nothing */
    TEST_ASSERT_EQUAL(0, siot_safr_label_table_encode(p, SAFR_LABEL_ZONE, 0, labels, 3, 0, NULL));
    TEST_ASSERT_EQUAL(0, siot_safr_label_table_encode(p, SAFR_LABEL_ZONE, 0, labels, 3, 2, NULL));
}

TEST_CASE("labels: a full table of long names pages at the payload cap", "[safr][labels]")
{
    static siot_safr_label_t labels[SAFR_LABEL_CAP];
    for (size_t i = 0; i < SAFR_LABEL_CAP; i++) {
        labels[i].id = (uint16_t)(i + 1);
        memset(labels[i].name, 'a', SAFR_LABEL_NAME_MAX);
        labels[i].name[SAFR_LABEL_NAME_MAX] = '\0';
    }
    uint8_t p[SAFR_MAX_PAYLOAD];
    uint8_t pages = 0;
    size_t total = 0;
    siot_safr_label_table_encode(p, SAFR_LABEL_ZONE, 9, labels, SAFR_LABEL_CAP, 1, &pages);
    TEST_ASSERT_EQUAL(13, pages); /* 35 bytes per entry: 5 per page */
    for (uint8_t pg = 1; pg <= pages; pg++) {
        const size_t n = siot_safr_label_table_encode(p, SAFR_LABEL_ZONE, 9, labels, SAFR_LABEL_CAP, pg, NULL);
        TEST_ASSERT_TRUE(n > 0 && n <= SAFR_MAX_PAYLOAD);
        TEST_ASSERT_EQUAL(pg, p[1]);
        TEST_ASSERT_EQUAL(pages, p[2]);
        TEST_ASSERT_EQUAL(SAFR_LABEL_CAP, p[4]);
        total += p[7];
    }
    TEST_ASSERT_EQUAL(SAFR_LABEL_CAP, total);
}

TEST_CASE("labels: SET_LABEL / DEL_LABEL / SET_DEVICE_IDS args", "[safr][labels]")
{
    uint8_t kind;
    uint16_t id;
    char name[SAFR_LABEL_NAME_MAX + 1];
    /* KIND ‖ ID u16 ‖ NAME_LEN ‖ NAME */
    const uint8_t ok[] = {SAFR_LABEL_ADDRESS, 0x00, 0x05, 4, 'S', 'a', 'l', 'a'};
    TEST_ASSERT_TRUE(siot_safr_set_label_decode(ok, sizeof(ok), &kind, &id, name));
    TEST_ASSERT_EQUAL(SAFR_LABEL_ADDRESS, kind);
    TEST_ASSERT_EQUAL(5, id);
    TEST_ASSERT_EQUAL_STRING("Sala", name);
    const uint8_t id0[] = {SAFR_LABEL_ZONE, 0x00, 0x00, 1, 'x'};
    TEST_ASSERT_FALSE(siot_safr_set_label_decode(id0, sizeof(id0), &kind, &id, name));
    const uint8_t kind3[] = {3, 0x00, 0x01, 1, 'x'};
    TEST_ASSERT_FALSE(siot_safr_set_label_decode(kind3, sizeof(kind3), &kind, &id, name));
    const uint8_t empty[] = {SAFR_LABEL_ZONE, 0x00, 0x01, 0};
    TEST_ASSERT_FALSE(siot_safr_set_label_decode(empty, sizeof(empty), &kind, &id, name));
    TEST_ASSERT_FALSE(siot_safr_set_label_decode(ok, sizeof(ok) - 1, &kind, &id, name)); /* length mismatch */
    uint8_t longn[4 + SAFR_LABEL_NAME_MAX + 1] = {SAFR_LABEL_ZONE, 0x00, 0x01, SAFR_LABEL_NAME_MAX + 1};
    memset(&longn[4], 'n', SAFR_LABEL_NAME_MAX + 1);
    TEST_ASSERT_FALSE(siot_safr_set_label_decode(longn, sizeof(longn), &kind, &id, name));

    const uint8_t del[] = {SAFR_LABEL_ZONE, 0x01, 0x00};
    TEST_ASSERT_TRUE(siot_safr_del_label_decode(del, sizeof(del), &kind, &id));
    TEST_ASSERT_EQUAL(0x0100, id);
    const uint8_t del0[] = {SAFR_LABEL_ZONE, 0x00, 0x00};
    TEST_ASSERT_FALSE(siot_safr_del_label_decode(del0, sizeof(del0), &kind, &id));
    TEST_ASSERT_FALSE(siot_safr_del_label_decode(del, 2, &kind, &id));

    uint8_t mac[6];
    uint16_t zone_id, address_id;
    const uint8_t ids[] = {0x80, 0x45, 0x6B, 0x72, 0xE3, 0x30, 0x00, 0x02, 0x00, 0x00};
    TEST_ASSERT_TRUE(siot_safr_set_device_ids_decode(ids, sizeof(ids), mac, &zone_id, &address_id));
    TEST_ASSERT_EQUAL_HEX8(0x30, mac[5]);
    TEST_ASSERT_EQUAL(2, zone_id);
    TEST_ASSERT_EQUAL(SAFR_LABEL_ID_NONE, address_id);
    TEST_ASSERT_FALSE(siot_safr_set_device_ids_decode(ids, 9, mac, &zone_id, &address_id));
}
