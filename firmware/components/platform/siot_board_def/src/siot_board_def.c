#include "siot_board_def.h"

#include <string.h>

#include "siot_board_def_gen.h"

static const siot_board_def_t *s_selected;
static bool s_fallback; /* the model matched nothing: the default entry lends its pins */

static const siot_board_def_t *find_default(void)
{
    for (int i = 0; i < SIOT_BOARD_DEF_COUNT; i++) {
        if (SIOT_BOARD_DEFS[i].is_default) return &SIOT_BOARD_DEFS[i];
    }
    return &SIOT_BOARD_DEFS[0];
}

esp_err_t siot_board_def_select(const char *model, uint8_t hw_rev)
{
    const siot_board_def_t *any_rev = NULL;
    if (model != NULL) {
        for (int i = 0; i < SIOT_BOARD_DEF_COUNT; i++) {
            const siot_board_def_t *d = &SIOT_BOARD_DEFS[i];
            if (strcmp(d->model, model) != 0) continue;
            if (d->hw_rev == hw_rev) {
                s_selected = d;
                s_fallback = false;
                return ESP_OK;
            }
            if (d->hw_rev == 0 && any_rev == NULL) any_rev = d;
        }
    }
    if (any_rev != NULL) {
        s_selected = any_rev;
        s_fallback = false;
        return ESP_OK;
    }
    s_selected = find_default();
    s_fallback = true;
    return ESP_ERR_NOT_FOUND;
}

const siot_board_def_t *siot_board_def(void)
{
    if (s_selected == NULL) s_selected = find_default();
    return s_selected;
}

uint16_t siot_board_def_product(void)
{
    return s_fallback ? 0 : siot_board_def()->product;
}
