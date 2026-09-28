/* Protocol §12 pure pieces (siot_leaf_proto): the 9-byte leaf ACK (§12.4),
 * parent selection (§12.3), the outbox ring (§12.6) and the probe policy. */
#include <string.h>

#include "unity.h"

#include "siot_leaf_proto.h"
#include "siot_safr.h"

TEST_CASE("leaf ack: 4-byte §7.5 form parses with no extension", "[leaf][ack]")
{
    const uint8_t p[4] = {0x12, 0x34, SAFR_ACK_OK, 0x00};
    siot_leaf_ack_t a;
    TEST_ASSERT_TRUE(siot_leaf_ack_parse(p, sizeof(p), &a));
    TEST_ASSERT_EQUAL_HEX16(0x1234, a.acked_msg_id);
    TEST_ASSERT_EQUAL(SAFR_ACK_OK, a.code);
    TEST_ASSERT_FALSE(a.pending);
    TEST_ASSERT_FALSE(a.no_path);
    TEST_ASSERT_FALSE(a.has_ext);
    TEST_ASSERT_EQUAL(0, a.epoch);
    TEST_ASSERT_EQUAL(0, a.channel);
}

TEST_CASE("leaf ack: build → parse round trip keeps flags, count, epoch, channel", "[leaf][ack]")
{
    uint8_t p[SIOT_LEAF_ACK_EXT_LEN];
    TEST_ASSERT_EQUAL(9, siot_leaf_ack_build(p, 0xBEEF, SAFR_ACK_OK, 3, true, 1759000000u, 11));
    TEST_ASSERT_EQUAL_HEX8(0xBE, p[0]);
    TEST_ASSERT_EQUAL_HEX8(0xEF, p[1]);
    TEST_ASSERT_EQUAL_HEX8(SAFR_ACK_OK | SAFR_ACK_F_PENDING | SAFR_ACK_F_NO_PATH, p[2]);
    TEST_ASSERT_EQUAL_HEX8(3, p[3]);
    TEST_ASSERT_EQUAL_HEX8(11, p[8]);

    siot_leaf_ack_t a;
    TEST_ASSERT_TRUE(siot_leaf_ack_parse(p, sizeof(p), &a));
    TEST_ASSERT_EQUAL_HEX16(0xBEEF, a.acked_msg_id);
    TEST_ASSERT_EQUAL(SAFR_ACK_OK, a.code);
    TEST_ASSERT_TRUE(a.pending);
    TEST_ASSERT_TRUE(a.no_path);
    TEST_ASSERT_EQUAL(3, a.detail);
    TEST_ASSERT_TRUE(a.has_ext);
    TEST_ASSERT_EQUAL_UINT32(1759000000u, a.epoch);
    TEST_ASSERT_EQUAL(11, a.channel);
}

TEST_CASE("leaf ack: ERROR code survives the flag bits; odd lengths rejected", "[leaf][ack]")
{
    uint8_t p[SIOT_LEAF_ACK_EXT_LEN];
    siot_leaf_ack_build(p, 7, SAFR_ACK_ERROR, 0, false, 0, 6);
    siot_leaf_ack_t a;
    TEST_ASSERT_TRUE(siot_leaf_ack_parse(p, 9, &a));
    TEST_ASSERT_EQUAL(SAFR_ACK_ERROR, a.code);
    TEST_ASSERT_FALSE(a.pending);
    TEST_ASSERT_EQUAL(0, a.epoch); /* no clock */
    TEST_ASSERT_FALSE(siot_leaf_ack_parse(p, 5, &a));
    TEST_ASSERT_FALSE(siot_leaf_ack_parse(p, 8, &a));
    TEST_ASSERT_FALSE(siot_leaf_ack_parse(p, 0, &a));
}

static siot_leaf_candidate_t cand(int8_t link, uint8_t layer)
{
    siot_leaf_candidate_t c;
    memset(&c, 0, sizeof(c));
    c.link = link;
    c.layer = layer;
    return c;
}

TEST_CASE("leaf pick: best link wins, lower layer breaks ties, off-mesh never beats on-mesh", "[leaf][bind]")
{
    TEST_ASSERT_EQUAL(-1, siot_leaf_pick_parent(NULL, 0));

    siot_leaf_candidate_t c[4];
    c[0] = cand(-80, 1);
    c[1] = cand(-70, 3);
    c[2] = cand(-70, 2);   /* same link as [1], shallower → wins */
    c[3] = cand(-40, 0xFF); /* strongest, but not on a mesh */
    TEST_ASSERT_EQUAL(2, siot_leaf_pick_parent(c, 4));

    /* Nothing reaches −85: still bind to the best available (§12.3). */
    siot_leaf_candidate_t w[2] = {cand(-92, 2), cand(-89, 3)};
    TEST_ASSERT_EQUAL(1, siot_leaf_pick_parent(w, 2));

    /* Only off-mesh answers: take the best of them. */
    siot_leaf_candidate_t o[2] = {cand(-60, 0xFF), cand(-50, 0xFF)};
    TEST_ASSERT_EQUAL(1, siot_leaf_pick_parent(o, 2));

    TEST_ASSERT_EQUAL(-83, siot_leaf_link(-83, -70));
    TEST_ASSERT_EQUAL(-83, siot_leaf_link(-70, -83));
}

static void ev(uint8_t out[17], uint8_t type, uint16_t seq)
{
    memset(out, 0, 17);
    out[0] = type;
    out[15] = (uint8_t)(seq >> 8);
    out[16] = (uint8_t)seq;
}

TEST_CASE("leaf outbox: FIFO, oldest first, count", "[leaf][outbox]")
{
    siot_leaf_outbox_t o;
    siot_leaf_outbox_init(&o);
    uint8_t p[17], got[17];
    TEST_ASSERT_EQUAL(0, siot_leaf_outbox_count(&o));
    TEST_ASSERT_FALSE(siot_leaf_outbox_peek(&o, got));
    ev(p, SAFR_EVT_TROUBLE, 1); TEST_ASSERT_FALSE(siot_leaf_outbox_push(&o, p));
    ev(p, SAFR_EVT_OK, 2);      TEST_ASSERT_FALSE(siot_leaf_outbox_push(&o, p));
    TEST_ASSERT_EQUAL(2, siot_leaf_outbox_count(&o));
    TEST_ASSERT_TRUE(siot_leaf_outbox_peek(&o, got));
    TEST_ASSERT_EQUAL(1, (got[15] << 8) | got[16]);
    siot_leaf_outbox_pop(&o);
    TEST_ASSERT_TRUE(siot_leaf_outbox_peek(&o, got));
    TEST_ASSERT_EQUAL(2, (got[15] << 8) | got[16]);
    siot_leaf_outbox_pop(&o);
    TEST_ASSERT_EQUAL(0, siot_leaf_outbox_count(&o));
    siot_leaf_outbox_pop(&o); /* harmless when empty */
}

TEST_CASE("leaf outbox: full → drops the oldest non-ALARM, keeps every ALARM", "[leaf][outbox]")
{
    siot_leaf_outbox_t o;
    siot_leaf_outbox_init(&o);
    uint8_t p[17], got[17];
    ev(p, SAFR_EVT_ALARM, 1);   siot_leaf_outbox_push(&o, p); /* oldest, an alarm */
    ev(p, SAFR_EVT_TROUBLE, 2); siot_leaf_outbox_push(&o, p); /* the victim */
    for (uint16_t s = 3; s <= SIOT_LEAF_OUTBOX_CAP; s++) { ev(p, SAFR_EVT_OK, s); siot_leaf_outbox_push(&o, p); }
    TEST_ASSERT_EQUAL(SIOT_LEAF_OUTBOX_CAP, siot_leaf_outbox_count(&o));

    ev(p, SAFR_EVT_OK, 99);
    TEST_ASSERT_TRUE(siot_leaf_outbox_push(&o, p)); /* dropped seq 2 */
    TEST_ASSERT_EQUAL(SIOT_LEAF_OUTBOX_CAP, siot_leaf_outbox_count(&o));
    TEST_ASSERT_TRUE(siot_leaf_outbox_peek(&o, got));
    TEST_ASSERT_EQUAL(SAFR_EVT_ALARM, got[0]);
    TEST_ASSERT_EQUAL(1, (got[15] << 8) | got[16]);
    siot_leaf_outbox_pop(&o);
    TEST_ASSERT_TRUE(siot_leaf_outbox_peek(&o, got));
    TEST_ASSERT_EQUAL(3, (got[15] << 8) | got[16]); /* 2 is gone, order kept */
    /* The newest is last. */
    while (siot_leaf_outbox_count(&o) > 1) siot_leaf_outbox_pop(&o);
    TEST_ASSERT_TRUE(siot_leaf_outbox_peek(&o, got));
    TEST_ASSERT_EQUAL(99, (got[15] << 8) | got[16]);

    /* All alarms: the oldest alarm goes. */
    siot_leaf_outbox_init(&o);
    for (uint16_t s = 1; s <= SIOT_LEAF_OUTBOX_CAP; s++) { ev(p, SAFR_EVT_ALARM, s); siot_leaf_outbox_push(&o, p); }
    ev(p, SAFR_EVT_ALARM, 77);
    TEST_ASSERT_TRUE(siot_leaf_outbox_push(&o, p));
    TEST_ASSERT_TRUE(siot_leaf_outbox_peek(&o, got));
    TEST_ASSERT_EQUAL(2, (got[15] << 8) | got[16]);
}

TEST_CASE("leaf policy: probe on the 2nd miss; unbound every wake / every 5th; budget", "[leaf][policy]")
{
    TEST_ASSERT_FALSE(siot_leaf_probe_after_misses(0));
    TEST_ASSERT_FALSE(siot_leaf_probe_after_misses(1));
    TEST_ASSERT_TRUE(siot_leaf_probe_after_misses(2));
    TEST_ASSERT_TRUE(siot_leaf_probe_due_unbound(0, true));
    TEST_ASSERT_FALSE(siot_leaf_probe_due_unbound(4, false));
    TEST_ASSERT_TRUE(siot_leaf_probe_due_unbound(5, false));
    TEST_ASSERT_EQUAL(500, siot_leaf_budget_left_ms(0, 500));
    TEST_ASSERT_EQUAL(120, siot_leaf_budget_left_ms(380, 500));
    TEST_ASSERT_EQUAL(0, siot_leaf_budget_left_ms(500, 500));
    TEST_ASSERT_EQUAL(0, siot_leaf_budget_left_ms(900, 500));
}

TEST_CASE("leaf rx check: new / dup (same MSG_ID) / replay (same boot, counter not newer)", "[leaf][parent]")
{
    siot_leaf_rx_state_t st = {0};
    TEST_ASSERT_EQUAL(SIOT_LEAF_RX_NEW, siot_leaf_rx_check(&st, 7, 1, 100));
    TEST_ASSERT_EQUAL(SIOT_LEAF_RX_DUP, siot_leaf_rx_check(&st, 7, 2, 100));    /* fast retry: fresh ctr, same id */
    TEST_ASSERT_EQUAL(SIOT_LEAF_RX_REPLAY, siot_leaf_rx_check(&st, 7, 2, 100)); /* identical again */
    TEST_ASSERT_EQUAL(SIOT_LEAF_RX_REPLAY, siot_leaf_rx_check(&st, 7, 1, 101)); /* older counter */
    TEST_ASSERT_EQUAL(SIOT_LEAF_RX_NEW, siot_leaf_rx_check(&st, 7, 3, 101));
    TEST_ASSERT_EQUAL(SIOT_LEAF_RX_NEW, siot_leaf_rx_check(&st, 8, 1, 101));    /* new boot: counters restart, id may repeat */
}

static const uint8_t F1[10] = {0xA5, 3, 0, 10, SAFR_MSG_COMMAND, 0, 1, 0, 0, 0};

TEST_CASE("leaf mailbox: same CMD replaces, full drops oldest, ack clears, ttl expires", "[leaf][parent]")
{
    siot_leaf_mailbox_t m;
    siot_leaf_mailbox_init(&m);
    TEST_ASSERT_EQUAL(0, siot_leaf_mailbox_count(&m));
    TEST_ASSERT_FALSE(siot_leaf_mailbox_push(&m, F1, sizeof(F1), SAFR_CMD_IDENTIFY, 10, 1000));
    TEST_ASSERT_TRUE(siot_leaf_mailbox_push(&m, F1, sizeof(F1), SAFR_CMD_IDENTIFY, 11, 2000)); /* replaced */
    TEST_ASSERT_EQUAL(1, siot_leaf_mailbox_count(&m));
    TEST_ASSERT_EQUAL(11, siot_leaf_mailbox_oldest(&m)->msg_id);
    TEST_ASSERT_FALSE(siot_leaf_mailbox_push(&m, F1, sizeof(F1), SIOT_LEAF_NOT_A_COMMAND, 20, 3000)); /* an ACK: never replaces */
    TEST_ASSERT_FALSE(siot_leaf_mailbox_push(&m, F1, sizeof(F1), SIOT_LEAF_NOT_A_COMMAND, 21, 4000));
    TEST_ASSERT_FALSE(siot_leaf_mailbox_push(&m, F1, sizeof(F1), SAFR_CMD_RESET, 30, 5000));
    TEST_ASSERT_EQUAL(4, siot_leaf_mailbox_count(&m));
    TEST_ASSERT_TRUE(siot_leaf_mailbox_push(&m, F1, sizeof(F1), SAFR_CMD_TEST, 40, 6000)); /* full: 11 (oldest) dropped */
    TEST_ASSERT_EQUAL(4, siot_leaf_mailbox_count(&m));
    TEST_ASSERT_EQUAL(20, siot_leaf_mailbox_oldest(&m)->msg_id);
    TEST_ASSERT_TRUE(siot_leaf_mailbox_ack(&m, 21));
    TEST_ASSERT_FALSE(siot_leaf_mailbox_ack(&m, 21));
    TEST_ASSERT_EQUAL(3, siot_leaf_mailbox_count(&m));
    TEST_ASSERT_EQUAL(1, siot_leaf_mailbox_expire(&m, 3000 + SIOT_LEAF_MAILBOX_TTL_MS + 1)); /* 20 expired */
    TEST_ASSERT_EQUAL(2, siot_leaf_mailbox_count(&m));
    siot_leaf_mailbox_remove(&m, siot_leaf_mailbox_oldest(&m));
    TEST_ASSERT_EQUAL(1, siot_leaf_mailbox_count(&m));
}

TEST_CASE("leaf custody: 3 fast retries, alarm slow for ever, others released; ack clears", "[leaf][parent]")
{
    static const uint8_t L[6] = {1, 2, 3, 4, 5, 6};
    siot_leaf_custody_t c;
    siot_leaf_custody_init(&c);
    TEST_ASSERT_TRUE(siot_leaf_custody_add(&c, L, 5, false, F1, sizeof(F1), 0));
    TEST_ASSERT_TRUE(siot_leaf_custody_add(&c, L, 6, true, F1, sizeof(F1), 0));
    TEST_ASSERT_EQUAL(2, siot_leaf_custody_count(&c));
    TEST_ASSERT_NULL(siot_leaf_custody_due(&c, 1999));
    /* trouble (msg 5): forward + 2 fast retries = 3 sends, then released */
    siot_leaf_custody_entry_t *e;
    int64_t t = 2000;
    int released = 0;
    for (int i = 0; i < 6; i++) {
        e = siot_leaf_custody_due(&c, t);
        if (e == NULL) break;
        if (siot_leaf_custody_sent(&c, e, t)) released++;
        t += 2000;
    }
    TEST_ASSERT_EQUAL(1, released);          /* the trouble gave up */
    TEST_ASSERT_EQUAL(1, siot_leaf_custody_count(&c)); /* the alarm stays */
    e = siot_leaf_custody_due(&c, t + SIOT_LEAF_CUSTODY_SLOW_MS);
    TEST_ASSERT_NOT_NULL(e);
    TEST_ASSERT_EQUAL(6, e->msg_id);
    TEST_ASSERT_TRUE(e->alarm);
    TEST_ASSERT_FALSE(siot_leaf_custody_sent(&c, e, t + SIOT_LEAF_CUSTODY_SLOW_MS)); /* never released */
    TEST_ASSERT_FALSE(siot_leaf_custody_ack(&c, L, 5));
    TEST_ASSERT_TRUE(siot_leaf_custody_ack(&c, L, 6));
    TEST_ASSERT_EQUAL(0, siot_leaf_custody_count(&c));
    /* full of alarms: the oldest alarm is the victim */
    for (uint16_t i = 0; i < SIOT_LEAF_CUSTODY_CAP; i++) TEST_ASSERT_TRUE(siot_leaf_custody_add(&c, L, i, true, F1, sizeof(F1), i));
    TEST_ASSERT_TRUE(siot_leaf_custody_add(&c, L, 99, false, F1, sizeof(F1), 1000));
    TEST_ASSERT_FALSE(siot_leaf_custody_ack(&c, L, 0));
    TEST_ASSERT_TRUE(siot_leaf_custody_ack(&c, L, 99));
}
