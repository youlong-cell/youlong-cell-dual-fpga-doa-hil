#ifndef SPECTRUM_PL_H
#define SPECTRUM_PL_H

/* ============================================================================
 * spectrum_pl.h - public interface for the dual-channel PL FFT accelerator
 *
 * All phase values inside this API are radians. Display/report code performs
 * the conversion to degrees at the user-interface boundary.
 * ========================================================================== */

#include "xil_types.h"
#include "spectrum.h"

/*
 * Coherent dual-channel phase result.
 *
 * Phase convention is frozen in docs/PHASE_CONVENTION.md:
 *   CH0 is the reference, phase = phi_CH1 - phi_CH0,
 *   phase_rad is wrapped to [-pi, pi).
 * Keep radians inside the processing API; convert to degrees only at the UI
 * or experiment-reporting boundary.
 */
typedef struct {
    int   valid;
    u16   target_bin;
    u16   reserved;
    u32   sequence;
    float frequency_hz;
    float phase_rad;
    float ch0_mag_db;
    float ch1_mag_db;
} spectrum_phase_t;

/* Available only for a successfully released result-bank frame. The sample
 * IDs belong to the shared 48-bit ADC timeline, not to the PS wall clock. */
typedef struct {
    u32 sequence;
    u64 first_sample_id;
    u64 last_sample_id;
    u32 bank;
} spectrum_pl_frame_meta_t;

/* Selective, single-frequency DFT on one paired raw ADC capture.  This is a
 * PS diagnostic estimator; the PL FFT result remains the production result
 * until physical CH0/CH1 sample alignment has been verified. */
typedef struct {
    int valid;
    float frequency_hz;
    double exact_frequency_hz;
    float phase_rad;
    float ch0_amplitude_codes;
    float ch1_amplitude_codes;
    /* Unnormalized Hann-weighted DFT sums in ADC-code units. The common
     * complex origin n=0 is ch0[0]/ch1[0]; a valid phase is obtained from
     * arg((ch1_re+j*ch1_im)*conj(ch0_re+j*ch0_im)). */
    double ch0_re;
    double ch0_im;
    double ch1_re;
    double ch1_im;
} spectrum_dft_result_t;

/* samples are unsigned 12-bit ADC codes.  Both arrays must describe the same
 * capture interval and have the same sample index origin.  Returns 1 for a
 * valid phase, 0 for a rejected result or invalid arguments. */
int spectrum_pl_selective_dft(const u16 *ch0, const u16 *ch1, int count,
                              double sample_rate_hz, double target_hz,
                              spectrum_dft_result_t *result);

/* Service return codes. */
#define SPECTRUM_PL_SERVICE_IDLE       0
#define SPECTRUM_PL_SERVICE_FRAME      1
#define SPECTRUM_PL_SERVICE_TIMEOUT   -1

/* Initialize the PL FFT interface. Banked hardware starts autonomous search
 * once; the legacy ABI retains its one-shot compatibility behavior. */
int spectrum_pl_init(void);

/* Banked ABI only. STOP takes effect at the current FFT frame boundary;
 * neither call waits for the ADC-domain state transition. */
int spectrum_pl_start_search(void);
int spectrum_pl_stop_search(void);

/* Non-blocking service. Sample rate comes from hardware/sample_clock.h. */
int spectrum_pl_service(void);

/* Return the most recent completed dual-channel PL result. */
int spectrum_pl_get(const spectrum_t **ch0, const spectrum_t **ch1);

/* Optional UI-only, one-way observation of existing BRAM reads. No new MMIO,
 * no mutation of FFT buffers, no change to phase/detector mathematics.
 * Values are provisional until the completed-frame RELEASE has succeeded. */
typedef void (*spectrum_pl_display_tap_t)(u32 sequence,float fs,unsigned bin,
                                         s32 re0,s32 im0,s32 re1,s32 im1);
void spectrum_pl_set_display_tap(spectrum_pl_display_tap_t tap);

/* Return the phase result associated with the most recent completed frame.
 * The function returns 1 once any completed frame is available.  Callers must
 * still check result->valid before using phase_rad. */
int spectrum_pl_get_phase(spectrum_phase_t *result);

int spectrum_pl_get_frame_meta(spectrum_pl_frame_meta_t *result);
u32 spectrum_pl_export_drop_count(void);
u32 spectrum_pl_export_abort_count(void);

/* Deterministic, hardware-independent convention/wrap self-test.
 * Returns 0 on success or a negative failure count. */
int spectrum_pl_phase_selftest(void);

/* Raw accelerator status, useful for UART diagnostics. */
u32 spectrum_pl_status(void);

/* Number of PS-side completion timeouts since initialization. */
u32 spectrum_pl_timeout_count(void);

#endif /* SPECTRUM_PL_H */
