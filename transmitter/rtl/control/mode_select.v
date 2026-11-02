`timescale 1ns / 1ps
// HIL20_UART candidate: original 20-mode tables and restart pipeline retained.
// Unique NCO parameter owner: preset table or validated custom tuple, atomically.
// Arbitrator guarantees mutually exclusive mode_press / set_valid / custom_set_valid.

module mode_select #(
    // 全部模式共用的峰值幅度。有效范围 0..8191（14 位无符号峰值码）。
    parameter [13:0] LOCAL_AMPLITUDE = 14'd1024
) (
    input  wire               clk,               // 125 MHz
    input  wire               rst,               // 同步复位，高电平有效
    input  wire               mode_press,        // KEY0 按击脉冲（单周期）
    input  wire               target_enable,     // KEY1 的开关状态（1 = 输出开）
    input  wire               set_valid,         // candidate: accepted discrete mode only
    input  wire [4:0]         set_mode,
    input  wire               custom_set_valid,
    input  wire [31:0]         custom_frequency_word,
    input  wire signed [31:0] custom_phase_word,
    input  wire [1:0]          custom_frequency_index,
    input  wire signed [10:0] custom_angle_tenths,
    output reg                custom_active,
    output reg [1:0]          active_frequency_index,
    output reg signed [10:0] active_angle_tenths,
    output reg  [4:0]         mode_index,        // 当前模式，顶层独立译码LED
    output reg  [31:0]        frequency_word,    // 相位增量 = f_out/125MHz * 2^32
    output reg  [13:0]        amplitude,         // 峰值幅度
    output reg                wave_sel,          // 0 = 正弦，1 = 方波
    output reg  signed [31:0] phase_offset_word, // CH2-CH1 相位差
    output reg                enable,            // 送 NCO 的 enable
    output reg                restart_pulse      // 单周期确定性重启
);

    // 波形选择编码。数值与 coherent_nco 内部的 localparam 必须一致。
    // 本版本20个模式全部使用正弦；方波能力保留在 NCO 中以便日后复用
    // （例如把某个相位档改回方波做 DAC/时序直观检查），本表不使用。
    localparam WAVE_SINE   = 1'b0;
    localparam WAVE_SQUARE = 1'b1;

    // 模式知识由唯一配置生成；本模块只拥有参数提交与重启时序。
    `include "generated/mode_select_tables.vh"

    // 两拍序列只用一个标志：参数在本拍提交，下一拍发 restart。
    reg pending_restart = 1'b0;
    wire [4:0] next_mode_index = next_mode_of(mode_index);

    always @(posedge clk) begin
        if (rst) begin
            // 上电默认 = 模式 0（1 MHz / 0 度），即 G1 第一组的第一个测试点。
            // 输出默认关闭（enable=0），DAC 两路停在直流中值 —— 刻意的安全默认。
            mode_index        <= 5'd0;
            custom_active     <= 1'b0;
            active_frequency_index <= 0;
            active_angle_tenths <= 0;
            frequency_word    <= freq_word_of(5'd0);
            phase_offset_word <= $signed(phase_word_of(5'd0));
            wave_sel          <= WAVE_SINE;
            amplitude         <= LOCAL_AMPLITUDE;
            enable            <= 1'b0;
            restart_pulse     <= 1'b0;
            pending_restart   <= 1'b0;
        end else begin
            restart_pulse <= 1'b0;                 // 默认不高，只有 COMMIT 拍才置起

            if (custom_set_valid) begin
                mode_index<=5'd31;custom_active<=1;
                frequency_word<=custom_frequency_word;phase_offset_word<=custom_phase_word;
                active_frequency_index<=custom_frequency_index;active_angle_tenths<=custom_angle_tenths;
                wave_sel<=WAVE_SINE;pending_restart<=1;
            end else if (mode_press || set_valid) begin
                // ---- Cycle N：按照显式20状态表提交新参数 ----
                // 不用索引高低位推断频率/相位，保留5MHz8..12编号。
                // 保证提交的参数与即将点亮的 LED 编码严格一致。
                mode_index        <= mode_press ? next_mode_index : set_mode;
                custom_active     <= 0;
                active_frequency_index<=frequency_index_of(mode_press ? next_mode_index : set_mode);
                active_angle_tenths<=angle_of(mode_press ? next_mode_index : set_mode);
                frequency_word    <= freq_word_of(mode_press ? next_mode_index : set_mode);
                phase_offset_word <= $signed(phase_word_of(mode_press ? next_mode_index : set_mode));
                wave_sel          <= WAVE_SINE;

                pending_restart   <= 1'b1;         // 下一拍发重启
            end

            // ---- Cycle N+1：发确定性重启脉冲 ----
            if (pending_restart) begin
                restart_pulse   <= 1'b1;
                pending_restart <= 1'b0;
            end

            // target_enable 只跟随 KEY1：开关是电平行为，本身不触发重启。
            // （coherent_nco 在 !enable 期间把相位累加器压回 0，
            //   所以 enable 的每一次 0->1 都自然带来一次确定性起始。）
            enable <= target_enable;
        end
    end

endmodule
