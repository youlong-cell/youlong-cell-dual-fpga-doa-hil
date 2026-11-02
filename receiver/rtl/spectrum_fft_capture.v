`timescale 1ns / 1ps

// 双通道采集缓存：只管理1024点存储、累加、块均值和采集索引。
// 开帧只清索引和累加器；均值保持到下一帧最后一个有效采样。
// RAM不复位，异步读不加流水，以保持原控制器的逐周期数值契约。
module spectrum_fft_capture (
    input wire clk,
    input wire resetn,
    input wire begin_capture,
    input wire accept_sample,
    input wire [11:0] adc_ch0,
    input wire [11:0] adc_ch1,
    input wire read_channel,
    input wire [9:0] read_index,
    output reg [9:0] capture_index,
    output reg [22:0] sum_ch0,
    output reg [22:0] sum_ch1,
    output reg [11:0] mean_ch0,
    output reg [11:0] mean_ch1,
    output wire [11:0] read_sample,
    output wire [11:0] read_mean
);
    reg [11:0] capture_ch0 [0:1023];
    reg [11:0] capture_ch1 [0:1023];

    assign read_sample = read_channel ? capture_ch1[read_index] : capture_ch0[read_index];
    assign read_mean = read_channel ? mean_ch1 : mean_ch0;

    always @(posedge clk) begin
        if (!resetn) begin
            capture_index <= 10'd0;
            sum_ch0 <= 23'd0;
            sum_ch1 <= 23'd0;
            mean_ch0 <= 12'd0;
            mean_ch1 <= 12'd0;
        end else if (begin_capture) begin
            capture_index <= 10'd0;
            sum_ch0 <= 23'd0;
            sum_ch1 <= 23'd0;
        end else if (accept_sample) begin
            capture_ch0[capture_index] <= adc_ch0;
            capture_ch1[capture_index] <= adc_ch1;
            sum_ch0 <= sum_ch0 + adc_ch0;
            sum_ch1 <= sum_ch1 + adc_ch1;
            if (capture_index == 10'd1023) begin
                // 保持原23位加法及截断语义，最后一个样本必须计入均值。
                mean_ch0 <= (sum_ch0 + adc_ch0) >> 10;
                mean_ch1 <= (sum_ch1 + adc_ch1) >> 10;
            end else begin
                capture_index <= capture_index + 1'b1;
            end
        end
    end
endmodule
