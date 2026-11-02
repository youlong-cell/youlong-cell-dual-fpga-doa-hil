`timescale 1ns/1ps
// Portable restoring unsigned divider: WIDTH steps, full quotient/remainder.
// Same clock domain; held response. No combinational '/' and no vendor IP.
module fine_unsigned_divider #(parameter integer WIDTH=68) (
    input wire clk, resetn,
    input wire start_valid, output wire start_ready,
    input wire [WIDTH-1:0] numerator, denominator,
    output wire result_valid, input wire result_ready,
    output reg divide_by_zero,
    output reg [WIDTH-1:0] quotient, remainder
);
    localparam IDLE=0, RUN=1, RESULT=2;
    reg [1:0] state;
    reg [WIDTH-1:0] dividend, divisor;
    reg [WIDTH:0] rem_work;
    reg [$clog2(WIDTH+1)-1:0] count;
    wire [WIDTH:0] trial={rem_work[WIDTH-1:0],dividend[WIDTH-1]};
    wire ge=trial>={1'b0,divisor};
    wire [WIDTH:0] next_rem=ge ? trial-{1'b0,divisor} : trial;
    wire [WIDTH-1:0] next_q={quotient[WIDTH-2:0],ge};
    assign start_ready=state==IDLE;
    assign result_valid=state==RESULT;
    always @(posedge clk) begin
        if(!resetn) begin state<=IDLE; quotient<=0; remainder<=0; divide_by_zero<=0;
            rem_work<=0; count<=0; dividend<=0; divisor<=0; end
        else case(state)
            IDLE: if(start_valid) begin
                dividend<=numerator; divisor<=denominator; quotient<=0;
                rem_work<=0; remainder<=0; count<=0; divide_by_zero<=denominator==0;
                state<=denominator==0 ? RESULT : RUN;
            end
            RUN: begin
                rem_work<=next_rem; quotient<=next_q; dividend<=dividend<<1;
                if(count==WIDTH-1) begin remainder<=next_rem[WIDTH-1:0]; state<=RESULT; end
                else count<=count+1'b1;
            end
            RESULT: if(result_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
