#ifndef SAMPLE_CLOCK_H
#define SAMPLE_CLOCK_H

/*
 * Authoritative receiver sample clock.
 *
 * Source of truth: current Vivado design_1.bd,
 *   PSU__CRL_APB__PL1_REF_CTRL__ACT_FREQMHZ = 62.499374
 * and the connected adc_clk interface metadata,
 *   FREQ_HZ = 62499374.
 *
 * All PS frequency axes, FIR normalization, zoom rates, and experiment
 * metadata must derive from this value. Do not add rounded 62.5 MHz literals
 * to application or DSP code. If the Vivado clock changes, update this file
 * in the same change and run the sample-rate consistency check.
 */
#define ADC_SAMPLE_RATE_HZ       62499374UL
#define ADC_SAMPLE_RATE_HZ_F     ((float)ADC_SAMPLE_RATE_HZ)
#define ADC_SAMPLE_RATE_HZ_D     ((double)ADC_SAMPLE_RATE_HZ)

#endif /* SAMPLE_CLOCK_H */
