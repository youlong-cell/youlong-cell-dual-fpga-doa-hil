`timescale 1ns/1ps
// Single-transaction adc_clk angle adapter. External IP must be the verified
// CORDIC 6.0 sqrt U48/F47 and Translate S40/F38 -> phase S38/F35 configs.
// No AXI/CDC/Window release. Controller keeps ownership until result storage.
module fine_doa_arcsin #(
    parameter integer WATCHDOG_CYCLES=512
) (
    input wire clk, resetn,
    input wire start_valid, output wire start_ready,
    input wire [63:0] session_epoch,
    input wire [31:0] candidate_seq, config_version,
    input wire argument_valid, input wire [7:0] argument_status,
    input wire signed [37:0] u,
    input wire [10:0] u_tolerance,
    input wire domain_clamped,
    input wire abort, output reg abort_ack, output wire busy,
    output wire result_valid, input wire result_ready,
    output reg [63:0] result_epoch,
    output reg [31:0] result_seq, result_config_version,
    output reg theta_valid, output reg [7:0] status,
    output reg signed [35:0] theta,
    output reg signed [37:0] result_u,
    output reg [10:0] result_u_tolerance,
    output reg result_domain_clamped, output reg near_endfire,
    output reg theta_endpoint_snapped,
    output wire fault_valid, output reg [7:0] fault_code,
    input wire fault_clear,
    // Both external CORDICs are private to this adapter. This reset is held
    // low for eight full clocks on abort/fault-clear before accepting new work.
    output wire cordic_aresetn,
    output wire sqrt_in_valid, input wire sqrt_in_ready,
    output wire [47:0] sqrt_in_data,
    input wire sqrt_out_valid, output wire sqrt_out_ready,
    input wire [47:0] sqrt_out_data,
    output wire translate_in_valid, input wire translate_in_ready,
    output wire [79:0] translate_in_data,
    input wire translate_out_valid, output wire translate_out_ready,
    input wire [79:0] translate_out_data
);
    localparam [3:0] BOOT=0, IDLE=1, CHECK=2, SQUARE=3, RADICAND=4,
        SQ_SEND=5, SQ_WAIT=6, TR_SEND=7, TR_WAIT=8, RESULT=9, FAULT=10;
    localparam signed [37:0] ONE_U=38'sd68719476736;
    localparam signed [37:0] HALF_PHASE=38'sd17179869184;
    localparam [72:0] ONE_R=73'h1000000000000000000;
    reg [3:0] state;
    reg [3:0] reset_left;
    reg abort_pending, av;
    reg [15:0] wait_cycles;
    reg signed [37:0] held_u;
    reg [75:0] square;
    reg [47:0] radicand;
    reg [39:0] sqrt_x;
    wire [37:0] abs_u=held_u[37] ? -$unsigned(held_u) : $unsigned(held_u);
    wire [72:0] r_full=ONE_R-square[72:0];
    wire r_round=(r_full[24:0]>25'h1000000) ||
        (r_full[24:0]==25'h1000000 && r_full[25]);
    wire [48:0] r_rne={1'b0,r_full[72:25]}+{{48{1'b0}},r_round};
    wire x_round=(sqrt_out_data[8:0]>9'd256) ||
        (sqrt_out_data[8:0]==9'd256 && sqrt_out_data[9]);
    wire [39:0] x_rne={1'b0,sqrt_out_data[47:9]}+{{39{1'b0}},x_round};
    // Sign extension BEFORE shift: y is exact S40/F38, not a narrowed S38.
    wire signed [39:0] y_scaled=$signed({{2{held_u[37]}},held_u})<<<2;
    wire signed [37:0] phase_out=$signed(translate_out_data[77:40]);
    wire phase_padding_ok=translate_out_data[79:78]=={2{phase_out[37]}};
    wire phase_range_ok=phase_out>=-HALF_PHASE-38'sd2 && phase_out<=HALF_PHASE+38'sd2;
    assign cordic_aresetn=resetn && !abort && state!=BOOT && state!=FAULT;
    assign start_ready=resetn && !abort && state==IDLE;
    assign result_valid=resetn && !abort && state==RESULT;
    assign busy=state!=IDLE && state!=RESULT && state!=FAULT;
    assign fault_valid=resetn && state==FAULT;
    assign sqrt_in_valid=cordic_aresetn && state==SQ_SEND;
    assign sqrt_in_data=radicand;
    assign sqrt_out_ready=cordic_aresetn && state==SQ_WAIT;
    assign translate_in_valid=cordic_aresetn && state==TR_SEND;
    assign translate_in_data={y_scaled,sqrt_x};
    assign translate_out_ready=cordic_aresetn && state==TR_WAIT;

    always @(posedge clk) begin
        if(!resetn) begin
            state<=BOOT; reset_left<=7; abort_pending<=0; abort_ack<=0;
            av<=0; held_u<=0; square<=0; radicand<=0; sqrt_x<=0; wait_cycles<=0;
            result_epoch<=0; result_seq<=0; result_config_version<=0;
            theta_valid<=0; status<=0; theta<=0; result_u<=0;
            result_u_tolerance<=0; result_domain_clamped<=0; near_endfire<=0;
            theta_endpoint_snapped<=0; fault_code<=0;
        end else begin
            abort_ack<=0;
            if(abort && state!=FAULT && state!=BOOT) begin
                state<=BOOT; reset_left<=7; abort_pending<=1;
                theta_valid<=0; theta<=0;
            end else case(state)
                BOOT: begin
                    // If abort stays asserted, do not reopen either IP.
                    if(abort) reset_left<=7;
                    else if(reset_left==0) begin
                        state<=IDLE; abort_ack<=abort_pending; abort_pending<=0;
                    end else reset_left<=reset_left-4'd1;
                end
                IDLE: if(start_valid && start_ready) begin
                    result_epoch<=session_epoch; result_seq<=candidate_seq;
                    result_config_version<=config_version;
                    av<=argument_valid; status<=argument_status; held_u<=u;
                    result_u<=u; result_u_tolerance<=u_tolerance;
                    result_domain_clamped<=domain_clamped;
                    near_endfire<=0; theta_valid<=0; theta<=0;
                    theta_endpoint_snapped<=0; fault_code<=0; state<=CHECK;
                end
                CHECK: begin
                    // Upstream numeric-invalid (including status 10) passes
                    // through without ever injecting data into either IP.
                    if(!av) state<=RESULT;
                    else if(status!=0 || held_u>ONE_U || held_u<-ONE_U ||
                            result_u_tolerance>11'd1024 ||
                            (result_domain_clamped && abs_u!=$unsigned(ONE_U))) begin
                        fault_code<=8'h60; state<=FAULT;
                    end else begin
                        near_endfire<=($unsigned(ONE_U)-abs_u)<=
                            {27'b0,result_u_tolerance};
                        state<=SQUARE;
                    end
                end
                SQUARE: begin
                    // Full S38*S38 product: no lost fractional bits before r.
                    square<=$signed(held_u)*$signed(held_u); state<=RADICAND;
                end
                RADICAND: begin
                    if(square> {3'b0,ONE_R} || r_rne>49'h0800000000000) begin
                        fault_code<=8'h60; state<=FAULT;
                    end else begin radicand<=r_rne[47:0]; wait_cycles<=0; state<=SQ_SEND; end
                end
                SQ_SEND: if(sqrt_in_ready) begin wait_cycles<=0; state<=SQ_WAIT; end
                    else if(wait_cycles==WATCHDOG_CYCLES-1) begin fault_code<=8'h61; state<=FAULT; end
                    else wait_cycles<=wait_cycles+16'd1;
                SQ_WAIT: if(sqrt_out_valid) begin
                    if(sqrt_out_data>48'h800000000000 || x_rne>40'h4000000000) begin
                        fault_code<=8'h62; state<=FAULT;
                    end else begin sqrt_x<=x_rne; wait_cycles<=0; state<=TR_SEND; end
                end else if(wait_cycles==WATCHDOG_CYCLES-1) begin fault_code<=8'h61; state<=FAULT; end
                else wait_cycles<=wait_cycles+16'd1;
                TR_SEND: if(translate_in_ready) begin wait_cycles<=0; state<=TR_WAIT; end
                    else if(wait_cycles==WATCHDOG_CYCLES-1) begin fault_code<=8'h61; state<=FAULT; end
                    else wait_cycles<=wait_cycles+16'd1;
                TR_WAIT: if(translate_out_valid) begin
                    if(!phase_padding_ok || !phase_range_ok) begin fault_code<=8'h63; state<=FAULT; end
                    else begin
                        // Only <=2 phase-code IP overshoot at the angle
                        // endpoint is snapped. Never wrap theta as a phase.
                        if(phase_out>HALF_PHASE) begin
                            theta<=36'sd17179869184; theta_endpoint_snapped<=1;
                        end else if(phase_out<-HALF_PHASE) begin
                            theta<=-36'sd17179869184; theta_endpoint_snapped<=1;
                        end else theta<=phase_out[35:0];
                        theta_valid<=1; state<=RESULT;
                    end
                end else if(wait_cycles==WATCHDOG_CYCLES-1) begin fault_code<=8'h61; state<=FAULT; end
                else wait_cycles<=wait_cycles+16'd1;
                RESULT: if(result_ready) state<=IDLE;
                FAULT: if(fault_clear) begin
                    state<=BOOT; reset_left<=7; abort_pending<=0; fault_code<=0;
                    theta_valid<=0; theta<=0;
                end
                default: begin theta_valid<=0; theta<=0; fault_code<=8'h64; state<=FAULT; end
            endcase
        end
    end
endmodule
