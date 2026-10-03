/* siot_ota_proto — protocol §13 (v3.5). Byte layouts are asserted against the
 * tables of the document, so a change in one without the other fails here. */
#include <string.h>

#include "unity.h"

#include "siot_ota_proto.h"

static void fill_sha(uint8_t sha[SIOT_OTA_SHA_LEN])
{
    for (int i = 0; i < SIOT_OTA_SHA_LEN; i++) sha[i] = (uint8_t)(0xA0 + i);
}

TEST_CASE("ota: version parse and order", "[ota][version]")
{
    siot_ota_version_t a, b;
    TEST_ASSERT_TRUE(siot_ota_version_parse("0.1.0-dev", &a));
    TEST_ASSERT_EQUAL(0, a.major);
    TEST_ASSERT_EQUAL(1, a.minor);
    TEST_ASSERT_EQUAL(0, a.patch);
    TEST_ASSERT_EQUAL_STRING("dev", a.pre);
    TEST_ASSERT_TRUE(siot_ota_version_parse("1.12.3+7a1bb585", &b)); /* build metadata dropped */
    TEST_ASSERT_EQUAL(12, b.minor);
    TEST_ASSERT_EQUAL_STRING("", b.pre);

    static const char *bad[] = {"", "1", "1.2", "1.2.", "v1.2.3", "1.2.3-", "1.2.3 ", "1.2.x", "1..3",
                                "1.2.3-dev!", "1.2.3.4", "-1.2.3", "1.2.3-0123456789012345678901"};
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        TEST_ASSERT_FALSE_MESSAGE(siot_ota_version_parse(bad[i], &a), bad[i]);
    }
    TEST_ASSERT_FALSE(siot_ota_version_parse(NULL, &a));

    /* each pair: left is OLDER than right */
    static const char *order[][2] = {
        {"0.1.0", "0.1.1"}, {"0.1.9", "0.2.0"}, {"0.9.9", "1.0.0"}, {"0.2.0", "0.10.0"},
        {"0.2.0-dev", "0.2.0"}, {"0.1.9", "0.2.0-dev"}, {"0.2.0-dev", "0.2.0-rc.1"},
    };
    for (size_t i = 0; i < sizeof(order) / sizeof(order[0]); i++) {
        TEST_ASSERT_TRUE(siot_ota_version_parse(order[i][0], &a));
        TEST_ASSERT_TRUE(siot_ota_version_parse(order[i][1], &b));
        TEST_ASSERT_TRUE_MESSAGE(siot_ota_version_cmp(&a, &b) < 0, order[i][1]);
        TEST_ASSERT_TRUE_MESSAGE(siot_ota_version_cmp(&b, &a) > 0, order[i][1]);
    }
    TEST_ASSERT_TRUE(siot_ota_version_parse("0.2.0", &a));
    TEST_ASSERT_TRUE(siot_ota_version_parse("0.2.0+build9", &b));
    TEST_ASSERT_EQUAL(0, siot_ota_version_cmp(&a, &b));
}

TEST_CASE("ota: a unit installs only a newer version; force is bench only", "[ota][version]")
{
    TEST_ASSERT_EQUAL(SIOT_OTA_R_NONE, siot_ota_accept_version("0.1.0", "0.2.0", false, false));
    TEST_ASSERT_EQUAL(SIOT_OTA_R_NONE, siot_ota_accept_version("0.2.0-dev", "0.2.0", false, false));
    TEST_ASSERT_EQUAL(SIOT_OTA_R_NOT_NEWER, siot_ota_accept_version("0.2.0", "0.2.0", false, false));
    TEST_ASSERT_EQUAL(SIOT_OTA_R_NOT_NEWER, siot_ota_accept_version("0.2.0", "0.1.9", false, false));
    TEST_ASSERT_EQUAL(SIOT_OTA_R_NOT_NEWER, siot_ota_accept_version("0.2.0", "0.2.0-dev", false, false));
    TEST_ASSERT_EQUAL(SIOT_OTA_R_BAD_VERSION, siot_ota_accept_version("0.2.0", "latest", false, false));
    TEST_ASSERT_EQUAL(SIOT_OTA_R_BAD_VERSION, siot_ota_accept_version("0.2.0", "latest", true, true));
    /* downgrade: bench build with FORCE yes, production build never */
    TEST_ASSERT_EQUAL(SIOT_OTA_R_NONE, siot_ota_accept_version("0.2.0", "0.1.0", true, true));
    TEST_ASSERT_EQUAL(SIOT_OTA_R_FORCE_REFUSED, siot_ota_accept_version("0.2.0", "0.1.0", true, false));
    /* a unit whose own version is unreadable takes the update */
    TEST_ASSERT_EQUAL(SIOT_OTA_R_NONE, siot_ota_accept_version("", "0.1.0", false, false));
}

TEST_CASE("ota: crc32 check value", "[ota][crc]")
{
    TEST_ASSERT_EQUAL_HEX32(0xCBF43926u, siot_ota_crc32((const uint8_t *)"123456789", 9));
    TEST_ASSERT_EQUAL_HEX32(0x00000000u, siot_ota_crc32(NULL, 0));
}

TEST_CASE("ota: OTA_PUSH_BEGIN layout and limits", "[ota][push]")
{
    siot_ota_image_t img = {.family = SAFR_FAMILY_NODE, .size = 0x000E1000, .chunk = 4096, .flags = 0};
    fill_sha(img.sha256);
    strcpy(img.version, "0.2.0");
    uint8_t p[SAFR_MAX_PAYLOAD];
    const size_t n = siot_ota_push_begin_encode(p, &img);
    TEST_ASSERT_EQUAL(1 + 4 + 32 + 2 + 1 + 1 + 5, n);
    TEST_ASSERT_EQUAL_HEX8(0x02, p[0]);
    const uint8_t size_be[] = {0x00, 0x0E, 0x10, 0x00};
    TEST_ASSERT_EQUAL_HEX8_ARRAY(size_be, &p[1], 4);
    TEST_ASSERT_EQUAL_HEX8(0xA0, p[5]);
    TEST_ASSERT_EQUAL_HEX8(0xBF, p[36]);
    TEST_ASSERT_EQUAL_HEX8(0x10, p[37]); /* chunk 4096 */
    TEST_ASSERT_EQUAL_HEX8(0x00, p[38]);
    TEST_ASSERT_EQUAL_HEX8(0x00, p[39]); /* flags */
    TEST_ASSERT_EQUAL_HEX8(5, p[40]);
    TEST_ASSERT_EQUAL_MEMORY("0.2.0", &p[41], 5);

    siot_ota_image_t back;
    TEST_ASSERT_TRUE(siot_ota_push_begin_decode(p, n, &back));
    TEST_ASSERT_EQUAL(SAFR_FAMILY_NODE, back.family);
    TEST_ASSERT_EQUAL_HEX32(0x000E1000, back.size);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(img.sha256, back.sha256, 32);
    TEST_ASSERT_EQUAL(4096, back.chunk);
    TEST_ASSERT_EQUAL_STRING("0.2.0", back.version);

    TEST_ASSERT_FALSE(siot_ota_push_begin_decode(p, n - 1, &back)); /* truncated */
    TEST_ASSERT_FALSE(siot_ota_push_begin_decode(p, n + 1, &back)); /* trailing byte */
    uint8_t q[SAFR_MAX_PAYLOAD];
    memcpy(q, p, n); q[0] = 0x04;                                   /* no such family */
    TEST_ASSERT_FALSE(siot_ota_push_begin_decode(q, n, &back));
    memcpy(q, p, n); memset(&q[1], 0, 4);                           /* size 0 */
    TEST_ASSERT_FALSE(siot_ota_push_begin_decode(q, n, &back));
    memcpy(q, p, n); q[37] = 0x10; q[38] = 0x01;                    /* chunk 4097 */
    TEST_ASSERT_FALSE(siot_ota_push_begin_decode(q, n, &back));
    memcpy(q, p, n); q[37] = 0; q[38] = 0;                          /* chunk 0 */
    TEST_ASSERT_FALSE(siot_ota_push_begin_decode(q, n, &back));
    memcpy(q, p, n); q[40] = 25;                                    /* VER_LEN past the cap */
    TEST_ASSERT_FALSE(siot_ota_push_begin_decode(q, n, &back));
    img.version[0] = '\0';                                          /* no version */
    TEST_ASSERT_FALSE(siot_ota_push_begin_decode(p, siot_ota_push_begin_encode(p, &img), &back));
}

TEST_CASE("ota: OTA_PUSH_CHUNK header and OTA_PUSH_RESULT", "[ota][push]")
{
    const siot_ota_chunk_t c = {.seq = 0x00000102, .len = 4096, .crc32 = 0xCBF43926u};
    uint8_t p[SAFR_MAX_PAYLOAD];
    TEST_ASSERT_EQUAL(SIOT_OTA_CHUNK_HDR_LEN, siot_ota_chunk_encode(p, &c));
    const uint8_t want[] = {0x00, 0x00, 0x01, 0x02, 0x10, 0x00, 0xCB, 0xF4, 0x39, 0x26};
    TEST_ASSERT_EQUAL_HEX8_ARRAY(want, p, sizeof(want));
    siot_ota_chunk_t back;
    TEST_ASSERT_TRUE(siot_ota_chunk_decode(p, 10, &back));
    TEST_ASSERT_EQUAL_HEX32(0x102, back.seq);
    TEST_ASSERT_EQUAL(4096, back.len);
    TEST_ASSERT_EQUAL_HEX32(0xCBF43926u, back.crc32);
    TEST_ASSERT_FALSE(siot_ota_chunk_decode(p, 9, &back));
    TEST_ASSERT_FALSE(siot_ota_chunk_decode(p, 11, &back));
    p[4] = 0x10; p[5] = 0x01; /* 4097 */
    TEST_ASSERT_FALSE(siot_ota_chunk_decode(p, 10, &back));
    p[4] = 0; p[5] = 0;
    TEST_ASSERT_FALSE(siot_ota_chunk_decode(p, 10, &back));

    siot_ota_push_result_t r = {.phase = SIOT_OTA_PUSH_RECEIVING, .reason = SIOT_OTA_R_OUT_OF_ORDER,
                                .family = SAFR_FAMILY_BOARD, .next_seq = 17};
    strcpy(r.version, "0.2.0");
    const size_t n = siot_ota_push_result_encode(p, &r);
    TEST_ASSERT_EQUAL(3 + 4 + 1 + 5, n);
    const uint8_t want_r[] = {0x00, 0x0F, 0x01, 0x00, 0x00, 0x00, 0x11, 0x05};
    TEST_ASSERT_EQUAL_HEX8_ARRAY(want_r, p, sizeof(want_r));
    siot_ota_push_result_t rb;
    TEST_ASSERT_TRUE(siot_ota_push_result_decode(p, n, &rb));
    TEST_ASSERT_EQUAL(17, rb.next_seq);
    TEST_ASSERT_EQUAL(SIOT_OTA_R_OUT_OF_ORDER, rb.reason);
    TEST_ASSERT_EQUAL_STRING("0.2.0", rb.version);
    TEST_ASSERT_FALSE(siot_ota_push_result_decode(p, n - 1, &rb));
    p[0] = 3;
    TEST_ASSERT_FALSE(siot_ota_push_result_decode(p, n, &rb));
}

TEST_CASE("ota: OTA_OFFER args, OTA_STATUS, OTA_RESULT", "[ota][mesh]")
{
    siot_ota_image_t img = {.family = SAFR_FAMILY_LEAF, .size = 856064, .deadline_s = 300,
                            .flags = SIOT_OTA_F_FORCE};
    fill_sha(img.sha256);
    strcpy(img.version, "0.2.0-rc.1");
    uint8_t p[SAFR_MAX_PAYLOAD];
    const size_t n = siot_ota_offer_encode(p, &img);
    TEST_ASSERT_EQUAL(1 + 4 + 32 + 2 + 1 + 1 + 10, n);
    TEST_ASSERT_TRUE(2 + n <= SAFR_MAX_PAYLOAD); /* it rides as COMMAND args */
    TEST_ASSERT_EQUAL_HEX8(0x03, p[0]);
    TEST_ASSERT_EQUAL_HEX8(0x01, p[37]); /* deadline 300 = 0x012C */
    TEST_ASSERT_EQUAL_HEX8(0x2C, p[38]);
    TEST_ASSERT_EQUAL_HEX8(SIOT_OTA_F_FORCE, p[39]);
    siot_ota_image_t back;
    TEST_ASSERT_TRUE(siot_ota_offer_decode(p, n, &back));
    TEST_ASSERT_EQUAL(300, back.deadline_s);
    TEST_ASSERT_EQUAL(856064, back.size);
    TEST_ASSERT_EQUAL_STRING("0.2.0-rc.1", back.version);
    TEST_ASSERT_FALSE(siot_ota_offer_decode(p, n - 1, &back));
    p[0] = 0;
    TEST_ASSERT_FALSE(siot_ota_offer_decode(p, n, &back));

    const siot_ota_status_t s = {.state = SIOT_OTA_U_DOWNLOADING, .percent = 40};
    TEST_ASSERT_EQUAL(2, siot_ota_status_encode(p, &s));
    TEST_ASSERT_EQUAL_HEX8(2, p[0]);
    TEST_ASSERT_EQUAL_HEX8(40, p[1]);
    siot_ota_status_t sb;
    TEST_ASSERT_TRUE(siot_ota_status_decode(p, 2, &sb));
    TEST_ASSERT_EQUAL(40, sb.percent);
    p[1] = 101;
    TEST_ASSERT_FALSE(siot_ota_status_decode(p, 2, &sb));
    p[1] = 0; p[0] = SIOT_OTA_U__COUNT;
    TEST_ASSERT_FALSE(siot_ota_status_decode(p, 2, &sb));
    TEST_ASSERT_FALSE(siot_ota_status_decode(p, 1, &sb));

    siot_ota_result_t r = {.ok = false, .reason = SIOT_OTA_R_SELFTEST_FAIL, .awake_s = 62};
    strcpy(r.version, "0.1.0");
    const size_t m = siot_ota_result_encode(p, &r);
    const uint8_t want[] = {0x00, 0x09, 0x00, 0x3E, 0x05, '0', '.', '1', '.', '0'};
    TEST_ASSERT_EQUAL(sizeof(want), m);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(want, p, sizeof(want));
    siot_ota_result_t rb;
    TEST_ASSERT_TRUE(siot_ota_result_decode(p, m, &rb));
    TEST_ASSERT_FALSE(rb.ok);
    TEST_ASSERT_EQUAL(62, rb.awake_s);
    TEST_ASSERT_EQUAL_STRING("0.1.0", rb.version);
    TEST_ASSERT_EQUAL(0, rb.detail);
    TEST_ASSERT_FALSE(siot_ota_result_decode(p, m + 2, &rb));
    p[0] = 2;
    TEST_ASSERT_FALSE(siot_ota_result_decode(p, m, &rb));

    /* v3.5: an optional DETAIL byte after VERSION — the reset reason with NOT_VALIDATED */
    siot_ota_result_t rd = {.ok = false, .reason = SIOT_OTA_R_NOT_VALIDATED, .awake_s = 0, .detail = 4};
    strcpy(rd.version, "0.1.0");
    const size_t md = siot_ota_result_encode(p, &rd);
    TEST_ASSERT_EQUAL(sizeof(want) + 1, md);
    TEST_ASSERT_EQUAL_HEX8(4, p[md - 1]);
    TEST_ASSERT_TRUE(siot_ota_result_decode(p, md, &rb));
    TEST_ASSERT_EQUAL(SIOT_OTA_R_NOT_VALIDATED, rb.reason);
    TEST_ASSERT_EQUAL(4, rb.detail);
    TEST_ASSERT_EQUAL_STRING("0.1.0", rb.version);
}

TEST_CASE("ota: OTA_CONTROL filters", "[ota][control]")
{
    uint8_t p[SAFR_MAX_PAYLOAD];
    siot_ota_control_t c = {.action = SIOT_OTA_ACT_START, .family = SAFR_FAMILY_NODE,
                            .filter = SIOT_OTA_FILTER_PRODUCT, .product = 0x0201};
    size_t n = siot_ota_control_encode(p, &c);
    const uint8_t want[] = {0x01, 0x02, 0x01, 0x02, 0x01};
    TEST_ASSERT_EQUAL(sizeof(want), n);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(want, p, sizeof(want));
    siot_ota_control_t b;
    TEST_ASSERT_TRUE(siot_ota_control_decode(p, n, &b));
    TEST_ASSERT_EQUAL_HEX16(0x0201, b.product);

    /* "only sirens" with the LEAF image: a product of another family is refused */
    p[1] = SAFR_FAMILY_LEAF;
    TEST_ASSERT_FALSE(siot_ota_control_decode(p, n, &b));
    p[1] = SAFR_FAMILY_NODE;
    p[3] = 0; p[4] = 0;
    TEST_ASSERT_FALSE(siot_ota_control_decode(p, n, &b));

    c = (siot_ota_control_t){.action = SIOT_OTA_ACT_PAUSE, .family = SAFR_FAMILY_NODE, .filter = SIOT_OTA_FILTER_ALL};
    n = siot_ota_control_encode(p, &c);
    TEST_ASSERT_EQUAL(3, n);
    TEST_ASSERT_TRUE(siot_ota_control_decode(p, n, &b));
    TEST_ASSERT_FALSE(siot_ota_control_decode(p, n + 1, &b));
    p[0] = 0;
    TEST_ASSERT_FALSE(siot_ota_control_decode(p, n, &b));
    p[0] = 5;
    TEST_ASSERT_FALSE(siot_ota_control_decode(p, n, &b));

    c = (siot_ota_control_t){.action = SIOT_OTA_ACT_START, .family = SAFR_FAMILY_LEAF, .filter = SIOT_OTA_FILTER_ZONE};
    strcpy(c.zone, "Térreo");
    n = siot_ota_control_encode(p, &c);
    TEST_ASSERT_TRUE(siot_ota_control_decode(p, n, &b));
    TEST_ASSERT_EQUAL_STRING("Térreo", b.zone);
    p[3] = 0; /* empty zone */
    TEST_ASSERT_FALSE(siot_ota_control_decode(p, 4, &b));

    const uint8_t mac[6] = {0x80, 0x45, 0x6B, 0x72, 0xE3, 0x30};
    c = (siot_ota_control_t){.action = SIOT_OTA_ACT_START, .family = SAFR_FAMILY_LEAF, .filter = SIOT_OTA_FILTER_UNIT};
    memcpy(c.mac, mac, 6);
    n = siot_ota_control_encode(p, &c);
    TEST_ASSERT_EQUAL(9, n);
    TEST_ASSERT_TRUE(siot_ota_control_decode(p, n, &b));
    TEST_ASSERT_EQUAL_HEX8_ARRAY(mac, b.mac, 6);
    memset(&p[3], 0xFF, 6); /* broadcast is not a unit */
    TEST_ASSERT_FALSE(siot_ota_control_decode(p, n, &b));
    p[2] = 4;
    TEST_ASSERT_FALSE(siot_ota_control_decode(p, n, &b));
}

TEST_CASE("ota: OTA_ROLLOUT page, header and entries", "[ota][rollout]")
{
    uint8_t p[SAFR_MAX_PAYLOAD];
    siot_ota_rollout_hdr_t h = {.page = 1, .page_count = 2, .total = 9, .count = 2,
                                .state = SIOT_OTA_RO_ROLLING, .family = SAFR_FAMILY_NODE};
    strcpy(h.target, "0.2.0");
    size_t off = siot_ota_rollout_hdr_encode(p, &h);
    const uint8_t want_h[] = {0x01, 0x02, 0x00, 0x09, 0x02, 0x02, 0x02, 0x05, '0', '.', '2', '.', '0'};
    TEST_ASSERT_EQUAL(sizeof(want_h), off);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(want_h, p, sizeof(want_h));

    siot_ota_rollout_entry_t e1 = {.mac = {0x80, 0x45, 0x6B, 0x74, 0x23, 0x20}, .product = 0x0201,
                                   .state = SIOT_OTA_U_DOWNLOADING, .percent = 40, .attempts = 1,
                                   .reason = SIOT_OTA_R_NONE, .age_s = 3};
    strcpy(e1.version, "0.1.0");
    siot_ota_rollout_entry_t e2 = {.mac = {0x7C, 0x4F, 0xAD, 0xAE, 0x85, 0x90}, .product = 0x0202,
                                   .state = SIOT_OTA_U_WAITING, .age_s = 0xFFFF};
    const size_t l1 = siot_ota_rollout_entry_len(&e1);
    TEST_ASSERT_EQUAL(14 + 1 + 5, l1);
    TEST_ASSERT_EQUAL(l1, siot_ota_rollout_entry_encode(&p[off], &e1));
    const uint8_t want_e[] = {0x80, 0x45, 0x6B, 0x74, 0x23, 0x20, 0x02, 0x01, 0x02, 40, 1, 0, 0x00, 0x03, 5};
    TEST_ASSERT_EQUAL_HEX8_ARRAY(want_e, &p[off], sizeof(want_e));
    off += l1;
    off += siot_ota_rollout_entry_encode(&p[off], &e2);

    siot_ota_rollout_hdr_t hb;
    size_t r = siot_ota_rollout_hdr_decode(p, off, &hb);
    TEST_ASSERT_EQUAL(sizeof(want_h), r);
    TEST_ASSERT_EQUAL(9, hb.total);
    TEST_ASSERT_EQUAL(2, hb.count);
    TEST_ASSERT_EQUAL_STRING("0.2.0", hb.target);
    siot_ota_rollout_entry_t b;
    size_t used = siot_ota_rollout_entry_decode(&p[r], off - r, &b);
    TEST_ASSERT_EQUAL(l1, used);
    TEST_ASSERT_EQUAL_HEX16(0x0201, b.product);
    TEST_ASSERT_EQUAL(40, b.percent);
    TEST_ASSERT_EQUAL_STRING("0.1.0", b.version);
    r += used;
    used = siot_ota_rollout_entry_decode(&p[r], off - r, &b);
    TEST_ASSERT_EQUAL(15, used); /* no version known yet */
    TEST_ASSERT_EQUAL_HEX16(0xFFFF, b.age_s);
    TEST_ASSERT_EQUAL_STRING("", b.version);
    TEST_ASSERT_EQUAL(off, r + used);

    TEST_ASSERT_EQUAL(0, siot_ota_rollout_entry_decode(&p[r], used - 1, &b));
    p[0] = 3; /* page 3 of 2 */
    TEST_ASSERT_EQUAL(0, siot_ota_rollout_hdr_decode(p, off, &hb));
    p[0] = 1; p[5] = SIOT_OTA_RO__COUNT;
    TEST_ASSERT_EQUAL(0, siot_ota_rollout_hdr_decode(p, off, &hb));

    /* the worst entry still leaves room for several per page */
    siot_ota_rollout_entry_t big = {0};
    memset(big.version, '9', SIOT_OTA_VER_MAX_LEN);
    TEST_ASSERT_EQUAL(39, siot_ota_rollout_entry_len(&big));
    TEST_ASSERT_TRUE((SAFR_MAX_PAYLOAD - (7 + 1 + SIOT_OTA_VER_MAX_LEN)) / 39 >= 4);
}

TEST_CASE("ota: the rollout's next unit, deepest first, the root last", "[ota][rollout]")
{
    /* root (1) ─ siren (2) ─ button (3); a second node at 2 not heard yet */
    siot_ota_pick_t u[4] = {
        {.waiting = true, .is_root = true, .layer = 1},
        {.waiting = true, .layer = 2},
        {.waiting = true, .layer = 3},
        {.waiting = true, .layer = 0},
    };
    TEST_ASSERT_EQUAL(2, siot_ota_pick_next(u, 4)); /* the deepest */
    u[2].waiting = false;
    TEST_ASSERT_EQUAL(1, siot_ota_pick_next(u, 4)); /* a known layer 2 before an unknown one */
    u[1].waiting = false;
    TEST_ASSERT_EQUAL(3, siot_ota_pick_next(u, 4)); /* unknown: still before the root */
    u[3].waiting = false;
    TEST_ASSERT_EQUAL(0, siot_ota_pick_next(u, 4)); /* the root, last */
    u[0].waiting = false;
    TEST_ASSERT_EQUAL(-1, siot_ota_pick_next(u, 4));

    /* the board does not know the root yet: LAYER 1 is the root all the same */
    siot_ota_pick_t fresh[3] = {
        {.waiting = true, .layer = 1},
        {.waiting = true, .layer = 0},
        {.waiting = true, .layer = 2},
    };
    TEST_ASSERT_EQUAL(2, siot_ota_pick_next(fresh, 3));
    fresh[2].waiting = false;
    TEST_ASSERT_EQUAL(1, siot_ota_pick_next(fresh, 3));
    /* nothing known about anybody: table order, never a unit marked root first */
    siot_ota_pick_t blind[2] = {{.waiting = true}, {.waiting = true}};
    TEST_ASSERT_EQUAL(0, siot_ota_pick_next(blind, 2));

    /* a unit that failed once goes after the fresh ones, still before the root */
    siot_ota_pick_t retry[3] = {
        {.waiting = true, .layer = 3, .attempts = 1},
        {.waiting = true, .layer = 2},
        {.waiting = true, .is_root = true, .layer = 1},
    };
    TEST_ASSERT_EQUAL(1, siot_ota_pick_next(retry, 3));
    retry[1].waiting = false;
    TEST_ASSERT_EQUAL(0, siot_ota_pick_next(retry, 3));
}
