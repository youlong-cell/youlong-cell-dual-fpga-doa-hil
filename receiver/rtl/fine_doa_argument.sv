`timescale 1ns/1ps
// Independent adc_clk math stage. NO Window release, AXI, CDC or angle output.
// p = calibrated CH1-CH0 phase/pi, S36/F35 in [-1,1).
// A = pi*Kgeo = c/(2*d), U64/F24 Hz; f = U49/F24 Hz.
// The controller must supply its WHOLE-task configuration snapshot, not live
// shadow registers. Identity fields are opaque: this module allocates no epoch.
module fine_doa_argument (
    input wire clk, resetn,
    input wire start_valid, output wire start_ready,
    input wire [63:0] session_epoch,
    input wire [31:0] candidate_seq, config_version,
    input wire calibrated_phase_valid, phase_encoding_valid, geometry_valid,
    input wire signed [35:0] phase_cal,
    input wire [48:0] f_hat_hz,
    input wire [63:0] geometry_a_hz,
    input wire abort, output reg abort_ack, output wire busy,
    output wire result_valid, input wire result_ready,
    output reg [63:0] result_epoch,
    output reg [31:0] result_seq, result_config_version,
    output reg argument_valid, output reg [7:0] status,
    output reg signed [37:0] u,
    output reg signed [53:0] u_unchecked,
    output reg [51:0] gain_pi,
    output reg [10:0] u_tolerance,
    output reg domain_clamped,
    output wire fault_valid, output reg [7:0] fault_code,
    input wire fault_clear
);
    localparam [3:0] IDLE=0, CHECK=1, G_START=2, G_WAIT=3,
        E_START=4, E_WAIT=5, MULTIPLY=6, ROUND_U=7, DOMAIN=8,
        RESULT=9, FAULT=10;
    // 0..7 preserve PS DOA status names. 8..10 are PL numeric invalid, NOT FAULT.
    localparam [7:0] OK=0, UNCALIBRATED=1, INVALID_FREQUENCY=2,
        INVALID_PHASE=3, INVALID_GEOMETRY=4, SPATIAL_AMBIGUITY=5,
        ASIN_DOMAIN=6, GEOMETRY_BOUNDARY_UNCERTAIN=8, GEOMETRY_NUMERIC_RANGE=9,
        PHASE_BOUNDARY_UNCERTAIN=10;
    localparam signed [53:0] ONE_U=54'sh00001000000000;
    localparam [99:0] ONE_GAIN=100'd68719476736;
    reg [3:0] state;
    reg cal_ok,phase_ok,geo_ok;
    reg signed [35:0] p;
    reg [48:0] f;
    reg [63:0] a;
    reg [10:0] eg_code;
    reg signed [88:0] product;
    reg [7:0] wait_cycles;
    // epsilon_p=3 phase-code LSB only holds on one non-wrap branch. An
    // interval touching either endpoint of [-pi,pi) cannot prove direction.
    // Inclusive guard: codes -2^35..-2^35+3 and 2^35-3..2^35-1.
    wire phase_boundary=(p<=-36'sd34359738365) || (p>=36'sd34359738365);
    wire [64:0] a_wide={1'b0,a}, f_wide={16'b0,f};
    // Two RNE half-LSB source intervals overlap for a-f in {-1,0,+1}.
    // Accept ONLY a-f >=2. This is not a tolerance permitting rho>=0.5.
    wire ambiguous=f_wide>a_wide+65'd1;
    wire uncertain=!(a_wide>f_wide+65'd1) && !ambiguous;

    wire div_start_ready,div_result_valid,div_zero;
    wire div_start=resetn && !abort && (state==G_START || state==E_START);
    wire div_take=state==G_WAIT || state==E_WAIT;
    wire [99:0] numerator=state==G_START ? {a,36'b0} :
        ({48'b0,gain_pi}+ONE_GAIN+100'd1);
    wire [99:0] denominator=state==G_START ? {51'b0,f} :
        ({50'b0,f,1'b0}-100'd1);
    wire [99:0] quotient,remainder;
    // Local abort/fault resets divider too; no stale response can leak to a
    // new task. There are no external in-flight memory/bus transactions here.
    fine_unsigned_divider #(.WIDTH(100)) divider (
        .clk(clk),.resetn(resetn && !abort && state!=FAULT),
        .start_valid(div_start),.start_ready(div_start_ready),
        .numerator(numerator),.denominator(denominator),
        .result_valid(div_result_valid),.result_ready(div_take),
        .divide_by_zero(div_zero),.quotient(quotient),.remainder(remainder));
    wire [100:0] twice_rem={remainder,1'b0};
    wire [100:0] freq_divisor={52'b0,f};
    wire gain_round_up=(twice_rem>freq_divisor) ||
        (twice_rem==freq_divisor && quotient[0]);
    wire [100:0] rounded_gain={1'b0,quotient}+{{100{1'b0}},gain_round_up};
    // |gain_true-gain_code/2^36| <= Eg/2^36, including source F24 errors.
    // Eg = 1 + ceil((G + 2^36 + 1)/(2*f_code - 1)). See derivation in docs.
    wire [100:0] error_gain=101'd1+{1'b0,quotient}+
        {{100{1'b0}},(remainder!=100'd0)};
    wire [53:0] gain_plus_error={2'b0,gain_pi}+{43'b0,eg_code};
    wire [56:0] phase_error_six=({3'b0,gain_plus_error}<<2)+
        ({3'b0,gain_plus_error}<<1);
    wire [56:0] phase_error_ceil=(phase_error_six+57'd68719476735)>>36;
    // epsilon_p = 3*2^-35, |p|<=1 and <=0.5 u-code rounding.
    wire [56:0] tolerance_work=phase_error_ceil+{46'b0,eg_code}+57'd1;
    wire [88:0] product_abs=product[88] ? -$unsigned(product) : $unsigned(product);
    wire product_round_up=(product_abs[34:0]>35'h400000000) ||
        (product_abs[34:0]==35'h400000000 && product_abs[35]);
    wire [53:0] u_magnitude=product_abs[88:35]+{{53{1'b0}},product_round_up};
    wire signed [53:0] rounded_u=product[88] ? -$signed(u_magnitude) : $signed(u_magnitude);
    wire signed [53:0] limit_u=ONE_U+$signed({43'b0,u_tolerance});
    assign start_ready=resetn && state==IDLE && !abort;
    assign result_valid=resetn && state==RESULT && !abort;
    assign fault_valid=resetn && state==FAULT;
    assign busy=state!=IDLE && state!=RESULT && state!=FAULT;

    always @(posedge clk) begin
        if(!resetn) begin
            state<=IDLE; cal_ok<=0; phase_ok<=0; geo_ok<=0; p<=0; f<=0; a<=0;
            eg_code<=0; product<=0; wait_cycles<=0; abort_ack<=0; fault_code<=0;
            result_epoch<=0; result_seq<=0; result_config_version<=0;
            argument_valid<=0; status<=0; u<=0; u_unchecked<=0;
            gain_pi<=0; u_tolerance<=0; domain_clamped<=0;
        end else begin
            abort_ack<=0;
            if(abort && state!=IDLE && state!=FAULT) begin
                state<=IDLE; abort_ack<=1; argument_valid<=0;
                u<=0; u_unchecked<=0; domain_clamped<=0;
            end else case(state)
                IDLE: if(start_valid && start_ready) begin
                    cal_ok<=calibrated_phase_valid; phase_ok<=phase_encoding_valid;
                    geo_ok<=geometry_valid; p<=phase_cal; f<=f_hat_hz; a<=geometry_a_hz;
                    result_epoch<=session_epoch; result_seq<=candidate_seq;
                    result_config_version<=config_version;
                    argument_valid<=0; status<=OK; u<=0; u_unchecked<=0;
                    gain_pi<=0; eg_code<=0; u_tolerance<=0; domain_clamped<=0;
                    fault_code<=0; state<=CHECK;
                end
                CHECK: begin
                    // Match PS input-check priority; finite/encoding source
                    // checks must occur before narrowing to this fixed format.
                    if(!cal_ok) begin status<=UNCALIBRATED; state<=RESULT; end
                    else if(f==0) begin status<=INVALID_FREQUENCY; state<=RESULT; end
                    else if(!phase_ok) begin status<=INVALID_PHASE; state<=RESULT; end
                    else if(!geo_ok || a==0) begin status<=INVALID_GEOMETRY; state<=RESULT; end
                    else if(ambiguous) begin status<=SPATIAL_AMBIGUITY; state<=RESULT; end
                    else if(uncertain) begin status<=GEOMETRY_BOUNDARY_UNCERTAIN; state<=RESULT; end
                    else state<=G_START;
                end
                G_START,E_START: if(div_start_ready) begin
                    wait_cycles<=0; state<=state==G_START ? G_WAIT : E_WAIT;
                end
                G_WAIT: if(div_result_valid) begin
                    if(div_zero) begin fault_code<=8'h50; state<=FAULT; end
                    else if(rounded_gain[100:52]!=0 || rounded_gain==0) begin
                        status<=GEOMETRY_NUMERIC_RANGE; state<=RESULT;
                    end else begin gain_pi<=rounded_gain[51:0]; state<=E_START; end
                end else if(wait_cycles==8'd110) begin fault_code<=8'h50; state<=FAULT; end
                else wait_cycles<=wait_cycles+8'd1;
                E_WAIT: if(div_result_valid) begin
                    if(div_zero) begin fault_code<=8'h50; state<=FAULT; end
                    else if(error_gain>101'd1024) begin status<=GEOMETRY_NUMERIC_RANGE; state<=RESULT; end
                    else begin eg_code<=error_gain[10:0]; state<=MULTIPLY; end
                end else if(wait_cycles==8'd110) begin fault_code<=8'h50; state<=FAULT; end
                else wait_cycles<=wait_cycles+8'd1;
                MULTIPLY: begin
                    // Signed 36 x zero-extended unsigned 52 => explicit S89.
                    product<=$signed(p)*$signed({1'b0,gain_pi}); state<=ROUND_U;
                end
                ROUND_U: begin
                    u_unchecked<=rounded_u;
                    if(tolerance_work>57'd1024) begin status<=GEOMETRY_NUMERIC_RANGE; state<=RESULT; end
                    else begin u_tolerance<=tolerance_work[10:0]; state<=DOMAIN; end
                end
                DOMAIN: begin
                    if(u_unchecked>limit_u || u_unchecked<-limit_u) begin status<=ASIN_DOMAIN; state<=RESULT; end
                    else if(phase_boundary) begin status<=PHASE_BOUNDARY_UNCERTAIN; state<=RESULT; end
                    else begin
                        if(u_unchecked>ONE_U) begin u<=38'sh1000000000; domain_clamped<=1; end
                        else if(u_unchecked<-ONE_U) begin u<=-38'sh1000000000; domain_clamped<=1; end
                        else u<=u_unchecked[37:0];
                        argument_valid<=1; status<=OK; state<=RESULT;
                    end
                end
                RESULT: if(result_ready) state<=IDLE;
                FAULT: if(fault_clear) begin state<=IDLE; fault_code<=0; end
                default: begin argument_valid<=0; u<=0; fault_code<=8'h51; state<=FAULT; end
            endcase
        end
    end
endmodule
