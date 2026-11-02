#ifndef DOA_UI_EMA_H
#define DOA_UI_EMA_H
#include "doa_result_publish.h"

#ifndef DOA_UI_EMA_TAU_MS
#define DOA_UI_EMA_TAU_MS 400U
#endif
#define DOA_UI_EMA_STALE_MS 300U /* existing main UI freshness cutoff */
#define DOA_UI_EMA_STEP_DEG 5.0
#define DOA_UI_EMA_STEP_MATCH_DEG 2.0
#define DOA_UI_EMA_STEP_WINDOW_MS 200U
#define DOA_UI_NUMBER_PERIOD_MS 100U

/* Display copies only; raw code retains the exact PL S36/F35 value. */
typedef struct {
    unsigned available;
    int64_t raw_theta_code;
    double raw_doa, smooth_doa;
    uint64_t publish_seq;
    XTime received_time;
    result_identity_t identity;
} doa_ui_angles_t;
typedef struct {
    doa_ui_angles_t value;
    result_identity_t seen_identity;
    uint64_t seen_publish_seq, accepted, step_resets;
    XTime last_now, step_time;
    double step_anchor, step_target;
    unsigned seen, clock_seen, step_pending;
} doa_ui_ema_t;

void doa_ui_ema_init(doa_ui_ema_t *);
/* No producer reads, MMIO, ACK, timer call, heap, loop or logging.
 * Caller supplies an already-published COPY and current PS clock ticks.
 * blocked/invalid/stale consumes that publication identity without reusing it.
 * Return 1 only when a fresh valid measurement was accepted, 0 otherwise. */
int doa_ui_ema_update(doa_ui_ema_t *, const doa_published_result_t *, XTime now,
                      int presentation_allowed);
int doa_ui_angles_match(const doa_ui_angles_t *, const doa_published_result_t *);
void doa_ui_raw_text(char *, unsigned size, int64_t raw_theta_code);
void doa_ui_smooth_text(char *, unsigned size, double smooth_doa);
#endif
