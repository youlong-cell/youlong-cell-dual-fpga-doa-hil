#ifndef ADC_G2_METRICS_H
#define ADC_G2_METRICS_H

/* Pure-C ADC word checks shared by the target firmware and host test.
 * The DMA stores a 12-bit offset-binary sample in each 16-bit word.  Exact
 * rail hits are evidence of clipping, not a proof that analog clipping is
 * absent when the counts are zero. */
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint16_t min_code;
    uint16_t max_code;
    uint32_t sum_codes;
    uint32_t rail_zero;
    uint32_t rail_full;
    uint32_t upper_bits_nonzero;
} adc_g2_metrics_t;

static inline void adc_g2_measure(const short *samples, size_t count,
                                  adc_g2_metrics_t *out)
{
    size_t i;

    if (out == NULL)
        return;
    out->min_code = 0;
    out->max_code = 0;
    out->sum_codes = 0;
    out->rail_zero = 0;
    out->rail_full = 0;
    out->upper_bits_nonzero = 0;
    if (samples == NULL || count == 0)
        return;

    out->min_code = 4095;
    for (i = 0; i < count; ++i) {
        uint16_t word = (uint16_t)samples[i];
        uint16_t code = word & 0x0fffU;
        if ((word & 0xf000U) != 0U)
            ++out->upper_bits_nonzero;
        if (code < out->min_code)
            out->min_code = code;
        if (code > out->max_code)
            out->max_code = code;
        out->sum_codes += code;
        if (code == 0U)
            ++out->rail_zero;
        if (code == 4095U)
            ++out->rail_full;
    }
}

#endif
