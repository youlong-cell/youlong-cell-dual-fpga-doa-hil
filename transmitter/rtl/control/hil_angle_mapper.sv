`timescale 1ns/1ps
// Two-stage control-plane lookup. No changes to NCO waveform ROM or arithmetic.
// valid follows start by one further sampled edge; the controller owns admission.
module hil_angle_mapper #(parameter ROM_FILE="hil_angle_phase_rom.mem")(
    input wire clk,rst,start,input wire [1:0] frequency_index,
    input wire signed [10:0] angle_tenths,
    output reg valid,output reg [31:0] frequency_word,
    output reg signed [31:0] phase_word
);
    `include "generated/mapper_reset.vh"
    (* rom_style="block" *) reg [31:0] phase_rom[0:4095];
    initial $readmemh(ROM_FILE,phase_rom);
    wire [10:0] magnitude=angle_tenths[10] ? -angle_tenths : angle_tenths;
    wire [11:0] address={frequency_index,magnitude[9:0]};
    reg pending,negative;
    reg [1:0] held_frequency;
    reg [31:0] magnitude_word;
    always @(posedge clk) begin
        if(rst) begin
            valid<=0;pending<=0;negative<=0;held_frequency<=0;
            magnitude_word<=0;frequency_word<=HIL_RESET_FREQUENCY_WORD;phase_word<=0;
        end else begin
            valid<=pending;pending<=start;
            if(start) begin
                magnitude_word<=phase_rom[address];negative<=angle_tenths[10];
                held_frequency<=frequency_index;
            end
            if(pending) begin
                phase_word<=negative ? $signed(-magnitude_word) : $signed(magnitude_word);
                `include "generated/mapper_frequency.vh"
            end
        end
    end
endmodule
