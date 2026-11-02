/*
 * spectrum.h - Spectrum analyzer interface for FFT-based frequency display
 *
 * Takes raw ADC samples, applies Hann window, computes 1024-point FFT,
 * and returns magnitude spectrum in dB scale.
 *
 * ADC sample rate: 62.5 MHz (PL clock = FCLK_CLK1 / 2)
 * Frequency resolution: 62.5 MHz / 1024 = 61.0 kHz
 * Max displayable frequency: 31.25 MHz (Nyquist)
 * Positive bins (DC to Nyquist): 512
 */

#ifndef SPECTRUM_H
#define SPECTRUM_H

#define FFT_SIZE    1024
#define FFT_BINS    (FFT_SIZE / 2)   /* 512 positive frequency bins */
#define SPEC_DB_FLOOR    -120.0f     /* noise floor in dB */

typedef struct {
    float freq[FFT_BINS];       /* bin center frequency (Hz) */
    float mag_db[FFT_BINS];     /* magnitude in dBFS */
    float fs;                   /* sample rate (Hz) */
    float freq_resolution;      /* fs / FFT_SIZE (Hz per bin) */
    float max_mag_db;           /* peak magnitude among all bins */
    float min_mag_db;           /* floor magnitude among all bins */
} spectrum_t;

/*
 * Compute frequency spectrum from raw ADC samples.
 *
 * samples:  array of unsigned 12-bit ADC codes [0..4095]
 *           DC offset = 2048 (0V). Will be subtracted internally.
 * count:    number of samples available (must be >= FFT_SIZE=1024,
 *           but extra samples beyond 1024 are ignored)
 * spec:     output spectrum (caller-allocated)
 * fs:       ADC sample clock in Hz (use 100e6 for 100 MHz)
 *
 * The FFT config is allocated once and cached (static, NOT thread-safe).
 */
void spectrum_compute(const unsigned short *samples, int count,
                      spectrum_t *spec, float fs);

/*
 * Compute THD (Total Harmonic Distortion) from spectrum.
 * Searches for fundamental + harmonics at 2f-5f.
 *
 * Returns THD as percentage (0.0 = perfect sine).
 * *fund_freq: fundamental frequency in Hz (if found)
 * *fund_db:   fundamental magnitude in dBFS (if found)
 *
 * If no meaningful fundamental is found, returns -1.0f.
 */
float spectrum_thd(spectrum_t *spec, float *fund_freq, float *fund_db);

/*
 * Classify waveform type from harmonic pattern.
 * Returns static string: "SIN", "SQR", "TRI", "SAW", or "???".
 *
 * Classification logic:
 *   SIN  - THD < 0.8%, pure fundamental
 *   SQR  - strong 3rd/5th odd harmonics, weak even harmonics
 *   TRI  - odd harmonics present, falling as 1/n^2
 *   SAW  - both odd and even harmonics, falling as 1/n
 *   ???  - no significant fundamental detected
 */
const char* spectrum_classify(spectrum_t *spec);

#endif /* SPECTRUM_H */
