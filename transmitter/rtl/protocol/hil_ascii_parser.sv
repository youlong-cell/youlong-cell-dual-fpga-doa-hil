`timescale 1ns/1ps
// Events are generated only by decoded UART bytes, never by partial lines.
module hil_ascii_parser #(parameter integer TIMEOUT_CYCLES=31250000)(
    input wire clk,rst,input wire [7:0] rx_byte,input wire rx_valid,frame_error,
    output reg event_valid,output reg [3:0] event_error,
    output reg [1:0] command_kind,output reg [4:0] command_mode,output reg command_enable,
    output reg [1:0] command_frequency_index,output reg signed [10:0] command_angle_tenths
);
    localparam integer TW=(TIMEOUT_CYCLES>1)?$clog2(TIMEOUT_CYCLES):1;
    reg [255:0] line;
    reg [5:0] length;
    reg discard;
    reg [TW-1:0] timer;
    wire [6:0] decoded; // {kind[1:0], mode[4:0]}; OUTPUT enable is decoded separately.
    wire found,decoded_enable;
    wire [1:0] decoded_frequency_index;
    wire signed [10:0] decoded_angle_tenths;
    initial if(TIMEOUT_CYCLES<16)$fatal(1,"PARSER_INVALID_TIMEOUT");
    hil_command_decode decoder(.line(line),.line_length(length),.found(found),.decoded(decoded),.decoded_enable(decoded_enable),
        .frequency_index(decoded_frequency_index),.angle_tenths(decoded_angle_tenths));
    always @(posedge clk)begin
        if(rst)begin line<=0;length<=0;discard<=0;timer<=0;event_valid<=0;event_error<=0;command_kind<=0;command_mode<=0;command_enable<=0;command_frequency_index<=0;command_angle_tenths<=0;end
        else begin
            event_valid<=0;
            if(frame_error)begin
                line<=0;length<=0;discard<=1;timer<=0;event_valid<=1;event_error<=7;
            end else if(rx_valid)begin
                timer<=0;
                if(rx_byte==8'h0d || rx_byte==8'h0a)begin
                    if(!discard && length!=0)begin
                        event_valid<=1;event_error<=found?4'd0:4'd3;
                        command_kind<=decoded[6:5];command_mode<=decoded[4:0];command_enable<=decoded_enable;
                        command_frequency_index<=decoded_frequency_index;command_angle_tenths<=decoded_angle_tenths;
                    end
                    line<=0;length<=0;discard<=0;
                end else if(!discard)begin
                    if(rx_byte<8'h20 || rx_byte>8'h7e)begin
                        event_valid<=1;event_error<=3;line<=0;length<=0;discard<=1;
                    end else if(length==32)begin
                        event_valid<=1;event_error<=5;line<=0;length<=0;discard<=1;
                    end else begin line<={line[247:0],rx_byte};length<=length+1'b1;end
                end
            end else if(length!=0 && !discard)begin
                if(timer==TIMEOUT_CYCLES-1)begin
                    event_valid<=1;event_error<=6;line<=0;length<=0;discard<=1;timer<=0;
                end else timer<=timer+1'b1;
            end
        end
    end
endmodule
