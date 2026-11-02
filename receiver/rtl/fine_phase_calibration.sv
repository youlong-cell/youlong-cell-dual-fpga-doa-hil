`timescale 1ns/1ps
// adc_clk only; synchronous active-low reset. NOT an AXI/CDC bridge.
// Snapshot occurs at WHOLE Fine task start, BEFORE the DFT/phase latency.
// shadow -> complete COMMIT -> active image -> per-task immutable snapshot.
// Math stage only: neither result handshake nor abort releases a Window.
module fine_phase_calibration (
    input wire clk,resetn,
    input wire cfg_shadow_valid,output wire cfg_shadow_ready,
    input wire [3:0] cfg_shadow_addr,input wire [31:0] cfg_shadow_data,
    output reg cfg_shadow_error,
    input wire cfg_commit_valid,output wire cfg_commit_ready,
    output reg cfg_commit_ack,output reg [7:0] cfg_commit_status,
    output reg [31:0] active_generation,
    input wire task_start_valid,output wire task_start_ready,
    input wire [31:0] candidate_seq,input wire [31:0] sample_rate_hz,
    input wire phase_valid,output wire phase_ready,
    input wire [31:0] phase_seq,
    input wire phase_numeric_valid,input wire [7:0] phase_status,
    input wire signed [35:0] phase_raw,input wire [48:0] f_hat_hz,
    input wire abort,output reg abort_ack,output wire busy,
    output wire result_valid,input wire result_ready,
    output reg [31:0] result_seq,result_generation,result_profile_id,
    output reg numeric_valid,output reg [7:0] result_status,
    output reg calibrated_valid,output reg [7:0] calibration_status,
    output reg signed [35:0] result_phase_raw,phase_cal,
    output reg [48:0] result_f_hat_hz,
    output wire fault_valid,output reg [7:0] fault_code,input wire fault_clear
);
    // Configuration image, ALL 10 words must be written before each COMMIT.
    // 0 valid; 1 sign (signed 32, EXACT +/-1); 2/3 bias signed64/F35 pi units;
    // 4/5 f_min U64/F24 Hz; 6/7 f_max U64/F24 Hz; 8 profile_id; 9 encoding_flags.
    // flags!=0 represents rejected/nonfinite/out-of-range source conversion.
    // Use WIDE transport fields so invalid values are checked BEFORE narrowing.
    localparam integer CONFIG_WORDS=10;
    localparam [3:0] IDLE=0,WAIT_PHASE=1,CHECK=2,SUBTRACT=3,SIGN=4,WRAP=5,RESULT=6,FAULT=7;
    localparam signed [63:0] PI_CODE=64'sh0000000800000000;
    reg [3:0] state;
    reg [31:0] shadow[0:CONFIG_WORDS-1];
    reg [31:0] active[0:CONFIG_WORDS-1];
    reg [31:0] snapshot[0:CONFIG_WORDS-1];
    reg [CONFIG_WORDS-1:0] written;
    reg [31:0] fs;
    reg signed [36:0] difference;
    reg signed [37:0] signed_difference;
    wire signed [63:0] snap_bias=$signed({snapshot[3],snapshot[2]});
    wire [63:0] snap_min={snapshot[5],snapshot[4]};
    wire [63:0] snap_max={snapshot[7],snapshot[6]};
    wire signed [31:0] snap_sign=$signed(snapshot[1]);
    // Compare 2*fmax and Fs in F24 WITHOUT a half-rate right-shift rounding.
    wire [64:0] max_twice={snap_max,1'b0};
    wire [64:0] fs_f24={9'b0,fs,24'b0};
    wire config_invalid=snapshot[0]!=32'd1 || snapshot[9]!=32'd0 ||
        snap_bias < -PI_CODE || snap_bias >= PI_CODE ||
        (snap_sign!=32'sd1 && snap_sign!=-32'sd1) || snapshot[8]==32'd0 ||
        snap_min==64'd0 || snap_max<snap_min || max_twice>=fs_f24 ||
        snap_min[63:49]!=15'd0 || snap_max[63:49]!=15'd0;
    wire [63:0] freq_wide={15'b0,result_f_hat_hz};

    assign cfg_commit_ready=resetn;
    // COMMIT wins over a simultaneous shadow write: the write is NOT accepted.
    // Producer must keep valid/data/address until cfg_shadow_ready.
    assign cfg_shadow_ready=resetn && !cfg_commit_valid;
    assign task_start_ready=resetn && state==IDLE && !abort;
    assign phase_ready=resetn && state==WAIT_PHASE && !abort;
    assign result_valid=state==RESULT && !abort;
    assign fault_valid=state==FAULT;
    assign busy=state!=IDLE && state!=RESULT && state!=FAULT;
    integer cfg_j,snap_j;
    always @(posedge clk) begin
        if(!resetn) begin
            written<=0; cfg_shadow_error<=0; cfg_commit_ack<=0; cfg_commit_status<=0; active_generation<=0;
            for(cfg_j=0;cfg_j<CONFIG_WORDS;cfg_j=cfg_j+1) begin shadow[cfg_j]<=0; active[cfg_j]<=0; end
        end else begin
            cfg_shadow_error<=0; cfg_commit_ack<=0;
            if(cfg_shadow_valid && cfg_shadow_ready) begin
                if(cfg_shadow_addr<CONFIG_WORDS) begin
                    shadow[cfg_shadow_addr]<=cfg_shadow_data; written[cfg_shadow_addr]<=1;
                end else cfg_shadow_error<=1;
            end
            if(cfg_commit_valid && cfg_commit_ready) begin
                cfg_commit_ack<=1;
                if(&written) begin
                    for(cfg_j=0;cfg_j<CONFIG_WORDS;cfg_j=cfg_j+1) active[cfg_j]<=shadow[cfg_j];
                    active_generation<=active_generation+32'd1;
                    written<=0; cfg_commit_status<=0;
                end else cfg_commit_status<=1; // INCOMPLETE: old active image retained.
            end
        end
    end
    always @(posedge clk) begin
        if(!resetn) begin
            state<=IDLE; fs<=0; difference<=0; signed_difference<=0; abort_ack<=0;
            result_seq<=0; result_generation<=0; result_profile_id<=0;
            numeric_valid<=0; result_status<=0; calibrated_valid<=0; calibration_status<=0;
            result_phase_raw<=0; phase_cal<=0; result_f_hat_hz<=0; fault_code<=0;
            for(snap_j=0;snap_j<CONFIG_WORDS;snap_j=snap_j+1) snapshot[snap_j]<=0;
        end else begin
            abort_ack<=0;
            // Cancellation is local; upstream correlator must independently drain.
            if(abort && state!=IDLE && state!=FAULT) begin
                state<=IDLE; abort_ack<=1; numeric_valid<=0; calibrated_valid<=0; phase_cal<=0;
            end else case(state)
                IDLE: if(task_start_valid && task_start_ready) begin
                    // NBA semantics intentionally choose PRE-COMMIT active image
                    // if COMMIT and start are accepted on the same clock edge.
                    for(snap_j=0;snap_j<CONFIG_WORDS;snap_j=snap_j+1) snapshot[snap_j]<=active[snap_j];
                    result_seq<=candidate_seq; result_generation<=active_generation; fs<=sample_rate_hz;
                    result_profile_id<=0; numeric_valid<=0; calibrated_valid<=0;
                    result_status<=0; calibration_status<=0; result_phase_raw<=0; phase_cal<=0;
                    result_f_hat_hz<=0; fault_code<=0; state<=WAIT_PHASE;
                end
                WAIT_PHASE: if(phase_valid && phase_ready) begin
                    if(phase_seq!=result_seq || (phase_numeric_valid && phase_status!=0)) begin
                        fault_code<=8'h40; numeric_valid<=0; calibrated_valid<=0; state<=FAULT;
                    end else begin
                        result_phase_raw<=phase_raw; result_f_hat_hz<=f_hat_hz;
                        numeric_valid<=phase_numeric_valid;
                        result_status<=(!phase_numeric_valid && phase_status==0) ? 8'd7 : phase_status;
                        state<=CHECK;
                    end
                end
                CHECK: begin
                    // Same priority as production C: invalid raw phase does not
                    // run calibration; valid=0 stays UNCONFIGURED even if other
                    // disabled fields are invalid. Raw validity remains separate.
                    if(!numeric_valid || snapshot[0]==32'd0) state<=RESULT;
                    else if(config_invalid) begin calibration_status<=2; state<=RESULT; end
                    else if(freq_wide<snap_min || freq_wide>snap_max) begin calibration_status<=3; state<=RESULT; end
                    else state<=SUBTRACT;
                end
                SUBTRACT: begin
                    // LOCKED ORDER: first (raw-bias) with signed extension.
                    difference<=$signed({result_phase_raw[35],result_phase_raw})-
                        $signed({snap_bias[35],snap_bias[35:0]});
                    state<=SIGN;
                end
                SIGN: begin
                    // THEN sign*(raw-bias). Widen BEFORE negating so -(-pi)
                    // and all +/-2pi work values are representable until wrap.
                    signed_difference<=snap_sign==-32'sd1 ?
                        -$signed({difference[36],difference}) : $signed({difference[36],difference});
                    state<=WRAP;
                end
                WRAP: begin
                    // LAST wrap: modulo 2^36 = modulo 2pi; no extra RNE here.
                    phase_cal<=signed_difference[35:0]; calibrated_valid<=1;
                    calibration_status<=1; result_profile_id<=snapshot[8]; state<=RESULT;
                end
                RESULT: if(result_ready) state<=IDLE;
                FAULT: if(fault_clear) begin state<=IDLE; fault_code<=0; end
                default: begin numeric_valid<=0; calibrated_valid<=0; fault_code<=8'h41; state<=FAULT; end
            endcase
        end
    end
endmodule
