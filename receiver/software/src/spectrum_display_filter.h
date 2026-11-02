#ifndef SPECTRUM_DISPLAY_FILTER_H
#define SPECTRUM_DISPLAY_FILTER_H
#include "lcd_doa.h"

#define SPECTRUM_UI_AVERAGE_FRAMES 8U
#ifndef SPECTRUM_UI_NOISE_FLOOR_DBFS
#define SPECTRUM_UI_NOISE_FLOOR_DBFS (-110.0f)
#endif
typedef struct {
    float noise_floor_dbfs, gate_margin_db, ema_old_weight, fast_rise_db;
    unsigned first_bin, last_bin;
} spectrum_display_config_t;
typedef struct {
    uint64_t accepted_frames, submitted_frames, compared_frames, resets;
    uint64_t fast_rises, gated_bins, rejected_frames;
    float before_last_db, after_last_db, before_max_db, after_max_db;
} spectrum_display_stats_t;
typedef struct {
    spectrum_display_config_t config;
    /* Only UI-owned memory. No pointers to an FFT bank or algorithm data. */
    double staged_power[2][FFT_BINS];
    double history[SPECTRUM_UI_AVERAGE_FRAMES][2][FFT_BINS];
    double sum[2][FFT_BINS];
    float average_db[2][FFT_BINS];
    float previous_display[2][FFT_BINS], previous_raw[2][FFT_BINS];
    u32 staged_sequence, committed_sequence;
    unsigned staged_bins, stage_valid, count, next_slot, average_valid, display_valid;
    float staged_fs, fs;
    XTime last_receive;
    spectrum_display_stats_t stats;
} spectrum_display_filter_t;

extern const spectrum_display_config_t spectrum_display_default_config;
int spectrum_display_init(spectrum_display_filter_t *, const spectrum_display_config_t *);
void spectrum_display_reset(spectrum_display_filter_t *);
/* Passive tap called with the values from the ALREADY existing FFT reads.
 * This stages only; no average or display is published until bank RELEASE. */
void spectrum_display_stage_bin(spectrum_display_filter_t *, u32 sequence, float fs,
                               unsigned bin, s32 re0, s32 im0, s32 re1, s32 im1);
int spectrum_display_accept(spectrum_display_filter_t *, const spectrum_view_snapshot_t *raw);
/* Prepare a value copy for the renderer; no EMA state change on redraw failure. */
int spectrum_display_prepare(const spectrum_display_filter_t *,
                             const spectrum_view_snapshot_t *raw,
                             spectrum_view_snapshot_t *display);
/* Called only after the framebuffer present API accepts the submitted frame.
 * Metrics are submitted-UI differences, not proof of physical scanout. */
void spectrum_display_commit(spectrum_display_filter_t *, const spectrum_view_snapshot_t *raw,
                             const spectrum_view_snapshot_t *display);
#endif
