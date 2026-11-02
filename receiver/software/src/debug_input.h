#ifndef DEBUG_INPUT_H
#define DEBUG_INPUT_H
#include <stdint.h>
#include <stddef.h>
#include "spectrum.h"

/* Engineering diagnostics only: not a detector, calibration or DOA gate. */
typedef enum { INPUT_NOT_READY, INPUT_NO_SIGNAL, INPUT_NOISE_ONLY,
               INPUT_SIGNAL_DETECTED } debug_input_state_t;
typedef struct {
    unsigned bin_min, bin_max;
    double no_signal_rms_codes;
    float min_peak_dbfs, min_prominence_db;
} debug_input_config_t;
typedef struct {
    uint16_t min, max;
    uint32_t mean, rms_millicodes, rail_count;
    size_t count;
    int valid;
} debug_adc_metrics_t;
typedef struct {
    unsigned valid, bin, valid_bins;
    uint64_t hz;
    float dbfs, prominence_db;
    int32_t dbfs_milli, prominence_milli;
} debug_peak_t;
extern const debug_input_config_t debug_input_default_config;
int debug_adc_measure(const uint16_t *raw, size_t count, debug_adc_metrics_t *out);
void debug_peak_measure(const spectrum_t *spec, const debug_input_config_t *cfg,
                        debug_peak_t *out);
debug_input_state_t debug_input_classify(int adc_fresh, int fft_fresh,
    uint32_t rms_millicodes, int overflow, const debug_peak_t *peak,
    const debug_input_config_t *cfg);
debug_input_state_t debug_input_pair(debug_input_state_t a, debug_input_state_t b);
const char *debug_input_name(debug_input_state_t state);
/* No %f anywhere in UART/UI. Invalid/nonfinite values are not formatted. */
void debug_format_milli(char *out, size_t capacity, int64_t value);
#endif
