`timescale 1ns/1ps
// Pure math submodule: 3 U84/F32 raw scores -> delta S34/F32, Hz U49/F24.
// Uses ln(raw integer); common score scale cancels. No float, sqrt or IP.
module fine_log_parabola #(parameter LOG_ROM_FILE="fine_ln_8193.mem") (
    input wire clk,resetn,
    input wire start_valid,output wire start_ready,
    input wire [83:0] score_left,score_center,score_right,
    input wire [9:0] coarse_bin,input wire [31:0] sample_rate_hz,
    output wire result_valid,input wire result_ready,
    output reg numeric_valid,output reg [7:0] status,
    output reg signed [33:0] delta_bin,
    output reg [48:0] f_hat_hz,output reg [47:0] phase_increment,
    output wire [104:0] log_scores,
    output reg signed [36:0] curvature,
    output reg [7:0] curvature_min
);
    localparam IDLE=0,LOG_START=1,LOG_WAIT=2,CURVE=3,CHECK=4,
        DIV_START=5,DIV_WAIT=6,BIN_ADD=7,FREQ_MUL=8,FREQ_RNE=9,RESULT=10;
    reg [3:0] state;
    reg [1:0] slot;
    reg [83:0] scores[0:2];
    reg signed [34:0] logs[0:2];
    reg [6:0] exponents[0:2];
    reg [9:0] bin;
    reg [31:0] fs;
    reg signed [35:0] difference;
    reg negative;
    reg [67:0] div_num,div_den;
    wire log_start_ready,log_result_valid,log_numeric_valid;
    wire signed [34:0] log_value;
    wire [6:0] log_exponent;
    wire div_ready,div_valid,div_zero;
    wire [67:0] div_q,div_r;
    fine_log_score #(.ROM_FILE(LOG_ROM_FILE)) log_core (
        .clk(clk),.resetn(resetn),.start_valid(state==LOG_START),.start_ready(log_start_ready),
        .score(scores[slot]),.result_valid(log_result_valid),.result_ready(state==LOG_WAIT),
        .numeric_valid(log_numeric_valid),.logarithm(log_value),.exponent(log_exponent));
    fine_unsigned_divider divider (.clk(clk),.resetn(resetn),.start_valid(state==DIV_START),
        .start_ready(div_ready),.numerator(div_num),.denominator(div_den),
        .result_valid(div_valid),.result_ready(state==DIV_WAIT),.divide_by_zero(div_zero),
        .quotient(div_q),.remainder(div_r));
    wire signed [36:0] l0=$signed({{2{logs[0][34]}},logs[0]});
    wire signed [36:0] l1=$signed({{2{logs[1][34]}},logs[1]});
    wire signed [36:0] l2=$signed({{2{logs[2][34]}},logs[2]});
    wire signed [9:0] ecombo=$signed({3'b0,exponents[0]})-
        ($signed({3'b0,exponents[1]})<<<1)+$signed({3'b0,exponents[2]});
    wire [9:0] eabs=ecombo<0 ? $unsigned(-ecombo) : $unsigned(ecombo);
    // wide Eb*2^28 = 2 exactly: tau = 10 + ceil(abs(ecombo)/2).
    wire [9:0] tau=10+((eabs+1)>>1);
    wire signed [36:0] tau_signed=$signed({29'b0,curvature_min});
    wire signed [37:0] denom_work=$signed({curvature[36],curvature})<<<1;
    wire [35:0] numerator_mag=difference<0 ? $unsigned(-difference) : $unsigned(difference);
    wire [37:0] denominator_mag=denom_work<0 ? $unsigned(-denom_work) : $unsigned(denom_work);
    wire [68:0] twice_r={1'b0,div_r}<<1;
    wire round_up=twice_r>{1'b0,div_den} || (twice_r=={1'b0,div_den} && div_q[0]);
    wire [68:0] rounded_delta={1'b0,div_q}+round_up;
    reg signed [41:0] bin_q;
    reg signed [74:0] freq_product;
    wire [74:0] freq_mag=$unsigned(freq_product);
    wire [74:0] freq_rounded=(freq_mag>>18)+
        ((freq_mag[17:0]>18'h20000 || (freq_mag[17:0]==18'h20000 && freq_mag[18])) ? 75'd1 : 75'd0);
    assign start_ready=state==IDLE;
    assign result_valid=state==RESULT;
    assign log_scores={logs[2],logs[1],logs[0]};
    integer j;
    always @(posedge clk) begin
        if(!resetn) begin state<=IDLE; slot<=0; bin<=0; fs<=0; numeric_valid<=0; status<=4;
            delta_bin<=0; f_hat_hz<=0; phase_increment<=0; curvature<=0; curvature_min<=0;
            difference<=0; div_num<=0; div_den<=0; negative<=0;
            bin_q<=0; freq_product<=0;
            for(j=0;j<3;j=j+1) begin scores[j]<=0; logs[j]<=0; exponents[j]<=0; end
        end else case(state)
            IDLE: if(start_valid) begin
                scores[0]<=score_left; scores[1]<=score_center; scores[2]<=score_right;
                bin<=coarse_bin; fs<=sample_rate_hz; slot<=0; numeric_valid<=0; status<=4;
                delta_bin<=0; f_hat_hz<=0; phase_increment<=0; curvature<=0; curvature_min<=0;
                for(j=0;j<3;j=j+1) begin logs[j]<=0; exponents[j]<=0; end
                if(coarse_bin<2 || coarse_bin>510 || score_left==0 || score_center==0 || score_right==0 ||
                   score_center<score_left || score_center<score_right) state<=RESULT;
                else if(sample_rate_hz==0) begin status<=5; state<=RESULT; end
                else state<=LOG_START;
            end
            LOG_START: if(log_start_ready) state<=LOG_WAIT;
            LOG_WAIT: if(log_result_valid) begin
                if(!log_numeric_valid) state<=RESULT;
                else begin logs[slot]<=log_value; exponents[slot]<=log_exponent;
                    if(slot==2) state<=CURVE;
                    else begin slot<=slot+1'b1; state<=LOG_START; end
                end
            end
            CURVE: begin
                curvature<=l0-(l1<<<1)+l2; difference<=
                    $signed({logs[0][34],logs[0]})-$signed({logs[2][34],logs[2]});
                curvature_min<=tau[7:0]; state<=CHECK;
            end
            CHECK: if(curvature>=-tau_signed) state<=RESULT;
            else begin
                div_num<={numerator_mag,32'b0}; div_den<={{30{1'b0}},denominator_mag};
                negative<=difference[35]^denom_work[37];
                state<=DIV_START;
            end
            DIV_START: if(div_ready) state<=DIV_WAIT;
            DIV_WAIT: if(div_valid) begin
                if(div_zero || rounded_delta>69'd2147483648) state<=RESULT;
                else begin delta_bin<=negative ? -$signed(rounded_delta[33:0]) : $signed(rounded_delta[33:0]);
                    state<=BIN_ADD; end
            end
            BIN_ADD: begin bin_q<=$signed({bin,32'b0})+$signed(delta_bin); state<=FREQ_MUL; end
            FREQ_MUL: begin freq_product<=bin_q*$signed({1'b0,fs}); state<=FREQ_RNE; end
            FREQ_RNE: if(freq_product<0 || freq_rounded[74:49]!=0 || bin_q<=0 || bin_q[41:0]>=42'h20000000000) begin
                status<=5; state<=RESULT;
            end else begin f_hat_hz<=freq_rounded[48:0]; phase_increment<={bin_q[41:0],6'b0};
                numeric_valid<=1; status<=0; state<=RESULT; end
            RESULT: if(result_ready) state<=IDLE;
            default: begin status<=5; state<=RESULT; end
        endcase
    end
endmodule
