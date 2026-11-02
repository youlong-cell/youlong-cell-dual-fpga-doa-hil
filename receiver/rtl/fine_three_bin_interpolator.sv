`timescale 1ns/1ps
// Independent interpolation quality, NOT signal detection or final DOA validity.
// Config and all scores snapshot on start. NO production P_min/D_min defaults.
// Log analytic error <=3 F28 LSB. Config D_min must certify delta error budget.
// All ports same adc_clk domain; external CDC/config transport not provided.
module fine_three_bin_interpolator #(parameter LOG_ROM_FILE="fine_log2_8193.mem") (
    input wire clk,resetn,
    input wire start_valid,output wire start_ready,
    input wire [83:0] S_minus,S_center,S_plus,input wire [2:0] score_valid,
    input wire [9:0] coarse_bin,input wire [31:0] sample_rate_hz,
    input wire quality_configured,
    input wire [36:0] cfg_P_min,       // U37/F28, strictly positive
    input wire [37:0] cfg_D_min,       // U38/F28 magnitude
    input wire [32:0] cfg_delta_max,   // U33/F32, 0 < max <= 0.5
    input wire [31:0] cfg_delta_error, // U32/F32; budget must exceed 0.5 LSB
    output wire result_valid,input wire result_ready,
    output reg freq_valid,output reg [7:0] interpolation_status,
    output reg signed [33:0] delta,
    output reg [48:0] f_hat,output reg [47:0] phase_increment,
    output reg signed [36:0] prominence,
    output reg signed [37:0] curvature,
    output wire [107:0] log_scores,
    output wire hardware_fault
);
    localparam IDLE=0,CONFIG_CHECK=1,LOG_START=2,LOG_WAIT=3,CURVE=4,CHECK=5,
        DIV_START=6,DIV_WAIT=7,BIN_ADD=8,FREQ_MUL=9,FREQ_RNE=10,RESULT=11,HW_FAULT=15;
    // Numeric status: 0 OK,1 unconfigured,2 score,3 localmax,4 prominence,
    // 5 nonnegative D,6 magnitude,7 delta range,8 freq/meta range,9 config budget.
    localparam [37:0] FOUR_EPS=38'd12;
    reg [3:0] state; reg [1:0] slot;
    reg [83:0] scores[0:2]; reg signed [35:0] logs[0:2];
    reg [9:0] bin; reg [31:0] fs; reg [36:0] pmin; reg [37:0] dmin; reg [32:0] dmax;
    reg [70:0] config_certificate; reg [38:0] required_certificate; reg [7:0] input_status;
    wire [37:0] cfg_margin=cfg_D_min-FOUR_EPS;
    wire [32:0] cfg_budget_twice=({1'b0,cfg_delta_error}<<1)-33'd1;
    wire [38:0] cfg_shape=39'd4294967296+({6'b0,cfg_delta_max}<<2);
    wire [38:0] cfg_required=cfg_shape*39'd6;
    wire log_ready,log_valid,log_numeric; wire signed [35:0] log_value; wire [6:0] log_exponent;
    fine_log2_score #(.ROM_FILE(LOG_ROM_FILE)) log_core (
        .clk(clk),.resetn(resetn),.start_valid(state==LOG_START),.start_ready(log_ready),.score(scores[slot]),
        .result_valid(log_valid),.result_ready(state==LOG_WAIT),.numeric_valid(log_numeric),
        .logarithm(log_value),.exponent(log_exponent));
    wire signed [37:0] lm=$signed({{2{logs[0][35]}},logs[0]});
    wire signed [37:0] lc=$signed({{2{logs[1][35]}},logs[1]});
    wire signed [37:0] lp=$signed({{2{logs[2][35]}},logs[2]});
    reg signed [36:0] difference; reg negative;
    wire [37:0] curve_mag=$unsigned(-curvature);
    wire [36:0] numerator_mag=difference<0 ? $unsigned(-difference) : $unsigned(difference);
    wire [38:0] denominator_mag={1'b0,curve_mag}<<1;
    wire [37:0] p_threshold={1'b0,pmin}+38'd6;
    reg [68:0] div_num,div_den;
    wire div_ready,div_valid,div_zero; wire [68:0] div_q,div_r;
    fine_unsigned_divider #(.WIDTH(69)) divider (
        .clk(clk),.resetn(resetn),.start_valid(state==DIV_START),.start_ready(div_ready),
        .numerator(div_num),.denominator(div_den),.result_valid(div_valid),.result_ready(state==DIV_WAIT),
        .divide_by_zero(div_zero),.quotient(div_q),.remainder(div_r));
    wire [69:0] twice_r={1'b0,div_r}<<1;
    wire round_up=twice_r>{1'b0,div_den} || (twice_r=={1'b0,div_den} && div_q[0]);
    wire [69:0] rounded_delta={1'b0,div_q}+{{69{1'b0}},round_up};
    wire [68:0] max_extended={{36{1'b0}},dmax};
    reg signed [41:0] bin_q; reg signed [74:0] freq_product;
    wire [74:0] freq_mag=$unsigned(freq_product);
    wire [74:0] freq_rounded=(freq_mag>>18)+
        ((freq_mag[17:0]>18'h20000 || (freq_mag[17:0]==18'h20000 && freq_mag[18])) ? 75'd1 : 75'd0);
    assign start_ready=state==IDLE; assign result_valid=state==RESULT;
    assign hardware_fault=state==HW_FAULT;
    assign log_scores={logs[2],logs[1],logs[0]};
    integer j;
    always @(posedge clk) begin
        if(!resetn) begin
            state<=IDLE; slot<=0; bin<=0; fs<=0; pmin<=0; dmin<=0; dmax<=0;
            config_certificate<=0; required_certificate<=0; input_status<=0; freq_valid<=0; interpolation_status<=1;
            delta<=0; f_hat<=0; phase_increment<=0; prominence<=0; curvature<=0; difference<=0;
            negative<=0; div_num<=0; div_den<=0; bin_q<=0; freq_product<=0;
            for(j=0;j<3;j=j+1) begin scores[j]<=0; logs[j]<=0; end
        end else case(state)
            IDLE: if(start_valid) begin
                scores[0]<=S_minus; scores[1]<=S_center; scores[2]<=S_plus;
                bin<=coarse_bin; fs<=sample_rate_hz; pmin<=cfg_P_min; dmin<=cfg_D_min; dmax<=cfg_delta_max;
                config_certificate<=cfg_margin*cfg_budget_twice; required_certificate<=cfg_required;
                slot<=0; freq_valid<=0; interpolation_status<=0; input_status<=0; delta<=0; f_hat<=0;
                phase_increment<=0; prominence<=0; curvature<=0;
                for(j=0;j<3;j=j+1) logs[j]<=0;
                if(!quality_configured) begin interpolation_status<=1; state<=RESULT; end
                else if(cfg_P_min==0 || cfg_D_min<=FOUR_EPS || cfg_delta_max==0 ||
                        cfg_delta_max>33'd2147483648 || cfg_delta_error==0) begin
                    interpolation_status<=9; state<=RESULT;
                end else begin
                    if(coarse_bin<2 || coarse_bin>510 || sample_rate_hz==0) input_status<=8;
                    else if(score_valid!=3'b111 || S_minus==0 || S_center==0 || S_plus==0) input_status<=2;
                    else if(S_center<S_minus || S_center<S_plus) input_status<=3;
                    state<=CONFIG_CHECK;
                end
            end
            CONFIG_CHECK: if(config_certificate<{{32{1'b0}},required_certificate}) begin
                interpolation_status<=9; state<=RESULT;
            end else if(input_status!=0) begin interpolation_status<=input_status; state<=RESULT; end
            else state<=LOG_START;
            LOG_START: if(log_ready) state<=LOG_WAIT;
            LOG_WAIT: if(log_valid) begin
                if(!log_numeric) begin interpolation_status<=2; state<=RESULT; end
                else begin logs[slot]<=log_value;
                    if(slot==2) state<=CURVE;
                    else begin slot<=slot+1'b1; state<=LOG_START; end
                end
            end
            CURVE: begin
                curvature<=lm-(lc<<<1)+lp;
                difference<=$signed({logs[0][35],logs[0]})-$signed({logs[2][35],logs[2]});
                prominence<=$signed({logs[1][35],logs[1]})-
                    (logs[0]>logs[2] ? $signed({logs[0][35],logs[0]}) : $signed({logs[2][35],logs[2]}));
                state<=CHECK;
            end
            CHECK: if(curvature>=0) begin interpolation_status<=5; state<=RESULT; end
            else if(prominence<=37'sd6 || $unsigned(prominence)<p_threshold) begin
                interpolation_status<=4; state<=RESULT;
            end else if(curve_mag<dmin) begin interpolation_status<=6; state<=RESULT; end
            else begin div_num<={numerator_mag,32'b0}; div_den<={30'b0,denominator_mag};
                negative<=!difference[36] && difference!=0; state<=DIV_START; end
            DIV_START: if(div_ready) state<=DIV_WAIT;
            DIV_WAIT: if(div_valid) begin
                if(div_zero) begin state<=HW_FAULT; end
                else if(div_q>max_extended || (div_q==max_extended && div_r!=0) ||
                        rounded_delta>{1'b0,max_extended}) begin interpolation_status<=7; state<=RESULT; end
                else begin delta<=negative ? -$signed(rounded_delta[33:0]) : $signed(rounded_delta[33:0]); state<=BIN_ADD; end
            end
            BIN_ADD: begin bin_q<=$signed({bin,32'b0})+$signed(delta); state<=FREQ_MUL; end
            FREQ_MUL: begin freq_product<=bin_q*$signed({1'b0,fs}); state<=FREQ_RNE; end
            FREQ_RNE: if(freq_product<0 || freq_rounded[74:49]!=0 || bin_q<=0 || $unsigned(bin_q)>=42'h20000000000) begin
                interpolation_status<=8; state<=RESULT;
            end else begin f_hat<=freq_rounded[48:0]; phase_increment<={bin_q,6'b0}; freq_valid<=1; state<=RESULT; end
            RESULT: if(result_ready) state<=IDLE;
            HW_FAULT: state<=HW_FAULT; // impossible internal state requires coordinated reset
            default: begin freq_valid<=0; state<=HW_FAULT; end
        endcase
    end
endmodule
