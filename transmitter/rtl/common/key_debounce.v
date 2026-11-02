`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// 按键消抖与按击事件提取                                                        //
//                                                                              //
// AX7103 板载按键为**低电平有效**：松开为 1，按下为 0（与 ALINX 02_key_test     //
// 例程一致）。本模块把物理按键整理成"按一次报一次"的单周期脉冲。                //
//                                                                              //
// 处理链：                                                                      //
//     异步输入 -> 两级同步（防亚稳态） -> 计数器消抖 -> 下降沿检测 -> press_pulse //
//                                                                              //
// 消抖原理：只有当同步后的电平**连续保持 DEBOUNCE_CYCLES 拍不变**时，才承认它   //
// 是一次真实变化。机械按键的抖动通常在 5~20 ms 量级，因此 20 ms 足够。           //
//                                                                              //
// 为什么必须参数化（重要）                                                      //
// ------------------------                                                      //
// 125 MHz 下 20 ms = 2,500,000 拍。若仿真里也用这个值，光一次按键就要跑 20 ms    //
// 仿真时间，整个回归会被拖慢到不可接受。因此 DEBOUNCE_CYCLES 必须可在例化时       //
// 覆盖；测试平台用几十拍即可验证同一套逻辑。                                     //
//                                                                              //
// 输出语义：                                                                    //
//     press_pulse —— 每次"确认按下"输出一个 clk 周期的 1，其余时刻为 0           //
//     key_state   —— 消抖后的稳定电平（低有效，按下为 0），供状态指示使用        //
//////////////////////////////////////////////////////////////////////////////////
// 修订历史：                                                                   //
// 日期        版本      变更说明                                               //
// ---------------------------------------------------------------------------  //
// 2026/09/22  1.0       两级同步 + 参数化消抖 + 按击脉冲                       //
//////////////////////////////////////////////////////////////////////////////////

module key_debounce #(
    // 连续稳定多少拍才承认电平变化。默认值 = 20 ms @ 125 MHz。
    parameter integer DEBOUNCE_CYCLES = 2_500_000,
    parameter integer CNT_WIDTH       = 22   // 需满足 2^CNT_WIDTH > DEBOUNCE_CYCLES
) (
    input  wire clk,           // 125 MHz 时钟
    input  wire rst,           // 同步复位，高电平有效
    input  wire key_n,         // 按键原始输入，低有效（按下为 0）
    output reg  press_pulse,   // 确认按下：单周期脉冲
    output wire key_state      // 消抖后的电平（低有效）
);

    // ------------------------------------------------------------------------
    // 1. 两级同步器：把异步按键信号搬进 clk 域，抑制亚稳态。
    //    这两级不能用复位值以外的逻辑，否则会破坏"复位期间无时钟"的边界。
    // ------------------------------------------------------------------------
    reg [1:0] sync_ff = 2'b11;   // 初值取"松开"状态，避免复位期间按键输入被误判

    always @(posedge clk) begin
        if (rst)
            sync_ff <= 2'b11;
        else
            sync_ff <= {sync_ff[0], key_n};
    end

    // ------------------------------------------------------------------------
    // 2. 计数器消抖。
    //    stable_cnt 只在"当前采样与已确认电平相同"时清零并保持；
    //    一旦连续 DEBOUNCE_CYCLES 拍都不同，就把 key_state 翻转过去。
    // ------------------------------------------------------------------------
    reg                 key_state_r = 1'b1;   // 已确认的电平，初值 = 松开
    reg [CNT_WIDTH-1:0] stable_cnt  = {CNT_WIDTH{1'b0}};

    // 比较阈值：把整数参数转成与计数器同宽的行向量（参数本身不能直接位选）。
    localparam [CNT_WIDTH-1:0] DEBOUNCE_TARGET = DEBOUNCE_CYCLES;

    always @(posedge clk) begin
        if (rst) begin
            key_state_r <= 1'b1;
            stable_cnt  <= {CNT_WIDTH{1'b0}};
        end else begin
            if (sync_ff[1] == key_state_r) begin
                // 采样与已确认电平一致：没有变化待确认，计数器归零
                stable_cnt <= {CNT_WIDTH{1'b0}};
            end else if (stable_cnt == DEBOUNCE_TARGET) begin
                // 连续稳定足够久：承认这次变化（用 == 而非 >=，避免参数被截位时
                // 计数器永远追不上阈值而卡死）
                key_state_r <= sync_ff[1];
                stable_cnt  <= {CNT_WIDTH{1'b0}};
            end else begin
                stable_cnt <= stable_cnt + 1'b1;
            end
        end
    end

    assign key_state = key_state_r;

    // ------------------------------------------------------------------------
    // 3. 按下沿检测：key_state_r 由 1 变 0 时输出一个周期的高电平。
    //    按键低有效，所以"按下"对应下降沿。
    // ------------------------------------------------------------------------
    reg key_state_d = 1'b1;

    always @(posedge clk) begin
        if (rst) begin
            key_state_d <= 1'b1;
            press_pulse <= 1'b0;
        end else begin
            key_state_d <= key_state_r;
            press_pulse <= (key_state_d == 1'b1) && (key_state_r == 1'b0);
        end
    end

endmodule
