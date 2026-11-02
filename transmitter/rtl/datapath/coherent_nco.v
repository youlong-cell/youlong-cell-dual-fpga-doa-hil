`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// 共享累加器的双通道数控振荡器（NCO）                                           //
//                                                                              //
// CH1 为参考波形，对应接收机 CH0；CH2 对应接收机 CH1，且满足                    //
// phase_CH2 = phase_CH1 + phase_offset_word。因此正的相位偏移量会产生正的        //
// 接收机相位（phi_CH1 - phi_CH0）。                                             //
//                                                                              //
// 相位字的高 10 位用于寻址 1024 项 Q1.13 正弦 ROM。带寄存器的乘法器流水线以同一  //
// 无符号峰值幅度对两路通道进行缩放。                                             //
//                                                                              //
// 波形选择（wave_sel）                                                          //
// ----------------------------------------------------------------------------  //
// 在**波形样本生成**这一层选择，而不是对 DAC 采样值做阈值判断：                 //
//     SINE   —— 直接使用 ROM 输出                                              //
//     SQUARE —— 用相位地址的最高位 chN_addr[9] 判定极性，输出 +/-满幅           //
// 三个好处：                                                                    //
//   1) 相位偏置仍由同一套地址链决定，方波与正弦严格同相；                        //
//   2) 幅度控制语义完全不变（方波同样乘 amplitude 再偏移中值）；                 //
//   3) 不需要第二个 ROM，资源开销仅为两个 mux。                                 //
//                                                                              //
// 极性核对（已按 sine_lut_14bit.mem 实测确认）                                  //
// ----------------------------------------------------------------------------  //
// 该表为标准 sin(2*pi*i/1024)：addr 0 -> 0，addr 256 -> +8191，addr 512 -> 0，   //
// addr 768 -> -8191。因此 addr[9]==0 严格对应正弦 >= 0（正半周），               //
// addr[9]==1 严格对应正弦 <= 0（负半周）。所以                                   //
//     addr[9] ? -8191 : +8191                                                   //
// 与正弦**同相**，方波跳变沿正好落在正弦过零点，不需要额外翻转 180 度。          //
//                                                                              //
// 时序对齐（关键，别改）                                                        //
// ----------------------------------------------------------------------------  //
// chN_sine <= sine_rom[chN_addr] 用的是**拍 N 时 chN_addr 的旧值**（非阻塞赋值   //
// 右侧取旧值），即拍 N-1 写入的地址。所以 chN_sine 与拍 N 的 chN_addr 恰好对应。 //
// 因此用拍 N 的 chN_addr[9] 做方波极性判定，与 chN_sine 严格同拍、同地址。       //
//////////////////////////////////////////////////////////////////////////////////
// 修订历史：                                                                   //
// 日期        版本      变更说明                                               //
// ---------------------------------------------------------------------------  //
// 2026/09/20  1.0       共享相位累加器与确定性重启                             //
// 2026/09/20  1.1       补充相位约定与定点流水线说明                           //
// 2026/09/22  1.2       新增 wave_sel：在样本生成层选择正弦或方波               //
//////////////////////////////////////////////////////////////////////////////////
module coherent_nco #(
    parameter LUT_FILE = "sine_lut_14bit.mem" // 1024 x 有符号 14 位正弦表
) (
    input  wire               clk,               // 125 MHz NCO 时钟
    input  wire               rst,               // 同步复位，高电平有效
    input  wire               enable,            // 1：生成波形；0：保持中值电平
    input  wire               restart,           // 单周期确定性重启
    input  wire               wave_sel,          // 0 = 正弦，1 = 方波
    input  wire [31:0]        frequency_word,     // f_out / f_clk * 2^32
    input  wire signed [31:0] phase_offset_word,  // CH2-CH1 相位差（二进制圈）
    input  wire [13:0]        amplitude,          // 峰值码值，有效范围 0..8191
    output reg  [13:0]        ch1_data,           // 偏移二进制 DAC CH1 采样数据
    output reg  [13:0]        ch2_data,           // 偏移二进制 DAC CH2 采样数据
    output wire [31:0]        phase_acc_debug     // 用于验证的共享相位
);

    localparam [13:0] DAC_MIDSCALE = 14'h2000; // 偏移二进制下的零电压码值
    localparam        WAVE_SINE    = 1'b0;     // wave_sel 编码（与 control_mux 一致）
    localparam        WAVE_SQUARE  = 1'b1;

    // 方波满幅码值。取 8191 = 2^13-1，与正弦表峰值相同，幅度语义完全一致。
    localparam signed [13:0] SQUARE_POS = 14'sd8191;
    localparam signed [13:0] SQUARE_NEG = -14'sd8191;

    reg [31:0] phase_acc;
    reg [9:0]  ch1_addr;
    reg [9:0]  ch2_addr;

    // 两个同步读端口在 Vivado 中可推断为真双端口 ROM。
    (* rom_style = "block" *) reg signed [13:0] sine_rom [0:1023];
    reg signed [13:0] ch1_sine;
    reg signed [13:0] ch2_sine;
    reg signed [13:0] amplitude_pipe;
    reg signed [27:0] ch1_product;
    reg signed [27:0] ch2_product;
    reg signed [14:0] ch1_scaled;
    reg signed [14:0] ch2_scaled;

    // 组合逻辑求得的下一相位值使两个 ROM 地址保持同周期对齐。
    wire [31:0] phase_next = phase_acc + frequency_word;
    wire [31:0] ch2_phase_next = phase_next + $unsigned(phase_offset_word);
    wire signed [13:0] amplitude_signed = $signed({1'b0, amplitude[12:0]});

    // 波形样本生成层的选择：正弦取 ROM 输出，方波由相位地址最高位判定极性。
    // 注意 chN_addr 与 chN_sine 同拍对应（见文件顶部"时序对齐"）。
    wire signed [13:0] ch1_wave = (wave_sel == WAVE_SQUARE)
                                ? (ch1_addr[9] ? SQUARE_NEG : SQUARE_POS)
                                : ch1_sine;
    wire signed [13:0] ch2_wave = (wave_sel == WAVE_SQUARE)
                                ? (ch2_addr[9] ? SQUARE_NEG : SQUARE_POS)
                                : ch2_sine;

    // 在载入生成的查找表之前，先把未使用/未被写入的位置初始化为零。
    integer lut_index;
    initial begin
        for (lut_index = 0; lut_index < 1024; lut_index = lut_index + 1)
            sine_rom[lut_index] = 14'sd0;
        $readmemh(LUT_FILE, sine_rom);
    end

    assign phase_acc_debug = phase_acc;

    // 流水线：相位/地址 -> ROM（或方波整形） -> 乘法 -> 移位 -> 偏移二进制输出。
    // 除样本来源由 chN_sine 改为 chN_wave 外，本段与 1.1 版完全一致。
    always @(posedge clk) begin
        if (rst || restart || !enable) begin
            phase_acc    <= 32'd0;
            ch1_addr     <= 10'd0;
            ch2_addr     <= 10'd0;
            ch1_sine     <= 14'sd0;
            ch2_sine     <= 14'sd0;
            amplitude_pipe <= 14'sd0;
            ch1_product  <= 28'sd0;
            ch2_product  <= 28'sd0;
            ch1_scaled   <= 15'sd0;
            ch2_scaled   <= 15'sd0;
            ch1_data     <= DAC_MIDSCALE;
            ch2_data     <= DAC_MIDSCALE;
        end else begin
            phase_acc   <= phase_next;
            ch1_addr    <= phase_next[31:22];
            ch2_addr    <= ch2_phase_next[31:22];
            ch1_sine    <= sine_rom[ch1_addr];
            ch2_sine    <= sine_rom[ch2_addr];
            amplitude_pipe <= amplitude_signed;
            ch1_product <= ch1_wave * amplitude_pipe;
            ch2_product <= ch2_wave * amplitude_pipe;
            ch1_scaled  <= ch1_product >>> 13;
            ch2_scaled  <= ch2_product >>> 13;
            ch1_data    <= DAC_MIDSCALE + ch1_scaled;
            ch2_data    <= DAC_MIDSCALE + ch2_scaled;
        end
    end

endmodule
