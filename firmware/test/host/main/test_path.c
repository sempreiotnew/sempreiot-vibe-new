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
    TEST_ASSERT_FALSE(siot_path_evaluate(&t, now, SIOT_PATH_SUSTAIN_MS, SIOT_PATH_GAIN_DB, &c));
    for (int i = 0; i < SIOT_PATH_SUSTAIN_MS / SIOT_PATH_ADVERT_MS - 1; i++) {
        hear(&now, 1, &root, -85);
        TEST_ASSERT_TRUE(siot_path_heard(&t, now, Y, 1, ++s_ctr, -60, &y));
        TEST_ASSERT_FALSE(siot_path_evaluate(&t, now, SIOT_PATH_SUSTAIN_MS, SIOT_PATH_GAIN_DB, &c));
    }
    hear(&now, 1, &root, -85);
    TEST_ASSERT_TRUE(siot_path_heard(&t, now, Y, 1, ++s_ctr, -60, &y));
    TEST_ASSERT_TRUE(siot_path_evaluate(&t, now, SIOT_PATH_SUSTAIN_MS, SIOT_PATH_GAIN_DB, &c));
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
    TEST_ASSERT_FALSE(siot_path_evaluate(&t, now, 0, SIOT_PATH_GAIN_DB, &c) && c.level != 1);

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

    /* -80 is not below -80: -40 next door changes nothing. */
    TEST_ASSERT_EQUAL(-80, SIOT_PATH_GOOD_DBM);
    siot_path_link_sample(&t, SIOT_PATH_GOOD_DBM);
    hear(&now, 3, &root, -80);
    hear(&now, 3, &y, -40);
    TEST_ASSERT_FALSE(siot_path_evaluate(&t, now, 0, SIOT_PATH_GAIN_DB, &c));

    /* -85 against -76: 9 dB, one short. */
    start();
    now = 0;
    siot_path_set_parent(&t, ROOT);
    siot_path_link_sample(&t, -85);
    hear(&now, 3, &root, -85);
    hear(&now, 3, &y, -76);
    TEST_ASSERT_TRUE(siot_path_best(&t, now, &c));
    TEST_ASSERT_EQUAL(-76, c.path_new);
    TEST_ASSERT_FALSE(siot_path_evaluate(&t, now, 0, SIOT_PATH_GAIN_DB, &c));
    /* One dB more and it is enough. */
    start();
    now = 0;
    siot_path_set_parent(&t, ROOT);
    siot_path_link_sample(&t, -85);
    hear(&now, 3, &root, -85);
    hear(&now, 3, &y, -75);
    TEST_ASSERT_TRUE(siot_path_evaluate(&t, now, 0, SIOT_PATH_GAIN_DB, &c));
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

TEST_CASE("path: a unit with no path goes to a unit that has one, never to another orphan", "[link][path]")
{
    /* The building of 2026-11-16: out of the board's reach, this unit lost its
     * parent and holds "level 1" with no board. X, heard at -63, is another
     * orphan calling itself level 1; Y, at -73, is in the real mesh. */
    start();
    int64_t now = 0;
    siot_path_set_parent(&t, NULL);
    siot_path_advert_t orphan = advert(X, 1, SIOT_PATH_ROOT_DBM, NULL, 0);
    orphan.complete = false;
    const uint8_t chain[12] = {0x52, 0, 0, 0, 0, 0x40, 0x52, 0, 0, 0, 0, 0x10};
    const siot_path_advert_t y = advert(Y, 3, -55, chain, 2);
    siot_path_choice_t c;

    hear(&now, 3, &orphan, -63);
    TEST_ASSERT_FALSE(siot_path_rescue(&t, now, &c)); /* nobody with a path: stay, keep the mesh */
    hear(&now, 3, &y, -73);
    TEST_ASSERT_TRUE(siot_path_rescue(&t, now, &c));
    TEST_ASSERT_EQUAL_MEMORY(Y, c.ap, 6);
    TEST_ASSERT_EQUAL(-73, c.path_new);

    /* The board is off: the real root says so, and so does everything under it. */
    siot_path_advert_t off = y;
    off.complete = false;
    hear(&now, 1, &off, -73);
    TEST_ASSERT_FALSE(siot_path_rescue(&t, now, &c));

    /* A child with a parent nothing comes down from: any unit with a path, but not that parent. */
    start();
    now = 0;
    siot_path_set_parent(&t, X);
    siot_path_link_sample(&t, -40);
    hear(&now, 3, &orphan, -40);
    TEST_ASSERT_FALSE(siot_path_rescue(&t, now, &c));
    hear(&now, 3, &y, -80);
    TEST_ASSERT_TRUE(siot_path_rescue(&t, now, &c));
    TEST_ASSERT_EQUAL_MEMORY(Y, c.ap, 6);
    /* ...and what this unit says meanwhile: no path it can vouch for. */
    siot_path_advert_t own;
    siot_path_own(&t, now, 2, false, false, false, &own);
    TEST_ASSERT_FALSE(own.complete);
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

TEST_CASE("path: a unit that just joined moves for 5 dB, but only from below -80", "[link][path]")
{
    /* After a power cut this unit took the first parent it heard: the root at
     * -88, with Y (path -40) heard at -82. 6 dB: not enough later, enough now. */
    start();
    int64_t now = 0;
    siot_path_set_parent(&t, ROOT);
    siot_path_link_sample(&t, -88);
    const siot_path_advert_t root = advert(ROOT, 1, SIOT_PATH_ROOT_DBM, NULL, 0);
    const siot_path_advert_t y = advert(Y, 2, -40, ROOT, 1);
    siot_path_choice_t c;
    hear(&now, 3, &root, -88);
    hear(&now, 3, &y, -82);
    TEST_ASSERT_FALSE(siot_path_evaluate(&t, now, 0, SIOT_PATH_GAIN_DB, &c));
    TEST_ASSERT_TRUE(siot_path_evaluate(&t, now, 0, SIOT_PATH_JOIN_GAIN_DB, &c));
    TEST_ASSERT_EQUAL_MEMORY(Y, c.ap, 6);

    /* On the root at -79: left alone whatever is next door, joined or not. */
    start();
    now = 0;
    siot_path_set_parent(&t, ROOT);
    siot_path_link_sample(&t, -79);
    hear(&now, 3, &root, -79);
    hear(&now, 3, &y, -40);
    TEST_ASSERT_FALSE(siot_path_evaluate(&t, now, 0, SIOT_PATH_JOIN_GAIN_DB, &c));
}

TEST_CASE("path: an alarm is told from unit to unit and dies with its source", "[link][path]")
{
    start();
    int64_t now = 0;
    TEST_ASSERT_EQUAL(0, siot_path_alarm(&t, now, false));
    TEST_ASSERT_EQUAL(1, siot_path_alarm(&t, now, true)); /* this unit's own */

    /* X is in alarm, Y heard of one two hops from it: the nearest counts. */
    siot_path_advert_t x = advert(X, 2, -50, ROOT, 1), y = advert(Y, 2, -50, ROOT, 1), b;
    x.alarm = 1;
    y.alarm = 3;
    uint8_t buf[SIOT_PATH_ADVERT_MAX_LEN];
    const size_t n = siot_path_advert_encode(&x, buf, sizeof(buf));
    TEST_ASSERT_TRUE(siot_path_advert_decode(buf, n, &b));
    TEST_ASSERT_EQUAL(1, b.alarm);
    TEST_ASSERT_TRUE(b.complete);
    hear(&now, 1, &y, -60);
    TEST_ASSERT_EQUAL(4, siot_path_alarm(&t, now, false));
    hear(&now, 1, &x, -60); /* one advert is enough */
    TEST_ASSERT_EQUAL(2, siot_path_alarm(&t, now, false));

    /* The alarm is reset: X says so, and Y's word is still believed... */
    x.alarm = 0;
    hear(&now, 1, &x, -60);
    TEST_ASSERT_EQUAL(4, siot_path_alarm(&t, now, false));
    /* ...until Y is as far as the word goes, or silent. */
    y.alarm = SIOT_PATH_ALARM_MAX;
    hear(&now, 1, &y, -60);
    TEST_ASSERT_EQUAL(0, siot_path_alarm(&t, now, false));
    y.alarm = 2;
    hear(&now, 1, &y, -60);
    TEST_ASSERT_EQUAL(3, siot_path_alarm(&t, now, false));
    now += SIOT_PATH_FRESH_MS + 1;
    TEST_ASSERT_EQUAL(0, siot_path_alarm(&t, now, false));
}

TEST_CASE("path: a unit that lost its parent passes over the units that hang from it", "[link][path]")
{
    /* This unit hung from X. X goes off: Y, which hangs from X too, goes on
     * saying COMPLETE until the news reaches it. ROOT is the real way in. */
    start();
    int64_t now = 0;
    siot_path_set_parent(&t, X);
    siot_path_link_sample(&t, -50);
    const siot_path_advert_t x = advert(X, 2, -60, ROOT, 1);
    const uint8_t via_x[12] = {0x52, 0, 0, 0, 0, 0x20, 0x52, 0, 0, 0, 0, 0x10};
    const siot_path_advert_t y = advert(Y, 3, -60, via_x, 2);
    const siot_path_advert_t root = advert(ROOT, 1, SIOT_PATH_ROOT_DBM, NULL, 0);
    siot_path_choice_t c;
    hear(&now, 3, &x, -50);
    hear(&now, 3, &y, -45);

    siot_path_parent_lost(&t, now, X);
    siot_path_set_parent(&t, NULL);
    TEST_ASSERT_FALSE(siot_path_rescue(&t, now, &c)); /* X itself, and Y through X: no way out */
    hear(&now, 3, &root, -84);
    TEST_ASSERT_TRUE(siot_path_rescue(&t, now, &c));
    TEST_ASSERT_EQUAL_MEMORY(ROOT, c.ap, 6);

    /* Y found another parent: what it says now is news, and it is the better path. */
    const siot_path_advert_t y2 = advert(Y, 2, -60, ROOT, 1);
    hear(&now, 1, &y2, -45);
    TEST_ASSERT_TRUE(siot_path_rescue(&t, now, &c));
    TEST_ASSERT_EQUAL_MEMORY(Y, c.ap, 6);

    /* X is back with a path before the wait is over: believed at once. */
    start();
    now = 0;
    siot_path_set_parent(&t, X);
    hear(&now, 3, &x, -50);
    siot_path_parent_lost(&t, now, X);
    siot_path_set_parent(&t, NULL);
    TEST_ASSERT_FALSE(siot_path_rescue(&t, now, &c));
    hear(&now, 1, &x, -50);
    TEST_ASSERT_TRUE(siot_path_rescue(&t, now, &c));
    TEST_ASSERT_EQUAL_MEMORY(X, c.ap, 6);

    /* And the wait ends by itself. */
    start();
    now = 0;
    siot_path_set_parent(&t, X);
    hear(&now, 3, &x, -50);
    hear(&now, 3, &y, -45);
    siot_path_parent_lost(&t, now, X);
    siot_path_set_parent(&t, NULL);
    hear(&now, SIOT_PATH_LOST_MS / SIOT_PATH_ADVERT_MS - 1, &y, -45);
    TEST_ASSERT_FALSE(siot_path_rescue(&t, now, &c));
    hear(&now, 1, &y, -45);
    TEST_ASSERT_TRUE(siot_path_rescue(&t, now, &c));
    TEST_ASSERT_EQUAL_MEMORY(Y, c.ap, 6);
}

TEST_CASE("path: a unit with no path passes over a missed parent for one round, not half an hour", "[link][path]")
{
    start();
    int64_t now = 0;
    siot_path_set_parent(&t, NULL);
    const siot_path_advert_t y = advert(Y, 2, -60, ROOT, 1);
    siot_path_choice_t c;
    hear(&now, 3, &y, -70);
    TEST_ASSERT_TRUE(siot_path_rescue(&t, now, &c));
    siot_path_mark_bad_for(&t, now, Y, SIOT_PATH_RESCUE_SKIP_MS);
    TEST_ASSERT_FALSE(siot_path_rescue(&t, now, &c));
    now += SIOT_PATH_RESCUE_SKIP_MS - SIOT_PATH_ADVERT_MS;
    hear(&now, 1, &y, -70);
    TEST_ASSERT_TRUE(siot_path_rescue(&t, now, &c));
    TEST_ASSERT_EQUAL_MEMORY(Y, c.ap, 6);
}

TEST_CASE("path: HELD is said by a root that lost the central and heard by the units under it", "[link][path]")
{
    start();
    int64_t now = 0;
    siot_path_advert_t root = advert(ROOT, 1, SIOT_PATH_ROOT_DBM, NULL, 0), b;
    root.complete = false;
    root.held = true;
    uint8_t buf[SIOT_PATH_ADVERT_MAX_LEN];
    size_t n = siot_path_advert_encode(&root, buf, sizeof(buf));
    TEST_ASSERT_TRUE(siot_path_advert_decode(buf, n, &b));
    TEST_ASSERT_TRUE(b.held);
    TEST_ASSERT_FALSE(b.complete);

    /* Never together with COMPLETE: a path is a path. */
    root.complete = true;
    n = siot_path_advert_encode(&root, buf, sizeof(buf));
    TEST_ASSERT_TRUE(siot_path_advert_decode(buf, n, &b));
    TEST_ASSERT_FALSE(b.held);
    root.complete = false;

    siot_path_set_parent(&t, ROOT);
    TEST_ASSERT_FALSE(siot_path_parent_held(&t, now));
    hear(&now, 3, &root, -60);
    TEST_ASSERT_TRUE(siot_path_parent_held(&t, now));
    TEST_ASSERT_FALSE(siot_path_parent_complete(&t, now));

    /* The central is back: the root says COMPLETE, nothing is held. */
    root.complete = true;
    root.held = false;
    hear(&now, 1, &root, -60);
    TEST_ASSERT_FALSE(siot_path_parent_held(&t, now));
    TEST_ASSERT_TRUE(siot_path_parent_complete(&t, now));

    /* A parent that went silent vouches for nothing. */
    now += SIOT_PATH_FRESH_MS + 1;
    TEST_ASSERT_FALSE(siot_path_parent_complete(&t, now));
    TEST_ASSERT_FALSE(siot_path_parent_held(&t, now));
}
