`timescale 1ns/1ps
// 单时钟控制平面接线层：transport / framing / transaction / reply各自单一职责。
module hil20_uart_control #(
    parameter integer CLOCK_HZ=125000000,BAUD_RATE=0,
    parameter integer LINE_TIMEOUT_CYCLES=31250000,REPLY_DEPTH=4,USE_LINK_STATUS=0
)(
    input wire clk,rst,key0_press,key1_press,uart_rx,uart_link_up,
    output wire uart_tx,
    output wire [4:0] mode_index,output wire [31:0] frequency_word,
    output wire signed [31:0] phase_offset_word,output wire [13:0] amplitude,
    output wire wave_sel,output_enable,restart_pulse,
    output wire custom_active,output wire [1:0] active_frequency_index,
    output wire signed [10:0] active_angle_tenths,
    output wire control_busy,output wire [31:0] dropped_reply_count,
    output wire key_overflow,output wire reply_busy
);
    localparam integer PW=(REPLY_DEPTH>1)?$clog2(REPLY_DEPTH):1;
    wire link_ok,serial_rst;
    hil_uart_link #(.USE_LINK_STATUS(USE_LINK_STATUS)) link(
        .clk(clk),.rst(rst),.uart_link_up(uart_link_up),.link_ok(link_ok),.serial_rst(serial_rst));
    wire [7:0] rx_byte;
    wire rx_valid,frame_error,parser_event;
    wire [3:0] parser_error;
    wire [1:0] parser_kind;
    wire [4:0] parser_mode;
    wire parser_enable;
    wire [1:0] parser_frequency_index;
    wire signed [10:0] parser_angle_tenths;
    hil_uart_rx #(.CLOCK_HZ(CLOCK_HZ),.BAUD_RATE(BAUD_RATE)) rx(
        .clk(clk),.rst(serial_rst),.rx_pin(uart_rx),.rx_byte(rx_byte),.rx_valid(rx_valid),.frame_error(frame_error));
    hil_ascii_parser #(.TIMEOUT_CYCLES(LINE_TIMEOUT_CYCLES)) parser(
        .clk(clk),.rst(serial_rst),.rx_byte(rx_byte),.rx_valid(rx_valid),.frame_error(frame_error),
        .event_valid(parser_event),.event_error(parser_error),.command_kind(parser_kind),
        .command_mode(parser_mode),.command_enable(parser_enable),
        .command_frequency_index(parser_frequency_index),.command_angle_tenths(parser_angle_tenths));
    wire req_valid,inflight;
    wire [1:0] req_kind;
    wire [4:0] req_mode;
    wire req_enable;
    wire [1:0] req_frequency_index;
    wire signed [10:0] req_angle_tenths;
    wire req_ready,rsp_valid;
    wire [3:0] rsp_code;
    wire [4:0] rsp_mode;
    wire rsp_enable;
    wire rsp_custom_active;
    wire [1:0] rsp_frequency_index;
    wire signed [10:0] rsp_angle_tenths;
    hil20_control control(.clk(clk),.rst(rst),.key0_press(key0_press),.key1_press(key1_press),
        .req_valid(req_valid && link_ok),.req_ready(req_ready),.req_kind(req_kind),.req_mode(req_mode),.req_enable(req_enable),
        .req_frequency_index(req_frequency_index),.req_angle_tenths(req_angle_tenths),
        .rsp_valid(rsp_valid),.rsp_code(rsp_code),.rsp_mode(rsp_mode),.rsp_enable(rsp_enable),
        .rsp_custom_active(rsp_custom_active),.rsp_frequency_index(rsp_frequency_index),.rsp_angle_tenths(rsp_angle_tenths),
        .custom_active(custom_active),.active_frequency_index(active_frequency_index),.active_angle_tenths(active_angle_tenths),
        .mode_index(mode_index),.frequency_word(frequency_word),.phase_offset_word(phase_offset_word),
        .amplitude(amplitude),.wave_sel(wave_sel),.output_enable(output_enable),.restart_pulse(restart_pulse),
        .busy(control_busy),.key_overflow(key_overflow));

    wire pending_event,overflow_notice,reply_valid,formatter_ready;
    wire [PW:0] count;
    wire [9:0] front;
    wire [23:0] full_front;
    hil_reply_scheduler #(.REPLY_DEPTH(REPLY_DEPTH)) scheduler(
        .clk(clk),.serial_rst(serial_rst),
        .parser_event(parser_event),.parser_error(parser_error),.parser_kind(parser_kind),
        .parser_mode(parser_mode),.parser_enable(parser_enable),
        .parser_frequency_index(parser_frequency_index),.parser_angle_tenths(parser_angle_tenths),
        .req_ready(req_ready),.rsp_valid(rsp_valid),.rsp_code(rsp_code),
        .rsp_mode(rsp_mode),.rsp_enable(rsp_enable),
        .rsp_custom_active(rsp_custom_active),.rsp_frequency_index(rsp_frequency_index),.rsp_angle_tenths(rsp_angle_tenths),
        .mode_index(mode_index),.output_enable(output_enable),.formatter_ready(formatter_ready),
        .custom_active(custom_active),.active_frequency_index(active_frequency_index),.active_angle_tenths(active_angle_tenths),
        .req_valid(req_valid),.req_kind(req_kind),.req_mode(req_mode),.req_enable(req_enable),
        .req_frequency_index(req_frequency_index),.req_angle_tenths(req_angle_tenths),
        .reply_valid(reply_valid),.front(front),.full_front(full_front),.dropped_reply_count(dropped_reply_count),
        .inflight(inflight),.pending_event(pending_event),.overflow_notice(overflow_notice),.count(count));
    hil_uart_reply #(.CLOCK_HZ(CLOCK_HZ),.BAUD_RATE(BAUD_RATE)) formatter(
        .clk(clk),.rst(serial_rst),.event_valid(reply_valid),.event_ready(formatter_ready),
        .descriptor(full_front),.tx_pin(uart_tx),.reply_busy(reply_busy));
endmodule
