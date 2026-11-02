#ifndef DEBUG_UI_H
#define DEBUG_UI_H
#include "display_ctrl.h"
#include "lcd_doa.h"
#include "debug_input.h"
#include "engineering_session.h"
#include "hil_profiles.h"
#include "doa_ui_ema.h"
/* Preserve numeric page IDs/main-loop mapping. PAGE_FFT is now the HIL view;
 * PAGE_ADC/PAGE_SYSTEM retain detailed diagnostics. No source truth is supplied
 * by this renderer: SOURCE CONFIG and comparison error remain unavailable. */
enum debug_page { PAGE_DOA, PAGE_FFT, PAGE_ADC, PAGE_SYSTEM };
enum debug_state { DBG_NOT_INITIALIZED, DBG_OK, DBG_ERROR, DBG_NO_DATA };
typedef struct {
    enum debug_state dp, adc[2], dma[2], fft, stop;
    int dp_rc, stop_rc, fft_rc;
    u32 lifecycle, fine_status;
    u32 dma_status[2], adc_status[2], dropped[2];
    u32 transfers[2], errors[2], timeouts[2], rejected;
    u16 min[2], max[2], first[2];
    u32 mean[2], capture_seq, fft_frames, fft_timeouts;
    u32 drawn, present_fail, no_buffer, atb_status;
    UINTPTR bus_fault_address;
    u64 uptime_ms, draw_max_us, loop_max_us, service_gap_max_us;
    unsigned spectrum_fresh, signal_quality, adc_fresh;
    u32 peak_bin[2]; float peak_hz[2], peak_db[2], prominence_db[2];
    debug_peak_t peak[2];
    debug_input_state_t input[2], input_pair;
    u32 rms_millicodes[2], rail_count[2], block_sample_count[2];
    u64 sample_count[2]; /* accepted legacy DMA samples, not global sample_id */
    enum engineering_state session_state;
    int fine_rc;
    u64 session_epoch, fine_published, fine_invalid, result_age_ms;
    u32 config_version, fine_fault_code, fine_busy_drop, fine_result_drop;
    unsigned result_fresh;
    enum debug_page page;
    u32 key_mode_raw, key_mode_code, key_mode_errors;
    unsigned ui_low_detail;
    u64 renderer_last_us, renderer_max_us;
    u32 display_fps_milli;
    doa_ui_angles_t doa_angles; /* immutable display copy; never PL/result ABI */
} debug_view_t;
enum debug_page debug_page_from_pl_mode(unsigned mode);
const char *debug_page_name(enum debug_page);
const char *debug_state_name(enum debug_state s);
void debug_doa_visible_snapshot(const debug_view_t *,const doa_published_result_t *,doa_published_result_t *);
void debug_draw(u8 *frame,const debug_view_t *view,
                const spectrum_view_snapshot_t *spec,
                const doa_published_result_t *doa,
                const u16 samples[2][1920]);
#endif
