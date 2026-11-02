`timescale 1ns/1ps
// 只观察mode，不反馈控制；-60deg闪烁状态保持原逐周期语义。
module hil20_led_status #(parameter integer LED_BLINK_HALF_CYCLES=31250000)(
    input wire clk,rst,input wire [4:0] mode_index,output wire [3:0] led,
    input wire custom_active,input wire [1:0] active_frequency_index
);
    localparam integer LED_COUNT_WIDTH = (LED_BLINK_HALF_CYCLES <= 1)
                                         ? 1 : $clog2(LED_BLINK_HALF_CYCLES);
    reg [LED_COUNT_WIDTH-1:0] led_count;
    reg led_blink;
    reg [4:0] led_last_mode;
    reg [1:0] led_frequency;
    reg [1:0] led_angle;
    always @(posedge clk) begin
        if(rst || mode_index != led_last_mode) begin
            led_count<=0;
            led_blink<=1'b1;
            led_last_mode<=mode_index;
        end else if(led_count == LED_BLINK_HALF_CYCLES-1) begin
            led_count<=0;
            led_blink<=~led_blink;
        end else led_count<=led_count+1'b1;
    end
    always @* begin
        `include "generated/led_tables.vh"
    end
    // Custom angle cannot be represented by the old five-angle LED code.
    // Alternate 01/10 as a dedicated CUSTOM indication; STATUS carries actual angle.
    assign led=custom_active ? {active_frequency_index,(led_blink?2'b01:2'b10)} : {led_frequency,led_angle};
endmodule
