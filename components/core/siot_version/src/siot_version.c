#include "siot_version.h"

#include "siot_version_gen.h"

const char *siot_version_string(void)
{
    return SIOT_VERSION_STRING_GEN;
}

const char *siot_version_build_id(void)
{
    return SIOT_BUILD_ID_GEN;
}

const char *siot_version_full(void)
{
    return SIOT_VERSION_STRING_GEN "+" SIOT_BUILD_ID_GEN;
}
