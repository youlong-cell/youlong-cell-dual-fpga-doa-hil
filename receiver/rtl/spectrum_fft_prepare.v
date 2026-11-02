`timescale 1ns / 1ps

// FFT输入预处理：12位无符号ADC去块均值，再乘原Q1.15 Hann窗。
// 13位差、29位乘积、算术右移及16位截断完全沿用原实现；不新增寄存器。
module spectrum_fft_prepare (
    input wire [9:0] sample_index,
    input wire [11:0] sample_data,
    input wire [11:0] sample_mean,
    output wire signed [15:0] windowed_sample
);
    reg signed [15:0] hann_rom [0:1023];
    initial begin
        $readmemh("hann_1024.mem", hann_rom);
    end
    wire signed [12:0] centered_sample =
        $signed({1'b0, sample_data}) - $signed({1'b0, sample_mean});
    wire signed [28:0] window_product =
        centered_sample * $signed(hann_rom[sample_index]);
    assign windowed_sample = window_product >>> 15;
endmodule
