/* ONE root (blueprint §4, protocol §7.6 ROOT_YIELD): the board's rule when a
 * second unit dials while the root is alive. A root that works is left
 * alone; a root whose link is weak gives way to a unit the board hears
 * clearly better; anything it cannot compare leaves the root where it is. */
#include "unity.h"

#include "siot_link.h"

TEST_CASE("one root: a weak root gives way to a unit heard 10 dB better", "[link][root]")
{
    /* The building of 2026-11-05: the root attached at -93, a unit at -62 dials. */
    TEST_ASSERT_TRUE(siot_link_root_challenger_wins(true, -93, true, -62));
    /* The margin itself, and one dB short of it. */
    TEST_ASSERT_TRUE(siot_link_root_challenger_wins(true, -90, true, -90 + SIOT_LINK_ROOT_TAKEOVER_DB));
    TEST_ASSERT_FALSE(siot_link_root_challenger_wins(true, -90, true, -90 + SIOT_LINK_ROOT_TAKEOVER_DB - 1));
    /* A weak root and an even weaker unit: the root stays. */
    TEST_ASSERT_FALSE(siot_link_root_challenger_wins(true, -90, true, -95));
}

TEST_CASE("one root: a root that works is left alone, however good the newcomer", "[link][root]")
{
    /* The same two the other way round: the weak unit dials, the root stays. */
    TEST_ASSERT_FALSE(siot_link_root_challenger_wins(true, -62, true, -93));
    /* A much better unit still does not move a root that is not weak. */
    TEST_ASSERT_FALSE(siot_link_root_challenger_wins(true, -70, true, -30));
    TEST_ASSERT_FALSE(siot_link_root_challenger_wins(true, SIOT_LINK_ROOT_WEAK_DBM, true, -30));
    /* One dB under the weak-link level, and it does. */
    TEST_ASSERT_TRUE(siot_link_root_challenger_wins(true, SIOT_LINK_ROOT_WEAK_DBM - 1, true, -30));
}

TEST_CASE("one root: nothing to compare, the root stays", "[link][root]")
{
    TEST_ASSERT_FALSE(siot_link_root_challenger_wins(false, 0, true, -40));
    TEST_ASSERT_FALSE(siot_link_root_challenger_wins(true, -90, false, 0));
    TEST_ASSERT_FALSE(siot_link_root_challenger_wins(false, 0, false, 0));
}
