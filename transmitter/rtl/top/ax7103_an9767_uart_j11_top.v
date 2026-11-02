`timescale 1ns / 1ps
// HIL20_UART J11 board top, mechanically derived from the Stage-A top.
`include "uart_baud_config.vh"
// J11.3/P16 RX, J11.4/R17 TX; configured baud is NOT an HC05 factory claim.
// KEY0 cycle / KEY1 toggle, amplitude1024, original mode words and DAC tail retained.
// UART + keys share hil20_control; PLL/reset/LED/NCO/IOB/ODDR remain original.
// ENGINEERING_ONLY / NOT_SIGNED_OFF / NOT_BOARD_TESTED.

module ax7103_an9767_uart_j11_top #(
    // 按键消抖拍数。默认 = 20 ms @ 125 MHz。
    // **测试平台必须覆盖这个参数**，否则每次按键要跑 20 ms 仿真时间，
    // 整机回归会被拖到不可接受的长度。
    parameter integer KEY_DEBOUNCE_CYCLES = 2_500_000,
    parameter integer KEY_CNT_WIDTH       = 22,
    parameter integer LED_BLINK_HALF_CYCLES = 31_250_000,
    parameter integer UART_BAUD_RATE = `HIL20_UART_BAUD, // selected at build time
    parameter integer UART_LINE_TIMEOUT_CYCLES = 31_250_000,
    parameter integer UART_USE_LINK_STATUS = 0
) (
    input  wire        sys_clk_p, // 200 MHz 差分系统时钟，P 端
    input  wire        sys_clk_n, // 200 MHz 差分系统时钟，N 端
    input  wire        rst_n,     // 异步外部复位，低电平有效
    input  wire        uart_rx,   // J11.3/P16; HC05 TXD
    output wire        uart_tx,   // J11.4/R17; HC05 RXD
    input  wire [1:0]  key_in,    // 板载按键，低有效：bit0 = KEY0(模式)，bit1 = KEY1(开关)
    output wire [3:0]  led,       // 板载LED：频率/参考角，-60deg闪烁
    output wire        da1_clk,   // AN9767 通道 1 转发时钟
    output wire        da1_wrt,   // AN9767 通道 1 写选通信号
    output wire [13:0] da1_data,  // AN9767 通道 1 偏移二进制采样数据
    output wire        da2_clk,   // AN9767 通道 2 转发时钟
    output wire        da2_wrt,   // AN9767 通道 2 写选通信号
    output wire [13:0] da2_data   // AN9767 通道 2 偏移二进制采样数据
);

    // 生成供全部信号源逻辑与 DAC 引脚使用的唯一 125 MHz 时钟。
    wire dac_clk_125m;
    wire pll_locked;

    dac_pll dac_pll_inst (
        .clk_in1_p(sys_clk_p),
        .clk_in1_n(sys_clk_n),
        .reset    (!rst_n),
        .clk_out1 (dac_clk_125m),
        .locked   (pll_locked)
    );

    // 保持原本域同步复位采纳与三拍释放，不更改时序。
    // 保持复位直到 PLL 锁定，使 NCO 的启动过程可重复。
    wire dac_rst;
    hil20_reset_release reset_release_inst(
        .clk(dac_clk_125m),.rst_n(rst_n),.pll_locked(pll_locked),.dac_rst(dac_rst));

    // No external STATE pin. UART_USE_LINK_STATUS=0; do not load old CP2102 XDC.

    // ==========================================================================
    // 原按键同步/去抖通路（统一仲裁的本地输入）
    // ==========================================================================
    // KEY0（key_in[0]）：每按一次把模式循环推进一格。
    // KEY1（key_in[1]）：输出使能开关（按下翻转），与模式正交、不触发重启。
    // 消抖计数默认 20 ms @ 125 MHz = 2,500,000 拍；测试平台用短值覆盖。
    wire key0_press;
    wire key1_press;

    hil20_key_inputs #(.KEY_DEBOUNCE_CYCLES(KEY_DEBOUNCE_CYCLES),.KEY_CNT_WIDTH(KEY_CNT_WIDTH)) keys_inst(
        .clk(dac_clk_125m),.rst(dac_rst),.key_in(key_in),
        .key0_press(key0_press),.key1_press(key1_press));

    // KEY1 toggle and UART absolute output control share one enable owner.
    // KEY1 target_enable now has exactly one owner in hil20_control.

    // ==========================================================================
    // 模式表：唯一的参数来源，直接驱动 NCO
    // ==========================================================================
    wire [4:0]  mode_index;
    wire [31:0] frequency_word;
    wire [13:0] amplitude;
    wire        wave_sel;
    wire signed [31:0] phase_offset_word;
    wire        output_enable;
    wire        restart_pulse;
    wire custom_active;
    wire [1:0] active_frequency_index;
    wire signed [10:0] active_angle_tenths;

    hil20_uart_control #(.CLOCK_HZ(125000000),.BAUD_RATE(UART_BAUD_RATE),
        .LINE_TIMEOUT_CYCLES(UART_LINE_TIMEOUT_CYCLES),.USE_LINK_STATUS(UART_USE_LINK_STATUS)) uart_control_inst (
        .clk              (dac_clk_125m),
        .rst              (dac_rst),
        .key0_press       (key0_press),
        .key1_press       (key1_press),
        .uart_rx(uart_rx),.uart_tx(uart_tx),.uart_link_up(1'b1),
        .mode_index       (mode_index),
        .frequency_word   (frequency_word),
        .amplitude        (amplitude),
        .wave_sel         (wave_sel),
        .phase_offset_word(phase_offset_word),
        .output_enable    (output_enable),
        .restart_pulse    (restart_pulse),
        .custom_active(custom_active),.active_frequency_index(active_frequency_index),.active_angle_tenths(active_angle_tenths),
        .control_busy(),.dropped_reply_count(),.key_overflow(),.reply_busy()
    );

    // 单向LED观察支路；不得反馈到NCO、模式参数、enable或restart。
    hil20_led_status #(.LED_BLINK_HALF_CYCLES(LED_BLINK_HALF_CYCLES)) led_status_inst(
        .clk(dac_clk_125m),.rst(dac_rst),.mode_index(mode_index),.led(led),
        .custom_active(custom_active),.active_frequency_index(active_frequency_index));

    // 由同一个共享相位累加器生成的相干采样数据。
    wire [13:0] nco_ch1_data;
    wire [13:0] nco_ch2_data;

    coherent_nco nco_inst (
        .clk              (dac_clk_125m),
        .rst              (dac_rst),
        .enable           (output_enable),
        .restart          (restart_pulse),
        .wave_sel         (wave_sel),
        .frequency_word   (frequency_word),
        .phase_offset_word(phase_offset_word),
        .amplitude        (amplitude),
        .ch1_data         (nco_ch1_data),
        .ch2_data         (nco_ch2_data),
        .phase_acc_debug  ()
    );

    // 将数据发射寄存器置于 IOB 内。数据在内部时钟上升沿发生变化；
    // WRT/CLK 在内部时钟下降沿上升，从而在 125 MHz 下、扣除板级与封装
    // 偏斜之前，仍保有名义上的 4 ns 建立与保持时间。
    (* IOB = "TRUE" *) reg [13:0] da1_data_reg;
    (* IOB = "TRUE" *) reg [13:0] da2_data_reg;
    always @(posedge dac_clk_125m) begin
        if (dac_rst) begin
            da1_data_reg <= 14'h2000;
            da2_data_reg <= 14'h2000;
        end else begin
            da1_data_reg <= nco_ch1_data;
            da2_data_reg <= nco_ch2_data;
        end
    end

    assign da1_data = da1_data_reg;
    assign da2_data = da2_data_reg;

    // 有意采用 ODDR 转发时钟。D1=0/D2=1 会在 dac_clk_125m 的
    // 下降沿产生上升沿，正好位于数据有效窗口的中央。
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("ASYNC"))
        dac_clk_oddr_ch1 (.C(dac_clk_125m), .CE(1'b1), .D1(1'b0), .D2(1'b1), .Q(da1_clk), .R(dac_rst), .S(1'b0));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("ASYNC"))
        dac_wrt_oddr_ch1 (.C(dac_clk_125m), .CE(1'b1), .D1(1'b0), .D2(1'b1), .Q(da1_wrt), .R(dac_rst), .S(1'b0));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("ASYNC"))
        dac_clk_oddr_ch2 (.C(dac_clk_125m), .CE(1'b1), .D1(1'b0), .D2(1'b1), .Q(da2_clk), .R(dac_rst), .S(1'b0));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("ASYNC"))
        dac_wrt_oddr_ch2 (.C(dac_clk_125m), .CE(1'b1), .D1(1'b0), .D2(1'b1), .Q(da2_wrt), .R(dac_rst), .S(1'b0));

endmodule
