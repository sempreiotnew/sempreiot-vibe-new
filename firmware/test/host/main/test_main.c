/* Host test runner: runs every TEST_CASE and exits with the failure count so
 * ci/check.sh can fail the pipeline. */
#include <stdio.h>
#include <stdlib.h>

#include "unity.h"

#include "siot_version.h"

void app_main(void)
{
    printf("\n#### siot host tests — firmware %s ####\n\n", siot_version_full());
    UNITY_BEGIN();
    unity_run_all_tests();
    const int failures = UNITY_END();
    exit(failures == 0 ? 0 : 1);
}
