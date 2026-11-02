`timescale 1ns/1ps
// Snapshot descriptor -> bounded ASCII reply -> real 8N1 transmitter.
module hil_uart_reply #(parameter integer CLOCK_HZ=125000000,BAUD_RATE=0)(
    input wire clk,rst,input wire event_valid,output wire event_ready,
    input wire [23:0] descriptor,output wire tx_pin,output wire reply_busy
);
    reg [511:0] text;
    reg [6:0] length,index;
    reg active;
    wire tx_ready;
    wire [7:0] tx_byte=active?text[(length-1-index)*8+:8]:8'd0;
    assign event_ready=!active && tx_ready;
    assign reply_busy=active || !tx_ready;
    wire [511:0] formatted_text;
    wire [6:0] formatted_length;
    hil_reply_format format(.descriptor(descriptor),.formatted_text(formatted_text),.formatted_length(formatted_length));
    hil_uart_tx #(.CLOCK_HZ(CLOCK_HZ),.BAUD_RATE(BAUD_RATE)) tx(
        .clk(clk),.rst(rst),.tx_byte(tx_byte),.tx_valid(active),.tx_ready(tx_ready),.tx_pin(tx_pin));
    always @(posedge clk)begin
        if(rst)begin text<=0;length<=0;index<=0;active<=0;end
        else if(event_valid && event_ready)begin
            text<=formatted_text;length<=formatted_length;index<=0;active<=1;
        end else if(active && tx_ready)begin
            if(index==length-1)active<=0;else index<=index+1'b1;
        end
    end
endmodule
