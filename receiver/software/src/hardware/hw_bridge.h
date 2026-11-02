/*
 * hw_bridge.h — 硬件抽象层(HAL)契约
 * ============================================================================
 * 本文件定义 app 层(状态机 / UI 编排) 对硬件层的【全部】依赖接口。
 *
 * 设计目标（服务于“电赛快速迁移”，而非工业级过度重构）：
 *   - 换板卡时，只需在 hardware/<board>/ 下提供这些函数的实现，
 *     app 与 algorithm 完全不动 → “硬件抽象层换皮、算法层不动”。
 *   - 本契约是【迁移清单】的边界定义：先把“必须适配哪些接口”钉死，
 *     再按题目/板卡逐板实现，避免在能跑的系统上做无谓的大规模重构。
 *
 * 当前 Zynq(AXU) 实现位置见每个函数注释，作为迁移时的对照表。
 *
 * 注意：本头文件为【契约/接口声明】，不包含实现。
 *       实现文件(hw_bridge_zynq.c 等)在题目/板卡确定后加入，
 *       由对应板卡的 build 选择编译，不影响现有工程编译（Phase A 不动运行代码）。
 * ============================================================================
 */
#ifndef HW_BRIDGE_H
#define HW_BRIDGE_H

#include <stdint.h>
#include <stddef.h>
#include "board_config.h"   /* 板相关宏：采样率/分辨率/FFT点数等，算法层也引用 */

#ifdef __cplusplus
extern "C" {
#endif

/* ===================== 0. 系统初始化 ===================== */

/*
 * hw_init — 统一系统初始化（时钟 / cache / DMA / miniDP / ADC / KEY）。
 * 成功返回 0。应用层 main() 只需调用一次。
 * 当前 Zynq 实现：main() 中的 Xil_DCacheEnable() + init_dma() + lcd_init()
 *                 + adc_init() 等散落调用，未来收敛为 hw_init() 一处。
 */
int hw_init(void);

/* ===================== 1. ADC / 采集 ===================== */

/*
 * hw_adc_init — 初始化 ADC 与采集 DMA。
 * 返回 0 成功，非 0 失败。
 * 当前 Zynq 实现：ad9238_sample.v 寄存器映射 + adc_dma_ctrl.c 中 XAxiDma 初始化。
 */
int hw_adc_init(void);

/*
 * hw_adc_start — 启动一次连续捕获(长度为 length 样本/通道)。
 * 关键顺序(工程记忆#33)：必须【先 armed DMA 再触发 ADC】，否则 ad9238 FIFO
 * (1024深@62.5MHz≈16µs填满)溢出丢数据。此细节对应用层隐藏。
 * 返回 0 成功。
 * 当前 Zynq 实现：main.c adc_start_capture()（先 XAxiDma_SimpleTransfer 再
 *                 ad9238_sample()）。
 */
int hw_adc_start(uint32_t length);

/*
 * hw_adc_wait — 阻塞等待本次捕获完成（DMA 中断/S2MM 标志）。
 * 返回 0 完成，非 0 异常。不同平台实现不同（Zynq 轮询 ch0_s2mm_flag；
 * STM32 可用 DMA TC 中断；MicroBlaze 轮询 IP 状态寄存器）。
 */
int hw_adc_wait(void);

/*
 * hw_adc_get_buffer — 取指定通道的采样缓冲(16-bit 样本数组)。
 * channel: 0=CH0, 1=CH1。返回 CPU 可直接 FFT/FIR 的指针。
 * 当前 Zynq 实现：CH0DmaRxBuffer / CH1DmaRxBuffer（DDR 物理映射）。
 */
uint16_t *hw_adc_get_buffer(int channel);

/*
 * hw_adc_get_samplerate — 返回 ADC 实际采样率(Hz)，即“时间基准”。
 * ★ 关键接口：FFT 频率轴、RBW、zoom 等效采样率全部依赖它。
 *   换 ADC(20M/50M/100M) 时只有此函数变，algorithm 层零改动。
 * 当前 Zynq 实测 62.5 MHz。zoom 等效 = 此值 / FIR_DECIM_M(60)。
 */
float hw_adc_get_samplerate(void);

/*
 * hw_adc_present — 硬件是否接了 ADC 模块。
 * 返回 1=有 ADC, 0=无。无模块时禁止访问 ADC 寄存器(否则 AXI DECERR/Data Abort)。
 * 应用层据此决定是否进入 ADC 相关模式。
 */
int hw_adc_present(void);

/* ===================== 2. DMA(可选，高速场景) ===================== */

/*
 * hw_dma_init — 初始化 DMA 控制器。简单场景由 hw_adc_init 内部调用即可，
 * 此函数保留给未来高速/ping-pong/SG DMA 场景。
 */
int hw_dma_init(void);

/*
 * hw_dma_transfer — 通用 DMA 传输(地址 addr, 长度 len 字节)。
 * 未来支持单 buffer / ping-pong / SG。当前 Zynq 由 XAxiDma_SimpleTransfer 承担。
 */
int hw_dma_transfer(void *addr, uint32_t len);

/* ===================== 3. PS miniDP 显示 ===================== */

/*
 * hw_display_init — 初始化 PS DisplayPort / DPDMA 与帧缓冲。
 * 成功返回 0。
 * 当前 Zynq 实现：display_ctrl.c(DisplayCtrl)，不使用旧 PL LCD IP。
 */
int hw_display_init(void);

/*
 * hw_display_get_frame — 获取当前可写帧缓冲指针与几何参数。
 * frame: 输出帧缓冲首地址(CPU 写像素用)；width/height/stride: 输出分辨率与步长。
 * 当前 Zynq 实现：dispCtrl.framePtr[curFrame] / dispCtrl.vMode / dispCtrl.stride。
 * 注：lcd_draw_* 系列是【板无关渲染】，不在此声明，归入 algorithm/display。
 */
void hw_display_get_frame(uint8_t **frame, int *width, int *height, int *stride);

/*
 * hw_display_flush — 将 CPU 写入的帧缓冲推到屏幕。
 * Zynq: Xil_DCacheFlushRange() + DisplayChangeFrame()；STM32: LTDC_Refresh()。
 * 必须 flush，否则 PS DPDMA 可能看不到最新像素。
 * 成功返回 0。
 */
int hw_display_flush(void);

/* ===================== 4. 按键 / 输入 ===================== */

/*
 * hw_key_get — 读取用户输入(KEY1 / 触摸 / 串口 / 手机，按板卡替换)。
 * 返回按键编码(0=无)。当前 Zynq 实现：XGpio_DiscreteRead(&Gpio,1) 读 1 位 KEY1。
 */
int hw_key_get(void);

#ifdef __cplusplus
}
#endif

#endif /* HW_BRIDGE_H */
