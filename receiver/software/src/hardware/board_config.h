/*
 * board_config.h — 板卡相关配置（未来接入，Phase A 仅为骨架）
 * ============================================================================
 * 本文件集中定义所有“板相关常量”，使 algorithm 层(fft/fir/thd/display)
 * 通过宏引用而不写死，实现“换板只改此文件 + hw_bridge_<board>.c”。
 *
 * 采样率已由 sample_clock.h 作为唯一软件来源，当前工程与未来硬件抽象层
 * 必须引用同一宏，不得再次定义近似值。
 * ============================================================================
 */
#ifndef BOARD_CONFIG_H
#define BOARD_CONFIG_H

#include "sample_clock.h"

/* ---------------- 平台族 ---------------- */
#define PLATFORM_FAMILY_ZYNQ    1   /* 1=Zynq/SoC(有ARM PS), 0=MicroBlaze/STM32 */

/* ---------------- ADC ---------------- */
#define ADC_BITS                12
#define ADC_CHANNELS            2
#define ADC_VREF_V              2.0f
#define ADC_ZERO_OFFSET         (1u << (ADC_BITS - 1))   /* 12-bit -> 2048 */

/* ---------------- 捕获 / FFT ---------------- */
#define ADC_CAPTURELEN          1920        /* 全频单次捕获长度(样本/通道) */
#ifndef ZOOM_RAW_LEN
#define ZOOM_RAW_LEN            61440       /* 放大模式单次连续捕获长度 */
#endif
#define FFT_SIZE                1024
#define FFT_BINS                (FFT_SIZE / 2)

/* ---------------- 放大 / FIR 抽取 ---------------- */
#define FIR_DECIM_M             60          /* 抽取因子：62.5M/60 ~= 1.042M */
#define FIR_DECIM_N             1800        /* 多相 FIR 抽头数(每相30) */
#ifndef ZOOM_FS_EFF_HZ
#define ZOOM_FS_EFF_HZ          (ADC_SAMPLE_RATE_HZ / FIR_DECIM_M)
#endif

/* ---------------- 显示 ---------------- */
#define DISP_WIDTH              800
#define DISP_HEIGHT             480
#define DISP_BPP                3           /* BGR 3字节/像素 */
#define DISP_STRIDE             (DISP_WIDTH * DISP_BPP)
#define DISPLAY_NUM_FRAMES      3

/* ---------------- DMA 类型（未来扩展） ---------------- */
#define DMA_TYPE_SIMPLE         0           /* 0=简单单次, 1=ping-pong, 2=SG */

/* ---------------- 存储 ---------------- */
#define STORAGE_TYPE_SD         1           /* 0=无存储 */

#endif /* BOARD_CONFIG_H */
