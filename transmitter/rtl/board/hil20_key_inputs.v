`timescale 1ns/1ps
// 两个原去抖实例的纯接线封装，不增延迟；key_debounce字节副本另存common。
module hil20_key_inputs #(
    parameter integer KEY_DEBOUNCE_CYCLES=2500000,KEY_CNT_WIDTH=22
)(
    input wire clk,rst,input wire [1:0] key_in,
    output wire key0_press,key1_press
);
    key_debounce #(
        .DEBOUNCE_CYCLES(KEY_DEBOUNCE_CYCLES),
        .CNT_WIDTH      (KEY_CNT_WIDTH)
    ) key0_debounce_inst (
        .clk        (clk),
        .rst        (rst),
        .key_n      (key_in[0]),
        .press_pulse(key0_press),
        .key_state  ()
    );

    key_debounce #(
        .DEBOUNCE_CYCLES(KEY_DEBOUNCE_CYCLES),
        .CNT_WIDTH      (KEY_CNT_WIDTH)
    ) key1_debounce_inst (
        .clk        (clk),
        .rst        (rst),
        .key_n      (key_in[1]),
        .press_pulse(key1_press),
        .key_state  ()
    );

endmodule
