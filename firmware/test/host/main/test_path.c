/* The best path (blueprint §4, protocol §7.16 PATH_ADVERT): a unit under a
 * parent with a weak path moves to a unit that offers a clearly better one —
 * by the weakest link of the whole path, not by the signal of one hop. */
#include <string.h>

#include "unity.h"

#include "siot_link_path.h"

static const uint8_t ME[6]   = {0x52, 0, 0, 0, 0, 0x01};
static const uint8_t ROOT[6] = {0x52, 0, 0, 0, 0, 0x10};
static const uint8_t X[6]    = {0x52, 0, 0, 0, 0, 0x20};
static const uint8_t Y[6]    = {0x52, 0, 0, 0, 0, 0x30};

static siot_path_table_t t;
static uint32_t s_ctr;

static siot_path_advert_t advert(const uint8_t ap[6], uint8_t level, int8_t path, const uint8_t *chain, uint8_t chain_n)
{
    siot_path_advert_t a;
    memset(&a, 0, sizeof(a));
    memcpy(a.ap, ap, 6);
    a.level = level;
    a.path = path;
    a.complete = true;
    a.chain_n = chain_n;
    for (uint8_t i = 0; i < chain_n; i++) memcpy(a.chain[i], &chain[6 * i], 6);
    return a;
}

/* `n` adverts 10 s apart, the last one at `*now`. */
static void hear(int64_t *now, int n, const siot_path_advert_t *a, int8_t rssi)
{
    for (int i = 0; i < n; i++) {
        *now += SIOT_PATH_ADVERT_MS;
        TEST_ASSERT_TRUE(siot_path_heard(&t, *now, a->ap, 1, ++s_ctr, rssi, a));
    }
}

static void start(void)
{
    siot_path_init(&t, ME);
    s_ctr = 0;
}

TEST_CASE("path advert: what is written is what is read", "[link][path]")
{
    const uint8_t chain[12] = {0x52, 0, 0, 0, 0, 0x20, 0x52, 0, 0, 0, 0, 0x10};
    siot_path_advert_t a = advert(ME, 3, -71, chain, 2), b;
    a.full = true;
    uint8_t buf[SIOT_PATH_ADVERT_MAX_LEN];
    const size_t n = siot_path_advert_encode(&a, buf, sizeof(buf));
    TEST_ASSERT_EQUAL(SIOT_PATH_ADVERT_MIN_LEN + 12, n);
    TEST_ASSERT_TRUE(siot_path_advert_decode(buf, n, &b));
    TEST_ASSERT_EQUAL(3, b.level);
    TEST_ASSERT_EQUAL(-71, b.path);
    TEST_ASSERT_TRUE(b.complete);
    TEST_ASSERT_TRUE(b.full);
    TEST_ASSERT_EQUAL(2, b.chain_n);
    TEST_ASSERT_EQUAL_MEMORY(ME, b.ap, 6);
    TEST_ASSERT_EQUAL_MEMORY(ROOT, b.chain[1], 6);
    /* Cut, another version, too small a buffer. */
    TEST_ASSERT_FALSE(siot_path_advert_decode(buf, n - 1, &b));
    buf[0] = 2;
    TEST_ASSERT_FALSE(siot_path_advert_decode(buf, n, &b));
    TEST_ASSERT_EQUAL(0, siot_path_advert_encode(&a, buf, n - 1));
}

TEST_CASE("path: the unit at -85 on the root moves under a unit with a good path", "[link][path]")
{
    /* The building of 2026-11-16: this unit hangs from the root at -85; another
     * unit, on the root at -40, is heard here at -60. */
    start();
    int64_t now = 0;
    siot_path_set_parent(&t, ROOT);
    siot_path_link_sample(&t, -85);
    const siot_path_advert_t root = advert(ROOT, 1, SIOT_PATH_ROOT_DBM, NULL, 0);
    const siot_path_advert_t y = advert(Y, 2, -40, ROOT, 1);
    hear(&now, 3, &root, -85);
    hear(&now, 3, &y, -60);

    siot_path_choice_t c;
    TEST_ASSERT_TRUE(siot_path_best(&t, now, &c));
    TEST_ASSERT_EQUAL(-85, c.path_now);
    TEST_ASSERT_EQUAL(-60, c.path_new); /* the weaker of -60 (heard) and -40 (said) */
    TEST_ASSERT_EQUAL_MEMORY(Y, c.ap, 6);

    /* Better now is not enough: it must stay so. */
    TEST_ASSERT_FALSE(siot_path_evaluate(&t, now, SIOT_PATH_SUSTAIN_MS, &c));
    for (int i = 0; i < SIOT_PATH_SUSTAIN_MS / SIOT_PATH_ADVERT_MS - 1; i++) {
        hear(&now, 1, &root, -85);
        TEST_ASSERT_TRUE(siot_path_heard(&t, now, Y, 1, ++s_ctr, -60, &y));
        TEST_ASSERT_FALSE(siot_path_evaluate(&t, now, SIOT_PATH_SUSTAIN_MS, &c));
    }
    hear(&now, 1, &root, -85);
    TEST_ASSERT_TRUE(siot_path_heard(&t, now, Y, 1, ++s_ctr, -60, &y));
    TEST_ASSERT_TRUE(siot_path_evaluate(&t, now, SIOT_PATH_SUSTAIN_MS, &c));
    TEST_ASSERT_EQUAL_MEMORY(Y, c.ap, 6);
    TEST_ASSERT_EQUAL(2, c.level);
}

TEST_CASE("path: a strong hop to a parent with a weak path is a weak path", "[link][path]")
{
    /* This unit hears its parent X at -50, but X hangs from the root at -85:
     * its path is -85, and the root heard here at -65 is the better parent. */
    start();
    int64_t now = 0;
    siot_path_set_parent(&t, X);
    siot_path_link_sample(&t, -50);
    const siot_path_advert_t root = advert(ROOT, 1, SIOT_PATH_ROOT_DBM, NULL, 0);
    const siot_path_advert_t x = advert(X, 2, -85, ROOT, 1);
    hear(&now, 3, &x, -50);
    hear(&now, 3, &root, -65);

    siot_path_choice_t c;
    TEST_ASSERT_TRUE(siot_path_best(&t, now, &c));
    TEST_ASSERT_EQUAL(-85, c.path_now);
    TEST_ASSERT_EQUAL(-65, c.path_new);
    TEST_ASSERT_EQUAL_MEMORY(ROOT, c.ap, 6);
    TEST_ASSERT_FALSE(siot_path_evaluate(&t, now, 0, &c) && c.level != 1);

    /* What this unit says of itself: X above it, then the root; path -85. */
    siot_path_advert_t own;
    siot_path_own(&t, now, 3, false, false, false, &own);
    TEST_ASSERT_TRUE(own.complete);
    TEST_ASSERT_EQUAL(-85, own.path);
    TEST_ASSERT_EQUAL(2, own.chain_n);
    TEST_ASSERT_EQUAL_MEMORY(X, own.chain[0], 6);
    TEST_ASSERT_EQUAL_MEMORY(ROOT, own.chain[1], 6);
}

TEST_CASE("path: never under a unit that hangs from this one", "[link][path]")
{
    /* On the root at -85. X is heard at -50 with a "path" of -50 — but X is
     * this unit's own child: its path goes through here. */
    start();
    int64_t now = 0;
    siot_path_set_parent(&t, ROOT);
    siot_path_link_sample(&t, -85);
    const uint8_t chain[12] = {0x52, 0, 0, 0, 0, 0x01, 0x52, 0, 0, 0, 0, 0x10}; /* ME, ROOT */
    const siot_path_advert_t root = advert(ROOT, 1, SIOT_PATH_ROOT_DBM, NULL, 0);
    const siot_path_advert_t child = advert(X, 3, -85, chain, 2);
    hear(&now, 3, &root, -85);
    hear(&now, 3, &child, -50);
    siot_path_choice_t c;
    TEST_ASSERT_FALSE(siot_path_best(&t, now, &c));

    /* The child found the root by itself (-60): now it is a parent like any other. */
    const siot_path_advert_t moved = advert(X, 2, -60, ROOT, 1);
    hear(&now, 1, &root, -85);
    hear(&now, 1, &moved, -50);
    TEST_ASSERT_TRUE(siot_path_best(&t, now, &c));
    TEST_ASSERT_EQUAL_MEMORY(X, c.ap, 6);
    TEST_ASSERT_EQUAL(-60, c.path_new);
}

TEST_CASE("path: a path that works is left alone, and so is a small gain", "[link][path]")
{
    start();
    int64_t now = 0;
    siot_path_set_parent(&t, ROOT);
    const siot_path_advert_t root = advert(ROOT, 1, SIOT_PATH_ROOT_DBM, NULL, 0);
    const siot_path_advert_t y = advert(Y, 2, -40, ROOT, 1);
    siot_path_choice_t c;

    /* -75 is good: -40 next door changes nothing. */
    siot_path_link_sample(&t, SIOT_PATH_GOOD_DBM);
    hear(&now, 3, &root, -75);
    hear(&now, 3, &y, -40);
    TEST_ASSERT_FALSE(siot_path_evaluate(&t, now, 0, &c));

    /* -85 against -76: 9 dB, one short. */
    start();
    now = 0;
    siot_path_set_parent(&t, ROOT);
    siot_path_link_sample(&t, -85);
    hear(&now, 3, &root, -85);
    hear(&now, 3, &y, -76);
    TEST_ASSERT_TRUE(siot_path_best(&t, now, &c));
    TEST_ASSERT_EQUAL(-76, c.path_new);
    TEST_ASSERT_FALSE(siot_path_evaluate(&t, now, 0, &c));
    /* One dB more and it is enough. */
    start();
    now = 0;
    siot_path_set_parent(&t, ROOT);
    siot_path_link_sample(&t, -85);
    hear(&now, 3, &root, -85);
    hear(&now, 3, &y, -75);
    TEST_ASSERT_TRUE(siot_path_evaluate(&t, now, 0, &c));
}

TEST_CASE("path: only a neighbour that is fresh, complete, with room and not refused", "[link][path]")
{
    start();
    int64_t now = 0;
    siot_path_set_parent(&t, ROOT);
    siot_path_link_sample(&t, -88);
    const siot_path_advert_t root = advert(ROOT, 1, SIOT_PATH_ROOT_DBM, NULL, 0);
    siot_path_advert_t y = advert(Y, 2, -40, ROOT, 1);
    siot_path_choice_t c;

    /* Heard twice only. */
    hear(&now, 3, &root, -88);
    hear(&now, 2, &y, -60);
    TEST_ASSERT_FALSE(siot_path_best(&t, now, &c));
    hear(&now, 1, &y, -60);
    TEST_ASSERT_TRUE(siot_path_best(&t, now, &c));

    /* It does not know its own path up to the root. */
    y.complete = false;
    hear(&now, 1, &y, -60);
    TEST_ASSERT_FALSE(siot_path_best(&t, now, &c));
    y.complete = true;

    /* Its access point is full. */
    y.full = true;
    hear(&now, 1, &y, -60);
    TEST_ASSERT_FALSE(siot_path_best(&t, now, &c));
    y.full = false;
    hear(&now, 1, &y, -60);
    TEST_ASSERT_TRUE(siot_path_best(&t, now, &c));

    /* A replayed frame changes nothing. */
    TEST_ASSERT_FALSE(siot_path_heard(&t, now, Y, 1, s_ctr, -20, &y));

    /* It refused us: not again for half an hour. */
    siot_path_mark_bad(&t, now, Y);
    TEST_ASSERT_FALSE(siot_path_best(&t, now, &c));
    now += SIOT_PATH_BAD_MS - SIOT_PATH_ADVERT_MS;
    hear(&now, 1, &y, -60); /* the gap was long: it starts over, heard once */
    hear(&now, 2, &y, -60);
    TEST_ASSERT_TRUE(siot_path_best(&t, now, &c));

    /* Silent for more than SIOT_PATH_FRESH_MS. */
    now += SIOT_PATH_FRESH_MS + 1;
    TEST_ASSERT_FALSE(siot_path_best(&t, now, &c));
}

TEST_CASE("path: the root says a path of its own only with the board behind it", "[link][path]")
{
    start();
    siot_path_advert_t own;
    siot_path_own(&t, 0, 1, true, true, false, &own);
    TEST_ASSERT_TRUE(own.complete);
    TEST_ASSERT_EQUAL(SIOT_PATH_ROOT_DBM, own.path);
    TEST_ASSERT_EQUAL(0, own.chain_n);
    siot_path_own(&t, 0, 1, true, false, false, &own);
    TEST_ASSERT_FALSE(own.complete);

    /* A child whose parent says nothing: its parent is all it knows. */
    siot_path_set_parent(&t, X);
    siot_path_link_sample(&t, -62);
    siot_path_own(&t, 0, 2, false, false, false, &own);
    TEST_ASSERT_FALSE(own.complete);
    TEST_ASSERT_EQUAL(-62, own.path);
    TEST_ASSERT_EQUAL(1, own.chain_n);
    TEST_ASSERT_EQUAL_MEMORY(X, own.chain[0], 6);
}
