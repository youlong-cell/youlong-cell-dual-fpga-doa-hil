`timescale 1ns/1ps
// Rebuild k-1/k/k+1 from immutable Frozen Window [1536:2559].
// ONE existing correlator is reused serially; no FFT Bank interface at all.
// Optional 4K final correlation REUSES the same physical correlator/NCO.
// Same adc_clk domain. No calibration, phase or DOA.
// Caller retains window ownership until the entire later Fine chain finishes.
module fine_three_bin_estimator #(
    parameter HANN_FRAME_FILE="fine_hann_1024.mem",
    parameter HANN_WINDOW_FILE="fine_hann_4096.mem",
    parameter NCO_FILE="fine_nco_16384.mem",
    parameter LOG_ROM_FILE="fine_ln_8193.mem",
    parameter integer READ_TIMEOUT_CYCLES=4096,
    parameter integer ENABLE_WINDOW_STAGE=0,
    // Optional integrated quality path. Legacy ln mode remains unchanged.
    parameter integer USE_QUALITY_INTERPOLATION=0,
    parameter QUALITY_LOG_ROM_FILE="fine_log2_8193.mem",
    // ceil(64 * quantized_Hann_sum^2 /15625), P is U83/F32.
    // Hann sum=536346634 for checked-in F20 symmetric 1024 ROM.
    parameter [82:0] CENTER_MIN_POWER=83'd1178286947545621,
    // Same 2.048-code amplitude gate, actual 4K F20 Hann sum=2146959394.
    parameter [82:0] WINDOW_MIN_POWER=83'd18880244283329935
) (
    input wire clk,resetn,
    input wire start_valid,output wire start_ready,
    input wire [31:0] candidate_seq,frame_seq,
    input wire [47:0] window_start_sample_id,frame_start_sample_id,event_sample_id,
    input wire [9:0] coarse_bin,input wire [31:0] sample_rate_hz,
    input wire quality_configured,
    input wire [36:0] cfg_P_min,
    input wire [37:0] cfg_D_min,
    input wire [32:0] cfg_delta_max,
    input wire [31:0] cfg_delta_error,
    input wire abort,output reg abort_ack,output wire busy,
    output wire fine_rd_req,input wire fine_rd_ready,
    output wire [11:0] fine_rd_addr,
    input wire fine_rd_valid,input wire [31:0] fine_rd_data,input wire [11:0] fine_rd_index,
    output wire result_valid,input wire result_ready,
    output reg numeric_valid,output reg [7:0] result_status,
    output reg [31:0] result_seq,result_frame_seq,
    output reg [47:0] result_window_start_id,result_frame_start_id,result_event_id,
    output reg [9:0] result_bin,
    output reg signed [33:0] delta_bin,output reg [48:0] f_hat_hz,
    output reg [47:0] phase_increment,
    output wire [251:0] scores_out,output wire [104:0] logs_out,
    output wire [491:0] complex_out,
    output reg window_present,
    output reg signed [40:0] window_i0,window_q0,window_i1,window_q1,
    output reg [23:0] window_mean0,window_mean1,
    output reg [82:0] window_power0,window_power1,
    output reg signed [36:0] curvature,output reg [7:0] curvature_min,
    output wire [107:0] quality_logs_out,
    output wire signed [36:0] quality_prominence,
    output wire signed [37:0] quality_curvature,
    output reg [7:0] interpolation_status,
    // Diagnostic phase only, NOT a second controller. 0=FRAME/quality,
    // 1=f_hat latched and WINDOW start offered, 2=WINDOW correlation/result.
    output wire [1:0] processing_stage,
    output wire fault_valid,output reg [7:0] fault_code,output wire [31:0] fault_seq,
    input wire fault_clear
);
    localparam IDLE=0,C_START=1,C_WAIT=2,SQUARE=3,POWER=4,SCORE=5,
        NEXT=6,P_START=7,P_WAIT=8,RESULT=9,FAULT=10,ABORT_DRAIN=11,
        W_START=12,W_WAIT=13,W_SQUARE=14,W_POWER=15,W_FINISH=16;
    reg [4:0] state;
    assign processing_stage=state==W_START ? 2'd1 :
        (state==W_WAIT || state==W_SQUARE || state==W_POWER || state==W_FINISH ||
         (state==RESULT && window_present)) ? 2'd2 : 2'd0;
    reg [1:0] slot;
    reg [31:0] fs;
    reg quality_q;
    reg [36:0] p_min_q;
    reg [37:0] d_min_q;
    reg [32:0] delta_max_q;
    reg [31:0] delta_error_q;
    reg [83:0] scores[0:2];
    reg [122:0] bins_x[0:3]; // three signed S41 values per component, diagnostic
    reg signed [40:0] xi0,xq0,xi1,xq1;
    reg [81:0] square_i0,square_q0,square_i1,square_q1;
    reg [82:0] power0,power1;
    reg [104:0] logs;
    wire c_ready,c_result,c_numeric,c_busy,c_fault;
    wire [7:0] c_status,c_fault_code;
    wire [31:0] c_result_seq;
    wire c_result_mode;
    wire [47:0] c_start_id,c_result_fcw;
    wire [23:0] c_mean0,c_mean1;
    wire signed [40:0] ci0,cq0,ci1,cq1;
    wire [9:0] requested_bin=result_bin-10'd1+{8'b0,slot};
    wire [47:0] coarse_fcw={requested_bin,38'b0};
    wire window_mode=state==W_START || state==W_WAIT;
    wire [47:0] requested_fcw=window_mode ? phase_increment : coarse_fcw;
    wire c_start=(state==C_START || state==W_START) && !abort;
    fine_complex_correlator #(.HANN_FRAME_FILE(HANN_FRAME_FILE),.HANN_WINDOW_FILE(HANN_WINDOW_FILE),
        .NCO_FILE(NCO_FILE),.READ_TIMEOUT_CYCLES(READ_TIMEOUT_CYCLES)) correlator (
        .clk(clk),.resetn(resetn),.start_valid(c_start),.start_ready(c_ready),.mode(window_mode),
        .candidate_seq(result_seq),.window_start_sample_id(result_window_start_id),.phase_increment(requested_fcw),
        .abort(abort),.abort_ack(),.busy(c_busy),
        .fine_rd_req(fine_rd_req),.fine_rd_ready(fine_rd_ready),.fine_rd_addr(fine_rd_addr),
        .fine_rd_valid(fine_rd_valid),.fine_rd_data(fine_rd_data),.fine_rd_index(fine_rd_index),
        .result_valid(c_result),.result_ready((state==C_WAIT || state==W_WAIT) && !abort),.numeric_valid(c_numeric),
        .result_status(c_status),.result_seq(c_result_seq),.result_mode(c_result_mode),.result_start_sample_id(c_start_id),
        .result_phase_increment(c_result_fcw),.mean0(c_mean0),.mean1(c_mean1),.i0(ci0),.q0(cq0),.i1(ci1),.q1(cq1),
        .fault_valid(c_fault),.fault_code(c_fault_code),.fault_seq(),.fault_clear(fault_clear && state==FAULT));
    wire p_ready,p_result,p_numeric;
    wire [7:0] p_status,p_tau;
    wire signed [33:0] p_delta;
    wire [48:0] p_freq;
    wire [47:0] p_fcw;
    wire [104:0] p_logs;
    wire signed [36:0] p_curvature;
    wire p_hardware_fault;
    // Synchronous math-only cancellation; no externally outstanding transaction.
    // Clear quality diagnostics before each task, including tasks rejected
    // before P_START. Otherwise LOW_SIGNAL could expose a previous peak's P/D.
    // Do not alter the legacy ln path's reset contract.
    wire math_resetn=resetn && !abort && state!=FAULT && state!=ABORT_DRAIN &&
        !((USE_QUALITY_INTERPOLATION != 0) && state==IDLE);
    generate if (USE_QUALITY_INTERPOLATION == 0) begin : g_legacy_ln
    assign p_hardware_fault=1'b0;
    assign quality_logs_out=108'd0;
    assign quality_prominence=37'sd0;
    assign quality_curvature=38'sd0;
    fine_log_parabola #(.LOG_ROM_FILE(LOG_ROM_FILE)) parabola (
        .clk(clk),.resetn(math_resetn),.start_valid(state==P_START),.start_ready(p_ready),
        .score_left(scores[0]),.score_center(scores[1]),.score_right(scores[2]),
        .coarse_bin(result_bin),.sample_rate_hz(fs),.result_valid(p_result),.result_ready(state==P_WAIT),
        .numeric_valid(p_numeric),.status(p_status),.delta_bin(p_delta),.f_hat_hz(p_freq),
        .phase_increment(p_fcw),.log_scores(p_logs),.curvature(p_curvature),.curvature_min(p_tau));
    end else begin : g_quality_log2
    // New S36/F28 logs must not be silently narrowed into legacy S35 ln ports.
    assign p_logs=105'd0;
    assign p_curvature=37'sd0;
    assign p_tau=8'd0;
    fine_three_bin_interpolator #(.LOG_ROM_FILE(QUALITY_LOG_ROM_FILE)) parabola (
        .clk(clk),.resetn(math_resetn),.start_valid(state==P_START),.start_ready(p_ready),
        .S_minus(scores[0]),.S_center(scores[1]),.S_plus(scores[2]),
        .score_valid(3'b111),.coarse_bin(result_bin),.sample_rate_hz(fs),
        .quality_configured(quality_q),.cfg_P_min(p_min_q),.cfg_D_min(d_min_q),
        .cfg_delta_max(delta_max_q),.cfg_delta_error(delta_error_q),
        .result_valid(p_result),.result_ready(state==P_WAIT),.freq_valid(p_numeric),
        .interpolation_status(p_status),.delta(p_delta),.f_hat(p_freq),
        .phase_increment(p_fcw),.prominence(quality_prominence),
        .curvature(quality_curvature),.log_scores(quality_logs_out),
        .hardware_fault(p_hardware_fault));
    end endgenerate
    wire [47:0] frame_offset=frame_start_sample_id-window_start_sample_id;
    wire [47:0] event_offset=event_sample_id-frame_start_sample_id;
    assign start_ready=state==IDLE && c_ready && !abort;
    assign result_valid=state==RESULT && !abort;
    assign busy=(state!=IDLE && state!=RESULT && state!=FAULT) || c_busy;
    assign fault_valid=state==FAULT;
    assign fault_seq=result_seq;
    assign scores_out={scores[2],scores[1],scores[0]};
    assign logs_out=logs;
    assign complex_out={bins_x[3],bins_x[2],bins_x[1],bins_x[0]};
    integer j;
    always @(posedge clk) begin
        if(!resetn) begin state<=IDLE; slot<=0; fs<=0; abort_ack<=0; fault_code<=0;
            quality_q<=0; p_min_q<=0; d_min_q<=0; delta_max_q<=0; delta_error_q<=0;
            interpolation_status<=8'hff;
            numeric_valid<=0; result_status<=2; result_seq<=0; result_frame_seq<=0;
            result_window_start_id<=0; result_frame_start_id<=0; result_event_id<=0; result_bin<=0;
            delta_bin<=0; f_hat_hz<=0; phase_increment<=0; logs<=0; curvature<=0; curvature_min<=0;
            xi0<=0; xq0<=0; xi1<=0; xq1<=0; square_i0<=0; square_q0<=0; square_i1<=0; square_q1<=0;
            power0<=0; power1<=0;
            window_present<=0; window_i0<=0; window_q0<=0; window_i1<=0; window_q1<=0;
            window_mean0<=0; window_mean1<=0; window_power0<=0; window_power1<=0;
            for(j=0;j<3;j=j+1) scores[j]<=0;
            for(j=0;j<4;j=j+1) bins_x[j]<=0;
        end else begin
            abort_ack<=0;
            if(abort && state!=IDLE && state!=FAULT && state!=ABORT_DRAIN) begin
                numeric_valid<=0; window_present<=0; state<=ABORT_DRAIN;
            end else case(state)
                IDLE: if(start_valid && start_ready) begin
                    result_seq<=candidate_seq; result_frame_seq<=frame_seq;
                    result_window_start_id<=window_start_sample_id; result_frame_start_id<=frame_start_sample_id;
                    result_event_id<=event_sample_id; result_bin<=coarse_bin; fs<=sample_rate_hz;
                    quality_q<=quality_configured; p_min_q<=cfg_P_min; d_min_q<=cfg_D_min;
                    delta_max_q<=cfg_delta_max; delta_error_q<=cfg_delta_error;
                    interpolation_status<=8'hff;
                    slot<=0; numeric_valid<=0; result_status<=2; fault_code<=0;
                    delta_bin<=0; f_hat_hz<=0; phase_increment<=0; logs<=0; curvature<=0; curvature_min<=0;
                    window_present<=0; window_i0<=0; window_q0<=0; window_i1<=0; window_q1<=0;
                    window_mean0<=0; window_mean1<=0; window_power0<=0; window_power1<=0;
                    for(j=0;j<3;j=j+1) scores[j]<=0;
                    for(j=0;j<4;j=j+1) bins_x[j]<=0;
                    if(coarse_bin==0 || coarse_bin>=512 || frame_offset!=1536 || event_offset!=512) state<=RESULT;
                    else if(coarse_bin==1 || coarse_bin==511) begin result_status<=4; state<=RESULT; end
                    else if(sample_rate_hz==0) begin result_status<=5; state<=RESULT; end
                    else state<=C_START;
                end
                C_START: if(c_ready) state<=C_WAIT;
                C_WAIT: if(c_result) begin
                    if(!c_numeric || c_status!=0 || c_result_seq!=result_seq || c_result_mode ||
                       c_start_id!=result_frame_start_id || c_result_fcw!=coarse_fcw) begin fault_code<=8'h20; state<=FAULT; end
                    else begin xi0<=ci0; xq0<=cq0; xi1<=ci1; xq1<=cq1;
                        bins_x[0][slot*41 +:41]<=ci0; bins_x[1][slot*41 +:41]<=cq0;
                        bins_x[2][slot*41 +:41]<=ci1; bins_x[3][slot*41 +:41]<=cq1; state<=SQUARE; end
                end
                SQUARE: begin square_i0<=xi0*xi0; square_q0<=xq0*xq0;
                    square_i1<=xi1*xi1; square_q1<=xq1*xq1; state<=POWER; end
                POWER: begin power0<={1'b0,square_i0}+{1'b0,square_q0};
                    power1<={1'b0,square_i1}+{1'b0,square_q1}; state<=SCORE; end
                SCORE: begin scores[slot]<={1'b0,power0}+{1'b0,power1}; state<=NEXT; end
                NEXT: if(slot==1 && (power0<CENTER_MIN_POWER || power1<CENTER_MIN_POWER)) begin
                    result_status<=1; state<=RESULT;
                end else if(slot==2) state<=P_START;
                else begin slot<=slot+1'b1; state<=C_START; end
                P_START: if(p_ready) state<=P_WAIT;
                P_WAIT: if(p_result) begin
                    numeric_valid<=p_numeric;
                    // 0x81..0x89: normal interpolation rejection, NOT HW fault.
                    result_status<=((USE_QUALITY_INTERPOLATION != 0) && !p_numeric) ?
                                   (8'h80 | p_status) : p_status;
                    interpolation_status<=p_status; delta_bin<=p_delta;
                    f_hat_hz<=p_freq; phase_increment<=p_fcw; logs<=p_logs;
                    curvature<=p_curvature; curvature_min<=p_tau;
                    state<=((ENABLE_WINDOW_STAGE != 0) && p_numeric) ? W_START : RESULT;
                end
                W_START: if(c_ready) state<=W_WAIT;
                W_WAIT: if(c_result) begin
                    if(!c_numeric || c_status!=0 || c_result_seq!=result_seq || !c_result_mode ||
                       c_start_id!=result_window_start_id || c_result_fcw!=phase_increment) begin
                        fault_code<=8'h20; numeric_valid<=0; window_present<=0; state<=FAULT;
                    end else begin
                        window_i0<=ci0; window_q0<=cq0; window_i1<=ci1; window_q1<=cq1;
                        window_mean0<=c_mean0; window_mean1<=c_mean1;
                        xi0<=ci0; xq0<=cq0; xi1<=ci1; xq1<=cq1; state<=W_SQUARE;
                    end
                end
                W_SQUARE: begin square_i0<=xi0*xi0; square_q0<=xq0*xq0;
                    square_i1<=xi1*xi1; square_q1<=xq1*xq1; state<=W_POWER; end
                W_POWER: begin window_power0<={1'b0,square_i0}+{1'b0,square_q0};
                    window_power1<={1'b0,square_i1}+{1'b0,square_q1}; state<=W_FINISH; end
                W_FINISH: begin
                    window_present<=1;
                    if(window_power0<WINDOW_MIN_POWER || window_power1<WINDOW_MIN_POWER) begin
                        numeric_valid<=0; result_status<=1;
                    end
                    state<=RESULT;
                end
                RESULT: if(result_ready) state<=IDLE;
                FAULT: if(fault_clear && !c_busy) begin state<=IDLE; fault_code<=0; end
                ABORT_DRAIN: if(c_fault) begin state<=FAULT; fault_code<=c_fault_code; end
                else if(!c_busy && !c_result) begin state<=IDLE; abort_ack<=1; end
                default: begin fault_code<=8'h20; numeric_valid<=0; window_present<=0; state<=FAULT; end
            endcase
            if(c_fault && state!=FAULT && state!=IDLE) begin
                numeric_valid<=0; window_present<=0; fault_code<=c_fault_code; state<=FAULT;
            end
            if(p_hardware_fault && state==P_WAIT) begin
                numeric_valid<=0; window_present<=0; fault_code<=8'h21; state<=FAULT;
            end
        end
    end
endmodule
