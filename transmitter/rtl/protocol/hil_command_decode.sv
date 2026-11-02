`timescale 1ns/1ps
// 完整行的无状态白名单译码；不得在部分行上提交。
module hil_command_decode(
    input wire [255:0] line,input wire [5:0] line_length,output reg found,
    output reg [6:0] decoded,output reg decoded_enable,
    output reg [1:0] frequency_index,output reg signed [10:0] angle_tenths
);
    // Bounded grammar: 1/2 integer digits, optionally '.' and one digit.
    // Fixed byte muxes and <=10-bit arithmetic replace a 13-stage integer fold.
    reg [9:0] magnitude;
    reg negative;
    wire [3:0] shape_ok,candidate_ok,candidate_negative;
    wire [1:0] candidate_band[0:3];
    wire [9:0] magnitude_by_shape[0:3];
    wire [3:0] candidate_alias;
    wire [4:0] alias_mode[0:3];
    `include "generated/decoder_aliases.vh"
    wire [4:0] alias_decoded_mode=({5{candidate_alias[0]}}&alias_mode[0])|
        ({5{candidate_alias[1]}}&alias_mode[1])|({5{candidate_alias[2]}}&alias_mode[2])|
        ({5{candidate_alias[3]}}&alias_mode[3]);
    function is_digit(input [7:0] ch);
        is_digit=(ch>=8'h30 && ch<=8'h39);
    endfunction
    function [9:0] times_ten(input [3:0] digit);
        times_ten=({6'd0,digit}<<3)+({6'd0,digit}<<1);
    endfunction
    function [9:0] times_hundred(input [3:0] digit);
        times_hundred=({6'd0,digit}<<6)+({6'd0,digit}<<5)+({6'd0,digit}<<2);
    endfunction
    // Digits are at fixed positions relative to the end of the captured line.
    // Prefix comparisons for all four possible numeric lengths run in parallel.
    assign shape_ok[0]=is_digit(line[7:0]);
    assign shape_ok[1]=is_digit(line[15:8]) && is_digit(line[7:0]);
    assign shape_ok[2]=is_digit(line[23:16]) && line[15:8]=="." && is_digit(line[7:0]);
    assign shape_ok[3]=is_digit(line[31:24]) && is_digit(line[23:16]) && line[15:8]=="." && is_digit(line[7:0]);
    assign magnitude_by_shape[0]=times_ten(line[3:0]);
    assign magnitude_by_shape[1]=times_hundred(line[11:8])+times_ten(line[3:0]);
    assign magnitude_by_shape[2]=times_ten(line[19:16])+{6'd0,line[3:0]};
    assign magnitude_by_shape[3]=times_hundred(line[27:24])+times_ten(line[19:16])+{6'd0,line[3:0]};
    genvar n;
    generate for(n=1;n<=4;n=n+1)begin: fixed_prefix
        reg prefix_ok,negative;
        reg [1:0] band;
        always @*begin
            prefix_ok=1;negative=0;band=0;
            `include "generated/decoder_prefix.vh"
        end
        assign candidate_ok[n-1]=prefix_ok && shape_ok[n-1] && magnitude_by_shape[n-1]<=10'd900;
        assign candidate_negative[n-1]=negative;
        assign candidate_band[n-1]=band;
        assign candidate_alias[n-1]=prefix_ok && (alias_zero[n-1] || alias_thirty[n-1] || alias_sixty[n-1]);
        assign alias_mode[n-1]=alias_mode_of(band,negative,alias_thirty[n-1]?2'd1:(alias_sixty[n-1]?2'd2:2'd0));
    end endgenerate
    always @*begin
        found=1;decoded=0;decoded_enable=0;frequency_index=0;angle_tenths=0;
        magnitude=0;negative=0;
        case(line)
            `include "generated/decoder_presets.vh"
            "OUTPUT ON":begin decoded={2'd1,5'd0};decoded_enable=1;end
            "OUTPUT OFF":decoded={2'd1,5'd0};
            "STATUS?":decoded={2'd2,5'd0};
            // 未采纳命令的decoded无效；有效别名直接使用ASCII并行识别结果。
            default:begin found=0;decoded=(|candidate_alias)?{2'd0,alias_decoded_mode}:{2'd3,5'd31};end
        endcase
        // Exact old commands above retain their mode ID and byte-level reply.
        // New syntax: SET (1M|2M|5M|10M) [+-]dd[.d], strict -90.0..+90.0.
        if(!found && |candidate_ok) begin
                    frequency_index=({2{candidate_ok[0]}}&candidate_band[0])|({2{candidate_ok[1]}}&candidate_band[1])|({2{candidate_ok[2]}}&candidate_band[2])|({2{candidate_ok[3]}}&candidate_band[3]);
                    magnitude=({10{candidate_ok[0]}}&magnitude_by_shape[0])|({10{candidate_ok[1]}}&magnitude_by_shape[1])|({10{candidate_ok[2]}}&magnitude_by_shape[2])|({10{candidate_ok[3]}}&magnitude_by_shape[3]);
                    negative=|(candidate_ok&candidate_negative);
                    found=1;angle_tenths=negative ? -$signed({1'b0,magnitude}) : $signed({1'b0,magnitude});
        end
    end
endmodule
