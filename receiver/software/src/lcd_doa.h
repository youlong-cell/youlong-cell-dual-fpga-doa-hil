#ifndef LCD_DOA_H
#define LCD_DOA_H
#include "doa_result_publish.h"
#include "spectrum_pl.h"

#ifndef DOA_UI_STALE_MS
#define DOA_UI_STALE_MS 1000U
#endif

/* PS drawing inputs only. Not a PL ABI or a new result producer.
 * surface carries externally measured AGE, so the renderer needs no timer. */
typedef struct {
    uint8_t *pixels;
    uint32_t stride;
    uint64_t result_age_ms;
    unsigned result_age_valid;
    uint32_t stale_after_ms;
} doa_framebuffer_t;

typedef struct {
    unsigned available, metadata_valid, age_valid;
    uint64_t view_seq, age_ms;
    XTime received_time;             /* Independent of DOA received_time. */
    spectrum_pl_frame_meta_t metadata;
    spectrum_t ch[2];                /* Full value copies, never live pointers. */
} spectrum_view_snapshot_t;

typedef struct {
    char angle[40], raw_phase[40], cal_phase[40], frequency[40];
    char state[24], reason[80], age[48];
    unsigned pointer_valid, stale, target_valid;
    int pointer_x;
    int64_t theta_code;
    uint64_t frequency_code;
} doa_render_model_t;

/* Pure deterministic decoder/formatter and renderer. No MMIO/ACK/clock read. */
void lcd_doa_model(const doa_framebuffer_t *, const doa_published_result_t *,
                   doa_render_model_t *);
void lcd_draw_doa(const doa_framebuffer_t *framebuffer,
                  const doa_published_result_t *doa,
                  const spectrum_view_snapshot_t *spectrum);
/* Converts only a copied spectrum timestamp. No timer or producer access. */
void spectrum_view_age(spectrum_view_snapshot_t *, XTime now);
#endif
