/* safr_port.h — the only OS-specific piece of siot_safr: a mutex.
 *
 * Both the CCM context and the counter/dedupe/replay/handler state are shared
 * by the TX task and the RX task (brief §5.2, §10). On ESP targets this is a
 * FreeRTOS mutex; on the linux host target (test/host) a pthread mutex, so
 * core/ never depends on the FreeRTOS simulator.
 */
#pragma once

#include "sdkconfig.h"

#if CONFIG_IDF_TARGET_LINUX

#include <pthread.h>

typedef pthread_mutex_t safr_lock_t;

static inline void safr_lock_init(safr_lock_t *l) { pthread_mutex_init(l, NULL); }
static inline void safr_lock(safr_lock_t *l)      { pthread_mutex_lock(l); }
static inline void safr_unlock(safr_lock_t *l)    { pthread_mutex_unlock(l); }

#else /* ESP32 family: FreeRTOS */

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

typedef SemaphoreHandle_t safr_lock_t;

static inline void safr_lock_init(safr_lock_t *l) { *l = xSemaphoreCreateMutex(); }
static inline void safr_lock(safr_lock_t *l)      { xSemaphoreTake(*l, portMAX_DELAY); }
static inline void safr_unlock(safr_lock_t *l)    { xSemaphoreGive(*l); }

#endif
