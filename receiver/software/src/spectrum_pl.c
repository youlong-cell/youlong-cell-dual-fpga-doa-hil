/* ============================================================================
 * spectrum_pl.c - PS driver for the dual-channel PL FFT accelerator
 *
 * The driver exchanges toggle-based commands/status through AXI GPIO, reads
 * complex FFT bins from AXI BRAM and estimates phase as phi_CH1 - phi_CH0.
 * Internal phase values are radians wrapped to [-pi, pi).
 *
 * Revision History:
 * Date        Revision  Change Description
 * ---------------------------------------------------------------------------
 * 2026/09/20  1.0       PL FFT service, target selection and phase estimator
 * 2026/09/20  1.1       Documented register map and frozen phase convention
 * ========================================================================== */

#include <math.h>
#include "xil_io.h"
#include "xil_types.h"
#include "xparameters.h"
#include "xtime_l.h"
#include "spectrum_pl.h"
#include "hardware/sample_clock.h"
#include "service_profile.h"

/* Fixed in design_1 address editor.  Keep these fallbacks so the source can
 * also be compiled before the regenerated BSP has been imported into Vitis. */
#ifdef XPAR_AXI_GPIO_FFT_BASEADDR
# define FFT_GPIO_BASE XPAR_AXI_GPIO_FFT_BASEADDR
#else
# define FFT_GPIO_BASE 0x80090000U
#endif

#ifdef XPAR_FFT_RESULT_BRAM_CTRL_S_AXI_BASEADDR
# define FFT_BRAM_BASE XPAR_FFT_RESULT_BRAM_CTRL_S_AXI_BASEADDR
#else
# define FFT_BRAM_BASE 0x800A0000U
#endif

#define GPIO_DATA1_OFFSET 0x00U
#define GPIO_TRI1_OFFSET  0x04U
#define GPIO_DATA2_OFFSET 0x08U
#define GPIO_TRI2_OFFSET  0x0CU

#define ST_BUSY_MASK       0x00000001U
#define ST_DONE_MASK       0x00000002U
#define ST_ERROR_MASK      0x00000004U

#define BANK_ABI_MAGIC     0xB25A3C00U
#define BANK_ABI_MASK      0xFFFFFF00U
#define BANK_READY_MASK    0x00000003U
#define BANK_CLAIM_ACK     0x00000010U
#define BANK_RELEASE_ACK   0x00000020U
#define BANK_CLAIM_GRANTED 0x00000040U
#define BANK_RELEASE_GRANTED 0x00000080U
#define BANK_BYTES         ((UINTPTR)FFT_BINS * 2U * 8U)
#define BANK_SELECT_SHIFT  20U
#define BANK_SELECT_MASK   (0xFU << BANK_SELECT_SHIFT)
#define BANK_SEQ_SHIFT     4U
#define BANK_SEQ_MASK      (0xFFFFU << BANK_SEQ_SHIFT)

enum bank_service_state {
    BANK_IDLE = 0,
    BANK_CLAIM_WAIT,
    BANK_RELEASE_WAIT
};

/* Hardware watchdog is about 16.8 ms. The independent PS deadline is longer
 * so a stopped adc_clk or lost status transition cannot wedge the service. */
#define FFT_PS_TIMEOUT_US      50000ULL
#define FFT_PS_TIMEOUT_TICKS   \
    ((XTime)(((u64)COUNTS_PER_SECOND * FFT_PS_TIMEOUT_US) / 1000000ULL))

#define ADC_FULL_SCALE     2048.0f
#define MAG_FLOOR_VALUE    1.0e-12f
/* Frozen Hann ROM Q15 sum=16760324, 1024 coefficients. SHA256 in
 * INPUT_DIAGNOSTICS.md. Unscaled FFT: Apeak=2*|X[k]|/sum(window). */
#define HANN_WINDOW_SUM    (16760324.0f / 32768.0f)

/* Initial validity gate.  It is intentionally named and isolated so it can be
 * replaced with a measured noise-floor policy after HIL data are available. */
#define PHASE_MIN_CHANNEL_DBFS  (-60.0f)
#define PHASE_PI_RAD             3.14159265358979323846
#define PHASE_TWO_PI_RAD         (2.0 * PHASE_PI_RAD)

static spectrum_t cached_ch0;
static spectrum_t cached_ch1;
static spectrum_phase_t cached_phase;
static u32 command_toggle;
static u32 expected_done_toggle;
static u32 result_sequence;
static int command_active;
static int result_valid;
static XTime command_start_ticks;
static u32 timeout_count;
static u32 gpio_control_word;
static int banked_mode;
static int bank_search_enabled;
static enum bank_service_state bank_state;
static u32 pending_bank;
static u32 pending_sequence;
static u32 pending_claim_ack;
static u32 pending_release_ack;
static int pending_frame_valid;
static int pending_stale_frame;
static int bank_timeout_reported;
static u64 pending_first_sample_id, pending_last_sample_id;
static spectrum_pl_frame_meta_t cached_frame_meta;
static int frame_meta_valid;

static spectrum_pl_display_tap_t display_tap;
void spectrum_pl_set_display_tap(spectrum_pl_display_tap_t tap){display_tap=tap;}

static u32 bank_read_selector(u32 selector)
{
    gpio_control_word = (gpio_control_word & ~BANK_SELECT_MASK)
                      | ((selector & 0xFU) << BANK_SELECT_SHIFT);
    Xil_Out32(FFT_GPIO_BASE + GPIO_DATA1_OFFSET, gpio_control_word);
    return Xil_In32(FFT_GPIO_BASE + GPIO_DATA2_OFFSET);
}

static u32 bank_status(void)
{
    return bank_read_selector(0U);
}

static u64 bank_read_sample_id(u32 low_selector)
{
    u64 low = (u64)bank_read_selector(low_selector);
    u64 high = (u64)(bank_read_selector(low_selector + 1U) & 0xFFFFU);
    return low | (high << 32);
}

static void bank_command(u32 bank, u32 sequence, int release)
{
    gpio_control_word &= ~(BANK_SEQ_MASK | 0x00000008U);
    gpio_control_word |= ((sequence & 0xFFFFU) << BANK_SEQ_SHIFT)
                       | ((bank & 1U) << 3);
    if (release)
        gpio_control_word ^= 0x00000004U;
    else
        gpio_control_word ^= 0x00000002U;
    gpio_control_word &= ~BANK_SELECT_MASK;
    Xil_Out32(FFT_GPIO_BASE + GPIO_DATA1_OFFSET, gpio_control_word);
    XTime_GetTime(&command_start_ticks);
    bank_timeout_reported = 0;
}

static double wrap_phase_rad(double phase_rad)
{
    while (phase_rad >= PHASE_PI_RAD)
        phase_rad -= PHASE_TWO_PI_RAD;
    while (phase_rad < -PHASE_PI_RAD)
        phase_rad += PHASE_TWO_PI_RAD;
    return phase_rad;
}

static double phase_from_complex(s32 re0, s32 im0, s32 re1, s32 im1)
{
    /* X_CH1 * conj(X_CH0) gives phi_CH1 - phi_CH0.  Promote before
     * multiplication: a signed 32-bit FFT component can overflow a 32-bit
     * product, and the sum of squares can approach the signed 64-bit limit. */
    double cross_re = (double)re1 * (double)re0
                    + (double)im1 * (double)im0;
    double cross_im = (double)im1 * (double)re0
                    - (double)re1 * (double)im0;

    return wrap_phase_rad(atan2(cross_im, cross_re));
}

int spectrum_pl_selective_dft(const u16 *ch0, const u16 *ch1, int count,
                              double sample_rate_hz, double target_hz,
                              spectrum_dft_result_t *result)
{
    double mean0 = 0.0, mean1 = 0.0;
    double re0 = 0.0, im0 = 0.0, re1 = 0.0, im1 = 0.0;
    double sum_window = 0.0;
    double step, step_re, step_im, rot_re = 1.0, rot_im = 0.0;
    double win_step_re, win_step_im, win_re = 1.0, win_im = 0.0;
    double amp0, amp1, cross_re, cross_im;
    int i;

    if (result == 0)
        return 0;
    result->valid = 0;
    result->frequency_hz = 0.0f;
    result->exact_frequency_hz = 0.0;
    result->phase_rad = 0.0f;
    result->ch0_amplitude_codes = 0.0f;
    result->ch1_amplitude_codes = 0.0f;
    result->ch0_re = 0.0;
    result->ch0_im = 0.0;
    result->ch1_re = 0.0;
    result->ch1_im = 0.0;
    if (ch0 == 0 || ch1 == 0 || count < 4 ||
        !isfinite(sample_rate_hz) || !isfinite(target_hz) ||
        sample_rate_hz <= 0.0 || target_hz <= 0.0 ||
        target_hz >= sample_rate_hz * 0.5)
        return 0;

    for (i = 0; i < count; ++i) {
        mean0 += (double)ch0[i];
        mean1 += (double)ch1[i];
    }
    mean0 /= (double)count;
    mean1 /= (double)count;

    /* Symmetric Hann matches the PL window ROM convention.  Recurrences
     * avoid trigonometric calls inside the sample loop.  DC removal precedes
     * windowing; both channels use exactly the same frequency and window. */
    step = -PHASE_TWO_PI_RAD * target_hz / sample_rate_hz;
    step_re = cos(step);
    step_im = sin(step);
    win_step_re = cos(PHASE_TWO_PI_RAD / (double)(count - 1));
    win_step_im = sin(PHASE_TWO_PI_RAD / (double)(count - 1));
    for (i = 0; i < count; ++i) {
        double window = 0.5 * (1.0 - win_re);
        double x0 = ((double)ch0[i] - mean0) * window;
        double x1 = ((double)ch1[i] - mean1) * window;
        double next_re, next_im, next_win_re;

        re0 += x0 * rot_re;
        im0 += x0 * rot_im;
        re1 += x1 * rot_re;
        im1 += x1 * rot_im;
        sum_window += window;
        next_re = rot_re * step_re - rot_im * step_im;
        next_im = rot_re * step_im + rot_im * step_re;
        rot_re = next_re;
        rot_im = next_im;
        next_win_re = win_re * win_step_re - win_im * win_step_im;
        win_im = win_re * win_step_im + win_im * win_step_re;
        win_re = next_win_re;
    }

    amp0 = 2.0 * hypot(re0, im0) / sum_window;
    amp1 = 2.0 * hypot(re1, im1) / sum_window;
    result->frequency_hz = (float)target_hz;
    result->exact_frequency_hz = target_hz;
    result->ch0_amplitude_codes = (float)amp0;
    result->ch1_amplitude_codes = (float)amp1;
    result->ch0_re = re0;
    result->ch0_im = im0;
    result->ch1_re = re1;
    result->ch1_im = im1;
    /* Same -60 dBFS floor as the PL phase gate (2048 * 10^(-60/20)). */
    if (amp0 < ADC_FULL_SCALE * 0.001 ||
        amp1 < ADC_FULL_SCALE * 0.001)
        return 0;

    cross_re = re1 * re0 + im1 * im0;
    cross_im = im1 * re0 - re1 * im0;
    result->phase_rad = (float)wrap_phase_rad(atan2(cross_im, cross_re));
    result->valid = 1;
    return 1;
}

static float complex_dbfs(s32 real_part, s32 imag_part, int bin)
{
    float re = (float)real_part;
    float im = (float)imag_part;
    float mag = sqrtf(re * re + im * im);
    float mag_norm = mag * ((bin == 0) ? 1.0f : 2.0f) / HANN_WINDOW_SUM;
    float db;

    if (mag_norm < MAG_FLOOR_VALUE)
        db = SPEC_DB_FLOOR;
    else
        db = 20.0f * log10f(mag_norm / ADC_FULL_SCALE + MAG_FLOOR_VALUE);

    if (bin == 0 || db < SPEC_DB_FLOOR)
        db = SPEC_DB_FLOOR;
    return db;
}

static void start_frame(void)
{
    u32 st = Xil_In32(FFT_GPIO_BASE + GPIO_DATA2_OFFSET);
    expected_done_toggle = st & ST_DONE_MASK;
    command_toggle ^= 1U;
    gpio_control_word = (gpio_control_word & ~1U) | command_toggle;
    Xil_Out32(FFT_GPIO_BASE + GPIO_DATA1_OFFSET, gpio_control_word);
    command_active = 1;
    XTime_GetTime(&command_start_ticks);
}

static void init_spectrum(spectrum_t *spec, float fs)
{
    spec->fs = fs;
    spec->freq_resolution = fs / (float)FFT_SIZE;
    spec->max_mag_db = SPEC_DB_FLOOR;
    spec->min_mag_db = 1.0e30f;
}

static void store_spectrum_bin(spectrum_t *spec, int bin, float db)
{
    spec->freq[bin] = (float)bin * spec->freq_resolution;
    spec->mag_db[bin] = db;
    if (db > spec->max_mag_db) spec->max_mag_db = db;
    if (db < spec->min_mag_db) spec->min_mag_db = db;
}

static void convert_frame(float fs, u32 sequence, u32 bank)
{
    SP_SCOPE(p,SP_FFT_CONVERT,bank,sequence);
    int i;
    int best_bin = -1;
    double best_score = -1.0;
    s32 best_re0 = 0, best_im0 = 0;
    s32 best_re1 = 0, best_im1 = 0;
    UINTPTR base0 = (UINTPTR)FFT_BRAM_BASE + (UINTPTR)bank * BANK_BYTES;
    UINTPTR base1 = base0 + (UINTPTR)FFT_BINS * 8U;

    init_spectrum(&cached_ch0, fs);
    init_spectrum(&cached_ch1, fs);

    cached_phase.valid = 0;
    cached_phase.target_bin = 0U;
    cached_phase.reserved = 0U;
    cached_phase.sequence = sequence;
    cached_phase.frequency_hz = 0.0f;
    cached_phase.phase_rad = 0.0f;
    cached_phase.ch0_mag_db = SPEC_DB_FLOOR;
    cached_phase.ch1_mag_db = SPEC_DB_FLOOR;

    for (i = 0; i < FFT_BINS; ++i) {
        UINTPTR addr0 = base0 + (UINTPTR)i * 8U;
        UINTPTR addr1 = base1 + (UINTPTR)i * 8U;
        s32 re0 = (s32)Xil_In32(addr0);
        s32 im0 = (s32)Xil_In32(addr0 + 4U);
        s32 re1 = (s32)Xil_In32(addr1);
        s32 im1 = (s32)Xil_In32(addr1 + 4U);
        float db0 = complex_dbfs(re0, im0, i);
        float db1 = complex_dbfs(re1, im1, i);

        /* Passive UI mirror only; raw values and phase path remain unchanged. */
        if(display_tap)display_tap(sequence,fs,(unsigned)i,re0,im0,re1,im1);

        store_spectrum_bin(&cached_ch0, i, db0);
        store_spectrum_bin(&cached_ch1, i, db1);

        /* Select a target that is strong in both channels.  Using the weaker
         * channel power prevents a large single-channel spur from becoming a
         * valid coherent target.  DC is excluded explicitly. */
        if (i > 0) {
            double p0 = (double)re0 * (double)re0
                      + (double)im0 * (double)im0;
            double p1 = (double)re1 * (double)re1
                      + (double)im1 * (double)im1;
            double score = (p0 < p1) ? p0 : p1;

            if (score > best_score) {
                best_score = score;
                best_bin = i;
                best_re0 = re0;
                best_im0 = im0;
                best_re1 = re1;
                best_im1 = im1;
            }
        }
    }

    if (best_bin > 0) {
        cached_phase.target_bin = (u16)best_bin;
        cached_phase.frequency_hz = cached_ch0.freq[best_bin];
        cached_phase.ch0_mag_db = cached_ch0.mag_db[best_bin];
        cached_phase.ch1_mag_db = cached_ch1.mag_db[best_bin];

        if (cached_phase.ch0_mag_db >= PHASE_MIN_CHANNEL_DBFS &&
            cached_phase.ch1_mag_db >= PHASE_MIN_CHANNEL_DBFS &&
            best_score > 0.0) {
            cached_phase.phase_rad = (float)phase_from_complex(
                best_re0, best_im0, best_re1, best_im1);
            cached_phase.valid = 1;
        }
    }
}

static int phase_close(double actual, double expected)
{
    return fabs(wrap_phase_rad(actual - expected)) < 1.0e-4;
}

int spectrum_pl_phase_selftest(void)
{
    int failures = 0;

    if (!phase_close(phase_from_complex(1000000, 0, 1000000, 0), 0.0))
        failures++;
    if (!phase_close(phase_from_complex(1000000, 0, 866025, 500000),
                     PHASE_PI_RAD / 6.0))
        failures++;
    if (!phase_close(phase_from_complex(1000000, 0, 866025, -500000),
                     -PHASE_PI_RAD / 6.0))
        failures++;
    if (!phase_close(phase_from_complex(1000000, 0, 0, 1000000),
                     PHASE_PI_RAD / 2.0))
        failures++;
    if (!phase_close(phase_from_complex(1000000, 0, 0, -1000000),
                     -PHASE_PI_RAD / 2.0))
        failures++;
    if (!phase_close(phase_from_complex(1000000, 0, -999848, 17452),
                     PHASE_PI_RAD * 179.0 / 180.0))
        failures++;
    if (!phase_close(phase_from_complex(1000000, 0, -999848, -17452),
                     -PHASE_PI_RAD * 179.0 / 180.0))
        failures++;
    if (!phase_close(phase_from_complex(1000000, 0, -1000000, 0),
                     -PHASE_PI_RAD))
        failures++;
    /* Swapping CH0/CH1 must reverse the sign. */
    if (!phase_close(phase_from_complex(866025, 500000, 1000000, 0),
                     -PHASE_PI_RAD / 6.0))
        failures++;

    return failures ? -failures : 0;
}

int spectrum_pl_init(void)
{
    u32 st;

    /* GPIO1 is the command toggle output; GPIO2 is the status input. */
    Xil_Out32(FFT_GPIO_BASE + GPIO_TRI1_OFFSET, 0x00000000U);
    Xil_Out32(FFT_GPIO_BASE + GPIO_TRI2_OFFSET, 0xFFFFFFFFU);
    Xil_Out32(FFT_GPIO_BASE + GPIO_DATA1_OFFSET, 0x00000000U);

    command_toggle = 0U;
    command_active = 0;
    result_valid = 0;
    result_sequence = 0U;
    timeout_count = 0U;
    command_start_ticks = 0;
    gpio_control_word = 0U;
    banked_mode = 0;
    bank_search_enabled = 0;
    bank_state = BANK_IDLE;
    pending_bank = 0U;
    pending_sequence = 0U;
    pending_frame_valid = 0;
    pending_stale_frame = 0;
    bank_timeout_reported = 0;
    pending_first_sample_id = 0U;
    pending_last_sample_id = 0U;
    frame_meta_valid = 0;
    cached_phase.valid = 0;
    cached_phase.sequence = 0U;
    st = Xil_In32(FFT_GPIO_BASE + GPIO_DATA2_OFFSET);
    if ((st & BANK_ABI_MASK) == BANK_ABI_MAGIC) {
        banked_mode = 1;
        pending_claim_ack = st & BANK_CLAIM_ACK;
        pending_release_ack = st & BANK_RELEASE_ACK;
        /* In banked mode bit 0 is a persistent run-enable level. It is not
         * toggled once per frame. Clearing it stops after the active frame. */
        gpio_control_word = 1U;
        bank_search_enabled = 1;
        Xil_Out32(FFT_GPIO_BASE + GPIO_DATA1_OFFSET, gpio_control_word);
        XTime_GetTime(&command_start_ticks);
        return 0;
    }
    expected_done_toggle = st & ST_DONE_MASK;

    if (st & ST_BUSY_MASK)
        return -1;

    start_frame();
    return 0;
}

int spectrum_pl_start_search(void)
{
    if (!banked_mode)
        return -1;
    gpio_control_word |= 1U;
    Xil_Out32(FFT_GPIO_BASE + GPIO_DATA1_OFFSET, gpio_control_word);
    bank_search_enabled = 1;
    bank_timeout_reported = 0;
    XTime_GetTime(&command_start_ticks);
    return 0;
}

int spectrum_pl_stop_search(void)
{
    if (!banked_mode)
        return -1;
    gpio_control_word &= ~1U;
    Xil_Out32(FFT_GPIO_BASE + GPIO_DATA1_OFFSET, gpio_control_word);
    bank_search_enabled = 0;
    return 0;
}

static int spectrum_pl_service_banked(void)
{
    SP_SCOPE(p,SP_FFT_BANK,bank_state,0);
    u32 st = bank_status();
    XTime now;

    if ((st & BANK_ABI_MASK) != BANK_ABI_MAGIC) {
        result_valid = 0;
        cached_phase.valid = 0;
        return SPECTRUM_PL_SERVICE_TIMEOUT;
    }

    if (bank_state == BANK_IDLE) {
        u32 mask = st & BANK_READY_MASK;
        u32 bank, seq;
        if (mask == 0U) {
            XTime_GetTime(&now);
            if (bank_search_enabled && !bank_timeout_reported &&
                (XTime)(now - command_start_ticks) >= FFT_PS_TIMEOUT_TICKS) {
                result_valid = 0;
                cached_phase.valid = 0;
                timeout_count++;
                bank_timeout_reported = 1;
                return SPECTRUM_PL_SERVICE_TIMEOUT;
            }
            return SPECTRUM_PL_SERVICE_IDLE;
        }

        /* The UI wants the latest complete result. A READY bank may have
         * been replaced by the owner; any racing claim is checked again. */
        bank = (mask & 1U) ? 0U : 1U;
        if (mask == 3U) {
            u32 seq0 = bank_read_selector(1U);
            u32 seq1 = bank_read_selector(6U);
            if ((s32)(seq0 - seq1) < 0)
                bank = 1U;
        }
        seq = bank_read_selector(bank ? 6U : 1U);
        st = bank_status();
        pending_bank = bank;
        pending_sequence = seq;
        pending_claim_ack = st & BANK_CLAIM_ACK;
        bank_command(bank, seq, 0);
        bank_state = BANK_CLAIM_WAIT;
        return SPECTRUM_PL_SERVICE_IDLE;
    }

    if (bank_state == BANK_CLAIM_WAIT) {
        if ((st & BANK_CLAIM_ACK) != pending_claim_ack) {
            u32 meta_base;
            u32 meta_sequence;
            u64 first_id, last_id;
            pending_frame_valid = 0;
            pending_stale_frame = 0;
            if (st & BANK_CLAIM_GRANTED) {
                /* The claimed bank cannot be recycled until RELEASE ACK.
                 * Re-read all metadata while it is held in READING. */
                meta_base = pending_bank ? 6U : 1U;
                meta_sequence = bank_read_selector(meta_base);
                first_id = bank_read_sample_id(meta_base + 1U);
                last_id = bank_read_sample_id(meta_base + 3U);
                if (meta_sequence == pending_sequence &&
                    ((last_id - first_id) & 0xFFFFFFFFFFFFULL) == 1023ULL &&
                    frame_meta_valid &&
                    (s32)(meta_sequence - cached_frame_meta.sequence) <= 0) {
                    /* Never replace a newer displayed frame with an older
                     * READY bank. Still RELEASE the stale bank. */
                    pending_stale_frame = 1;
                } else if (meta_sequence == pending_sequence &&
                           ((last_id - first_id) & 0xFFFFFFFFFFFFULL) == 1023ULL) {
                    result_valid = 0;
                    cached_phase.valid = 0;
                    convert_frame(ADC_SAMPLE_RATE_HZ_F, meta_sequence,
                                  pending_bank);
                    result_sequence = meta_sequence;
                    pending_first_sample_id = first_id;
                    pending_last_sample_id = last_id;
                    pending_frame_valid = 1;
                } else {
                    result_valid = 0;
                    cached_phase.valid = 0;
                }
                st = bank_status();
                pending_release_ack = st & BANK_RELEASE_ACK;
                bank_command(pending_bank, pending_sequence, 1);
                bank_state = BANK_RELEASE_WAIT;
            } else {
                /* A rejected claim is not a new frame. Keep the last
                 * completed result available to the display. */
                bank_state = BANK_IDLE;
            }
            return SPECTRUM_PL_SERVICE_IDLE;
        }
    } else if (bank_state == BANK_RELEASE_WAIT) {
        if ((st & BANK_RELEASE_ACK) != pending_release_ack) {
            int frame_result = pending_frame_valid &&
                               (st & BANK_RELEASE_GRANTED);
            if (frame_result) {
                result_valid = 1;
                cached_frame_meta.sequence = pending_sequence;
                cached_frame_meta.first_sample_id = pending_first_sample_id;
                cached_frame_meta.last_sample_id = pending_last_sample_id;
                cached_frame_meta.bank = pending_bank;
                frame_meta_valid = 1;
            } else if (!pending_stale_frame || !(st & BANK_RELEASE_GRANTED)) {
                result_valid = 0;
                cached_phase.valid = 0;
                frame_meta_valid = 0;
            }
            pending_frame_valid = 0;
            pending_stale_frame = 0;
            bank_state = BANK_IDLE;
            bank_timeout_reported = 0;
            XTime_GetTime(&command_start_ticks);
            return frame_result ? SPECTRUM_PL_SERVICE_FRAME
                                : SPECTRUM_PL_SERVICE_IDLE;
        }
    }

    XTime_GetTime(&now);
    if (!bank_timeout_reported &&
        (XTime)(now - command_start_ticks) >= FFT_PS_TIMEOUT_TICKS) {
        /* Keep waiting for the in-flight ACK: abandoning a late claim would
         * strand a Bank in READING. Report the fault once and keep polling. */
        result_valid = 0;
        cached_phase.valid = 0;
        timeout_count++;
        bank_timeout_reported = 1;
        return SPECTRUM_PL_SERVICE_TIMEOUT;
    }
    return SPECTRUM_PL_SERVICE_IDLE;
}

int spectrum_pl_service(void)
{
    if (banked_mode)
        return spectrum_pl_service_banked();
    u32 st = Xil_In32(FFT_GPIO_BASE + GPIO_DATA2_OFFSET);
    XTime now;

    if (!command_active) {
        if (!(st & ST_BUSY_MASK))
            start_frame();
        return SPECTRUM_PL_SERVICE_IDLE;
    }

    if ((st & ST_DONE_MASK) == expected_done_toggle) {
        XTime_GetTime(&now);
        if ((XTime)(now - command_start_ticks) < FFT_PS_TIMEOUT_TICKS)
            return SPECTRUM_PL_SERVICE_IDLE;

        /* Drop stale data and resynchronize with the observed DONE state.
         * If hardware is idle, immediately retry. If BUSY is stuck, leave the
         * command inactive so later calls do not repeatedly report timeouts. */
        command_active = 0;
        result_valid = 0;
        cached_phase.valid = 0;
        expected_done_toggle = st & ST_DONE_MASK;
        timeout_count++;
        if (!(st & ST_BUSY_MASK))
            start_frame();
        return SPECTRUM_PL_SERVICE_TIMEOUT;
    }

    command_active = 0;
    result_valid = 0;
    cached_phase.valid = 0;
    result_sequence++;
    if (!(st & ST_ERROR_MASK)) {
        convert_frame(ADC_SAMPLE_RATE_HZ_F, result_sequence, 0U);
        result_valid = 1;
    }

    /* Continuously keep a recent ADC-mode result ready for the LCD view. */
    if (!(st & ST_BUSY_MASK))
        start_frame();
    return SPECTRUM_PL_SERVICE_FRAME;
}

int spectrum_pl_get(const spectrum_t **ch0, const spectrum_t **ch1)
{
    if (!result_valid)
        return 0;
    if (ch0) *ch0 = &cached_ch0;
    if (ch1) *ch1 = &cached_ch1;
    return 1;
}

int spectrum_pl_get_phase(spectrum_phase_t *result)
{
    if (!result_valid)
        return 0;
    if (result)
        *result = cached_phase;
    return 1;
}

int spectrum_pl_get_frame_meta(spectrum_pl_frame_meta_t *result)
{
    if (!banked_mode || !result_valid || !frame_meta_valid)
        return 0;
    if (result)
        *result = cached_frame_meta;
    return 1;
}

u32 spectrum_pl_export_drop_count(void)
{
    return banked_mode ? bank_read_selector(11U) : 0U;
}

u32 spectrum_pl_export_abort_count(void)
{
    return banked_mode ? bank_read_selector(12U) : 0U;
}

u32 spectrum_pl_status(void)
{
    return banked_mode ? bank_status()
                       : Xil_In32(FFT_GPIO_BASE + GPIO_DATA2_OFFSET);
}

u32 spectrum_pl_timeout_count(void)
{
    return timeout_count;
}
