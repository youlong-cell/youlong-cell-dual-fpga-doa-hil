`timescale 1ns / 1ps

// FFT结果写回：仅接收主控允许的输出拍，注册写入每通道前512个自然序bin。
// 写口延迟保持一拍；空闲仅清使能，不改地址/数据保持行为。
module spectrum_fft_result_writer (
    input wire clk,
    input wire resetn,
    input wire accept_result,
    input wire active_channel,
    input wire [15:0] result_index,
    input wire [63:0] result_data,
    output reg bram_enb,
    output reg [7:0] bram_web,
    output reg [31:0] bram_addrb,
    output reg [63:0] bram_dinb
);
    always @(posedge clk) begin
        if (!resetn) begin
            bram_enb <= 1'b0;
            bram_web <= 8'd0;
            bram_addrb <= 32'd0;
            bram_dinb <= 64'd0;
        end else begin
            bram_enb <= 1'b0;
            bram_web <= 8'd0;
            if (accept_result && result_index[9:0] < 10'd512) begin
                bram_enb <= 1'b1;
                bram_web <= 8'hff;
                bram_addrb <= {19'd0, active_channel, result_index[8:0], 3'b000};
                bram_dinb <= result_data;
            end
        end
    end
endmodule
