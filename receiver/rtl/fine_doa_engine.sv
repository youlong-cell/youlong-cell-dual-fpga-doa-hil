`timescale 1ns/1ps
// Independent adc_clk full Fine/DOA integration. NO AXI/production BD hookup.
// Reuses one FRAME/WINDOW estimator, cross, calibration, argument and arcsin.
// Normal numeric-invalid results also consume/release the candidate. Results
// become visible ONLY after matching successful ownership RELEASE_ACK.
// Result slot occupancy never blocks the next window; full slot drops NEW result.
module fine_doa_engine #(
    parameter HANN_FRAME_FILE="fine_hann_1024.mem",
    parameter HANN_WINDOW_FILE="fine_hann_4096.mem",
    parameter NCO_FILE="fine_nco_16384.mem",
    parameter LOG_ROM_FILE="fine_log2_8193.mem",
    parameter ATAN_ROM_FILE="fine_atan_48.mem",
    parameter integer READ_TIMEOUT_CYCLES=4096,
    parameter integer RELEASE_TIMEOUT_CYCLES=4096,
    parameter integer CORDIC_TIMEOUT_CYCLES=512,
    parameter integer ENABLE_MAINTENANCE=0
) (
    input wire clk,resetn,
    input wire maintenance_hold,
    output wire maintenance_ready,
    // Ordered, atomic configuration commands already in adc_clk. NOT MMIO.
    input wire cfg_shadow_valid, output wire cfg_shadow_ready,
    input wire [4:0] cfg_shadow_addr, input wire [31:0] cfg_shadow_data,
    output wire cfg_shadow_error,
    input wire cfg_commit_valid, output wire cfg_commit_ready,
    output wire cfg_commit_ack, output wire [7:0] cfg_commit_status,
    output wire [31:0] active_config_version,
    input wire session_valid, input wire [63:0] session_epoch,
    input wire window_offer_valid, output wire window_offer_ready,
    input wire [31:0] window_offer_seq, input wire [479:0] window_offer_meta,
    output wire fine_rd_req, input wire fine_rd_ready,
    output wire [11:0] fine_rd_addr,
    input wire fine_rd_valid, input wire [31:0] fine_rd_data,
    input wire [11:0] fine_rd_index,
    output wire fine_busy, output wire fine_done, output wire fine_fault,
    output wire fine_result_latched, output wire [31:0] fine_seq,
    input wire fine_abort, fine_release_ack, fine_release_granted,
    input wire [31:0] fine_release_seq,
    // Local recovery only AFTER owner tagged CLEAR and drained reads. An ACK
    // timeout/failure requires coordinated reset; do not fabricate a result.
    input wire fault_clear, output wire fault_valid,
    output reg [7:0] fault_code,
    output wire result_valid,
    // Atomic tagged RESULT_ACK commands, already transferred into adc_clk.
    input wire result_ack_valid, input wire [63:0] result_ack_epoch,
    input wire [31:0] result_ack_seq,result_ack_config_version,
    output wire result_ack_response_valid,result_ack_granted,
    output wire [63:0] result_ack_response_epoch,
    output wire [31:0] result_ack_response_seq,result_ack_response_config_version,
    output wire [31:0] result_drop_count,result_protocol_error_count,
    output wire [63:0] result_last_drop_epoch,
    output wire [31:0] result_last_drop_seq,result_last_drop_config_version,
    output wire [63:0] result_epoch,
    output wire [31:0] result_seq,result_config_version,result_frame_seq,
    output wire [47:0] result_window_start_id,result_frame_start_id,result_event_id,
    output wire [9:0] result_bin,
    output wire [48:0] result_f_hat_hz,
    output wire [47:0] result_phase_increment,
    output wire signed [33:0] result_delta,
    output wire signed [36:0] result_prominence,
    output wire signed [37:0] result_curvature,
    output wire [7:0] result_interpolation_status,
    output wire result_window_present,
    output wire signed [40:0] result_i0,result_q0,result_i1,result_q1,
    output wire result_numeric_valid,output wire [7:0] result_status,
    output wire result_calibrated_valid,output wire [7:0] result_calibration_status,
    output wire signed [35:0] result_phase_raw,result_phase_cal,
    output wire [31:0] result_profile_id,
    // Legacy profile name aliases the SAME immutable calibration field.
    output wire [31:0] result_calibration_profile_id,result_geometry_id,
    // Six little-word-order ABI words; no duplicated identity storage.
    output wire [191:0] result_identity,
    // Atomic production transport: low 192 bits are the six-word identity.
    output wire [1087:0] result_transport,
    // Final numerical validity is DOA validity; earlier Fine validity is separate.
    output wire result_fine_numeric_valid,
    output wire [3:0] result_status_stage,
    output wire result_theta_valid, output wire signed [35:0] result_theta,
    output wire signed [37:0] result_u,
    output wire signed [53:0] result_u_unchecked,
    output wire [51:0] result_gain_pi, output wire [10:0] result_u_tolerance,
    output wire result_domain_clamped,result_near_endfire,result_theta_endpoint_snapped,
    output wire [4:0] lifecycle_state,
    // Connect the two dedicated verified CORDIC IPs in this clock domain.
    output wire cordic_aresetn,
    output wire sqrt_in_valid, input wire sqrt_in_ready, output wire [47:0] sqrt_in_data,
    input wire sqrt_out_valid, output wire sqrt_out_ready, input wire [47:0] sqrt_out_data,
    output wire translate_in_valid, input wire translate_in_ready, output wire [79:0] translate_in_data,
    input wire translate_out_valid, output wire translate_out_ready, input wire [79:0] translate_out_data
);
    localparam [4:0] IDLE=0,ACCEPT_WINDOW=1,THREE_BIN=2,FREQ_READY=3,FINE_4K=4,
        PHASE_START=5,CROSS_PHASE=6,CALIBRATE=7,ARG_START=8,DOA_ARGUMENT=9,
        ASIN_START=10,ASIN=11,RESULT_PENDING=12,WAIT_ACK=13,PUBLISH=14,
        FAULT_NOTIFY=15,FAULT_HOLD=16,RECOVER=17,ACK_BLOCKED=18;
    // 0..18 preserve the Fine configuration image. 19 geometry_valid (exact
    // 0/1); 20/21 A=c/(2d), U64/F24 Hz; 22 geometry source-conversion flags.
    // Word 23: geometry_id, zero means provenance unconfigured.
    // A must come from validated d/c, NOT from a separate incompatible Kgeo.
    localparam integer CONFIG_WORDS=24;
    reg [4:0] state;
    assign lifecycle_state=state;

    // Working/pending context is private to the current candidate. Published
    // outputs below are a separate immutable slot, not these task registers.
    reg [63:0] task_epoch;
    reg [31:0] task_seq,task_config_version,task_frame_seq;
    reg [47:0] task_window_start_id,task_frame_start_id,task_event_id;
    reg [9:0] task_bin;
    reg [48:0] task_f_hat_hz;
    reg [47:0] task_phase_increment;
    reg signed [33:0] task_delta;
    reg signed [36:0] task_prominence;
    reg signed [37:0] task_curvature;
    reg [7:0] task_interpolation_status;
    reg task_window_present;
    reg signed [40:0] task_i0,task_q0,task_i1,task_q1;
    reg task_numeric_valid;
    reg [7:0] task_status;
    reg task_calibrated_valid;
    reg [7:0] task_calibration_status;
    reg signed [35:0] task_phase_raw,task_phase_cal;
    reg [31:0] task_profile_id,task_geometry_id;
    reg task_fine_numeric_valid;
    reg [3:0] task_status_stage;
    reg task_theta_valid;
    reg signed [35:0] task_theta;
    reg signed [37:0] task_u;
    reg signed [53:0] task_u_unchecked;
    reg [51:0] task_gain_pi;
    reg [10:0] task_u_tolerance;
    reg task_domain_clamped,task_near_endfire,task_theta_endpoint_snapped;
    localparam integer RESULT_PAYLOAD_WIDTH=1047;
    wire [RESULT_PAYLOAD_WIDTH-1:0] result_payload;
    wire abort_children;
    wire [RESULT_PAYLOAD_WIDTH-1:0] offer_payload;
    // ABI字段排列集中在组合模块；槽位存储、ACK和流程仍沿用原实例。
    fine_result_abi result_abi (
        .result_payload(result_payload), .offer_payload(offer_payload),
        .task_epoch(task_epoch),
        .task_seq(task_seq),
        .task_config_version(task_config_version),
        .task_frame_seq(task_frame_seq),
        .task_window_start_id(task_window_start_id),
        .task_frame_start_id(task_frame_start_id),
        .task_event_id(task_event_id),
        .task_bin(task_bin),
        .task_f_hat_hz(task_f_hat_hz),
        .task_phase_increment(task_phase_increment),
        .task_delta(task_delta),
        .task_prominence(task_prominence),
        .task_curvature(task_curvature),
        .task_interpolation_status(task_interpolation_status),
        .task_window_present(task_window_present),
        .task_i0(task_i0),
        .task_q0(task_q0),
        .task_i1(task_i1),
        .task_q1(task_q1),
        .task_numeric_valid(task_numeric_valid),
        .task_status(task_status),
        .task_calibrated_valid(task_calibrated_valid),
        .task_calibration_status(task_calibration_status),
        .task_phase_raw(task_phase_raw),
        .task_phase_cal(task_phase_cal),
        .task_profile_id(task_profile_id),
        .task_geometry_id(task_geometry_id),
        .task_fine_numeric_valid(task_fine_numeric_valid),
        .task_status_stage(task_status_stage),
        .task_theta_valid(task_theta_valid),
        .task_theta(task_theta),
        .task_u(task_u),
        .task_u_unchecked(task_u_unchecked),
        .task_gain_pi(task_gain_pi),
        .task_u_tolerance(task_u_tolerance),
        .task_domain_clamped(task_domain_clamped),
        .task_near_endfire(task_near_endfire),
        .task_theta_endpoint_snapped(task_theta_endpoint_snapped),
        .result_epoch(result_epoch),
        .result_seq(result_seq),
        .result_config_version(result_config_version),
        .result_frame_seq(result_frame_seq),
        .result_window_start_id(result_window_start_id),
        .result_frame_start_id(result_frame_start_id),
        .result_event_id(result_event_id),
        .result_bin(result_bin),
        .result_f_hat_hz(result_f_hat_hz),
        .result_phase_increment(result_phase_increment),
        .result_delta(result_delta),
        .result_prominence(result_prominence),
        .result_curvature(result_curvature),
        .result_interpolation_status(result_interpolation_status),
        .result_window_present(result_window_present),
        .result_i0(result_i0),
        .result_q0(result_q0),
        .result_i1(result_i1),
        .result_q1(result_q1),
        .result_numeric_valid(result_numeric_valid),
        .result_status(result_status),
        .result_calibrated_valid(result_calibrated_valid),
        .result_calibration_status(result_calibration_status),
        .result_phase_raw(result_phase_raw),
        .result_phase_cal(result_phase_cal),
        .result_profile_id(result_profile_id),
        .result_geometry_id(result_geometry_id),
        .result_fine_numeric_valid(result_fine_numeric_valid),
        .result_status_stage(result_status_stage),
        .result_theta_valid(result_theta_valid),
        .result_theta(result_theta),
        .result_u(result_u),
        .result_u_unchecked(result_u_unchecked),
        .result_gain_pi(result_gain_pi),
        .result_u_tolerance(result_u_tolerance),
        .result_domain_clamped(result_domain_clamped),
        .result_near_endfire(result_near_endfire),
        .result_theta_endpoint_snapped(result_theta_endpoint_snapped),
        .result_calibration_profile_id(result_calibration_profile_id),
        .result_identity(result_identity),
        .result_transport(result_transport)
    );
    wire maintenance_active=(ENABLE_MAINTENANCE!=0) && maintenance_hold;
    reg maintenance_seen;
    wire maintenance_cancel=maintenance_active && !maintenance_seen;
    always @(posedge clk) begin
        if(!resetn) maintenance_seen<=0;
        else maintenance_seen<=maintenance_active;
    end
    fine_result_slot #(.PAYLOAD_WIDTH(RESULT_PAYLOAD_WIDTH),.ENABLE_MAINTENANCE(ENABLE_MAINTENANCE)) result_slot (
        .clk(clk),.resetn(resetn),
        .maintenance_invalidate(maintenance_active),
        .offer_valid(state==PUBLISH && !abort_children),
        .offer_payload(offer_payload),
        .offer_epoch(task_epoch),.offer_seq(task_seq),.offer_config_version(task_config_version),
        .offer_stored(),.offer_dropped(),.result_valid(result_valid),.result_payload(result_payload),
        .ack_valid(result_ack_valid),.ack_epoch(result_ack_epoch),.ack_seq(result_ack_seq),
        .ack_config_version(result_ack_config_version),.ack_response_valid(result_ack_response_valid),
        .ack_granted(result_ack_granted),.ack_response_epoch(result_ack_response_epoch),
        .ack_response_seq(result_ack_response_seq),.ack_response_config_version(result_ack_response_config_version),
        .drop_count(result_drop_count),.protocol_error_count(result_protocol_error_count),
        .last_drop_epoch(result_last_drop_epoch),.last_drop_seq(result_last_drop_seq),
        .last_drop_config_version(result_last_drop_config_version));

    reg task_geo_valid,argument_ok,angle_abort_sent;
    reg [63:0] task_geometry_a;
    wire [1:0] e_stage;
    wire d_ready,d_result,d_valid,d_busy,d_fault;
    wire [63:0] d_epoch;
    wire [31:0] d_seq,d_version;
    wire [7:0] d_status,d_fault_code;
    wire signed [37:0] d_u;
    wire signed [53:0] d_raw;
    wire [51:0] d_gain;
    wire [10:0] d_tau;
    wire d_clamp;
    wire a_ready,a_result,a_valid,a_busy,a_fault;
    wire [63:0] a_epoch;
    wire [31:0] a_seq,a_version;
    wire [7:0] a_status,a_fault_code;
    wire signed [35:0] a_theta;
    wire signed [37:0] a_u;
    wire [10:0] a_tau;
    wire a_clamp,a_endfire,a_snap;
    // 同名观察线保留，实际配置寄存器由独立模块拥有。
    wire [31:0] active[0:CONFIG_WORDS-1];
    wire [23:0] written;
    wire [767:0] active_words;
    genvar config_word;
    generate for(config_word=0; config_word<CONFIG_WORDS; config_word=config_word+1) begin: config_view
        assign active[config_word]=active_words[config_word*32 +: 32];
    end endgenerate
    reg pending_latched,owner_abort_seen,task_config_bad;
    reg [31:0] ack_wait_cycles;
    wire e_ready,e_result,e_numeric,e_busy,e_fault;
    wire [7:0] e_status,e_fault_code,e_interp;
    wire [31:0] e_seq,e_frame_seq;
    wire [47:0] e_window_id,e_frame_id,e_event_id,e_fcw;
    wire [9:0] e_bin;
    wire [48:0] e_freq;
    wire signed [33:0] e_delta;
    wire signed [36:0] e_prominence;
    wire signed [37:0] e_curvature;
    wire e_window_present;
    wire signed [40:0] e_i0,e_q0,e_i1,e_q1;
    wire c_start_ready,c_phase_ready,c_result,c_busy,c_fault;
    wire [7:0] c_status,c_cal_status,c_fault_code;
    wire [31:0] c_seq,c_version,c_profile;
    wire c_numeric,c_cal_valid;
    wire signed [35:0] c_raw,c_cal;
    wire [48:0] c_freq;
    wire p_ready,p_result,p_busy,p_fault,p_numeric;
    wire [7:0] p_status,p_fault_code;
    wire [31:0] p_seq;
    wire signed [35:0] p_phase;
    wire cal_shadow_ready,cal_commit_ready,cal_commit_ack,cal_shadow_error;
    wire [7:0] cal_commit_status;
    wire [31:0] cal_active_generation;
    wire cfg_complete,commit_install,bad_quality_encoding;
    fine_doa_config configuration (
        .clk(clk), .resetn(resetn), .maintenance_cancel(maintenance_cancel),
        .cfg_shadow_valid(cfg_shadow_valid), .cfg_shadow_ready(cfg_shadow_ready),
        .cfg_shadow_addr(cfg_shadow_addr), .cfg_shadow_data(cfg_shadow_data),
        .cfg_shadow_error(cfg_shadow_error), .cfg_commit_valid(cfg_commit_valid),
        .cfg_commit_ready(cfg_commit_ready), .cfg_commit_ack(cfg_commit_ack),
        .cfg_commit_status(cfg_commit_status), .active_config_version(active_config_version),
        .cal_shadow_ready(cal_shadow_ready), .cal_commit_ready(cal_commit_ready),
        .cfg_complete(cfg_complete), .commit_install(commit_install),
        .bad_quality_encoding(bad_quality_encoding), .written(written), .active_words(active_words)
    );
    wire take=window_offer_valid && window_offer_ready;
    assign maintenance_ready=state==IDLE && e_ready && p_ready && c_start_ready &&
                             d_ready && a_ready && !fine_rd_req && !fine_rd_valid && !result_valid;
    assign abort_children=(fine_abort && !maintenance_active) || maintenance_cancel || state==FAULT_NOTIFY || state==FAULT_HOLD ||
                        state==ACK_BLOCKED;
    wire clear_children=state==RECOVER;
    // Reject wide transport fields BEFORE truncation; no implicit default
    // quality thresholds. Calibration validates its own ten wide words.
    wire [47:0] offer_window={window_offer_meta[239:224],window_offer_meta[223:192]};
    wire [47:0] offer_frame={window_offer_meta[111:96],window_offer_meta[95:64]};
    wire [47:0] offer_event={window_offer_meta[175:160],window_offer_meta[159:128]};
    wire bad_meta=window_offer_meta[31:0]!=window_offer_seq ||
                  window_offer_meta[127:112]!=0 || window_offer_meta[191:176]!=0 ||
                  window_offer_meta[255:240]!=0 || window_offer_meta[287:273]!=0 ||
                  window_offer_meta[479:448]!=32'h00010000;
    assign window_offer_ready=resetn && state==IDLE && e_ready && c_start_ready &&
                              p_ready && d_ready && a_ready && session_valid && session_epoch!=0 && !fine_abort && !maintenance_active;
    assign fine_seq=task_seq;
    assign fine_done=resetn && !abort_children && state==RESULT_PENDING && !e_busy && !p_busy && !c_busy && !d_busy && !a_busy &&
                     !fine_rd_req && !fine_rd_valid;
    assign fine_fault=resetn && state==FAULT_NOTIFY;
    assign fine_result_latched=pending_latched;
    // Fault stays busy while an accepted RAM response is still outstanding.
    assign fine_busy=e_busy || p_busy || c_busy || d_busy || a_busy ||
        (state!=IDLE && state!=RESULT_PENDING && state!=WAIT_ACK && state!=PUBLISH &&
         state!=FAULT_NOTIFY && state!=FAULT_HOLD && state!=ACK_BLOCKED);
    assign fault_valid=resetn && (state==FAULT_NOTIFY || state==FAULT_HOLD || state==ACK_BLOCKED);

    fine_three_bin_estimator #(.HANN_FRAME_FILE(HANN_FRAME_FILE),
        .HANN_WINDOW_FILE(HANN_WINDOW_FILE),.NCO_FILE(NCO_FILE),
        .USE_QUALITY_INTERPOLATION(1),.QUALITY_LOG_ROM_FILE(LOG_ROM_FILE),
        .ENABLE_WINDOW_STAGE(1),.READ_TIMEOUT_CYCLES(READ_TIMEOUT_CYCLES)) estimator (
        .clk(clk),.resetn(resetn),.start_valid(take),.start_ready(e_ready),
        .candidate_seq(window_offer_seq),.frame_seq(window_offer_meta[63:32]),
        .window_start_sample_id(offer_window),.frame_start_sample_id(offer_frame),
        .event_sample_id(offer_event),.coarse_bin({1'b0,window_offer_meta[264:256]}),
        .sample_rate_hz(active[10]),.quality_configured(active[11]==1 && !bad_quality_encoding),
        .cfg_P_min({active[13][4:0],active[12]}),.cfg_D_min({active[15][5:0],active[14]}),
        .cfg_delta_max({active[17][0],active[16]}),.cfg_delta_error(active[18]),
        .abort(abort_children),.abort_ack(),.busy(e_busy),
        .fine_rd_req(fine_rd_req),.fine_rd_ready(fine_rd_ready),.fine_rd_addr(fine_rd_addr),
        .fine_rd_valid(fine_rd_valid),.fine_rd_data(fine_rd_data),.fine_rd_index(fine_rd_index),
        .result_valid(e_result),.result_ready((state==THREE_BIN || state==FINE_4K) && !abort_children),
        .numeric_valid(e_numeric),.result_status(e_status),.result_seq(e_seq),.result_frame_seq(e_frame_seq),
        .result_window_start_id(e_window_id),.result_frame_start_id(e_frame_id),.result_event_id(e_event_id),
        .result_bin(e_bin),.delta_bin(e_delta),.f_hat_hz(e_freq),.phase_increment(e_fcw),
        .scores_out(),.logs_out(),.complex_out(),.window_present(e_window_present),
        .window_i0(e_i0),.window_q0(e_q0),.window_i1(e_i1),.window_q1(e_q1),
        .window_mean0(),.window_mean1(),.window_power0(),.window_power1(),
        .curvature(),.curvature_min(),.quality_logs_out(),.quality_prominence(e_prominence),
        .quality_curvature(e_curvature),.interpolation_status(e_interp),.processing_stage(e_stage),
        .fault_valid(e_fault),.fault_code(e_fault_code),.fault_seq(),.fault_clear(clear_children));
    fine_cross_phase #(.ATAN_ROM_FILE(ATAN_ROM_FILE)) cross_phase (
        .clk(clk),.resetn(resetn),.start_valid(state==PHASE_START && !abort_children),.start_ready(p_ready),
        .candidate_seq(task_seq),.input_numeric_valid(task_numeric_valid),.input_status(task_status),
        .i0(task_i0),.q0(task_q0),.i1(task_i1),.q1(task_q1),
        .abort(abort_children),.abort_ack(),.busy(p_busy),
        .result_valid(p_result),.result_ready(state==CROSS_PHASE && c_phase_ready && !abort_children),
        .result_seq(p_seq),.numeric_valid(p_numeric),.status(p_status),.phase_raw(p_phase),
        .cross_re(),.cross_im(),.norm_re(),.norm_im(),.normalization_shift(),
        .fault_valid(p_fault),.fault_code(p_fault_code),.fault_clear(clear_children));
    fine_phase_calibration calibration (
        .clk(clk),.resetn(resetn),
        .cfg_shadow_valid(cfg_shadow_valid && cfg_shadow_ready && cfg_shadow_addr<10),
        .cfg_shadow_ready(cal_shadow_ready),.cfg_shadow_addr(cfg_shadow_addr[3:0]),
        .cfg_shadow_data(cfg_shadow_data),.cfg_shadow_error(cal_shadow_error),
        .cfg_commit_valid(commit_install),.cfg_commit_ready(cal_commit_ready),
        .cfg_commit_ack(cal_commit_ack),.cfg_commit_status(cal_commit_status),.active_generation(cal_active_generation),
        .task_start_valid(take),.task_start_ready(c_start_ready),
        .candidate_seq(window_offer_seq),.sample_rate_hz(active[10]),
        .phase_valid(p_result && state==CROSS_PHASE && !abort_children),.phase_ready(c_phase_ready),
        .phase_seq(p_seq),.phase_numeric_valid(p_numeric),.phase_status(p_status),
        .phase_raw(p_phase),.f_hat_hz(task_f_hat_hz),.abort(abort_children),.abort_ack(),.busy(c_busy),
        .result_valid(c_result),.result_ready(state==CALIBRATE && !abort_children),
        .result_seq(c_seq),.result_generation(c_version),.result_profile_id(c_profile),
        .numeric_valid(c_numeric),.result_status(c_status),.calibrated_valid(c_cal_valid),
        .calibration_status(c_cal_status),.result_phase_raw(c_raw),.phase_cal(c_cal),.result_f_hat_hz(c_freq),
        .fault_valid(c_fault),.fault_code(c_fault_code),.fault_clear(clear_children));

    fine_doa_argument argument (
        .clk(clk),.resetn(resetn),.start_valid(state==ARG_START && !abort_children),.start_ready(d_ready),
        .session_epoch(task_epoch),.candidate_seq(task_seq),.config_version(task_config_version),
        .calibrated_phase_valid(task_calibrated_valid),.phase_encoding_valid(1'b1),
        .geometry_valid(task_geo_valid),.phase_cal(task_phase_cal),
        .f_hat_hz(task_f_hat_hz),.geometry_a_hz(task_geometry_a),
        .abort(abort_children),.abort_ack(),.busy(d_busy),
        .result_valid(d_result),.result_ready(state==DOA_ARGUMENT && !abort_children),
        .result_epoch(d_epoch),.result_seq(d_seq),.result_config_version(d_version),
        .argument_valid(d_valid),.status(d_status),.u(d_u),.u_unchecked(d_raw),
        .gain_pi(d_gain),.u_tolerance(d_tau),.domain_clamped(d_clamp),
        .fault_valid(d_fault),.fault_code(d_fault_code),.fault_clear(clear_children));
    fine_doa_arcsin #(.WATCHDOG_CYCLES(CORDIC_TIMEOUT_CYCLES)) angle (
        .clk(clk),.resetn(resetn),.start_valid(state==ASIN_START && !abort_children),.start_ready(a_ready),
        .session_epoch(task_epoch),.candidate_seq(task_seq),.config_version(task_config_version),
        .argument_valid(argument_ok),.argument_status(task_status),
        .u(task_u),.u_tolerance(task_u_tolerance),.domain_clamped(task_domain_clamped),
        // Owner abort can be a held level. A private-IP reset must be a
        // ONE-shot cancel followed by its 8-clock quarantine; a held abort
        // would keep BOOT busy forever and prevent Manager drain/FAULT.
        .abort(abort_children && !angle_abort_sent),.abort_ack(),.busy(a_busy),
        .result_valid(a_result),.result_ready(state==ASIN && !abort_children),
        .result_epoch(a_epoch),.result_seq(a_seq),.result_config_version(a_version),
        .theta_valid(a_valid),.status(a_status),.theta(a_theta),.result_u(a_u),
        .result_u_tolerance(a_tau),.result_domain_clamped(a_clamp),.near_endfire(a_endfire),
        .theta_endpoint_snapped(a_snap),.fault_valid(a_fault),.fault_code(a_fault_code),
        .fault_clear(clear_children),.cordic_aresetn(cordic_aresetn),
        .sqrt_in_valid(sqrt_in_valid),.sqrt_in_ready(sqrt_in_ready),.sqrt_in_data(sqrt_in_data),
        .sqrt_out_valid(sqrt_out_valid),.sqrt_out_ready(sqrt_out_ready),.sqrt_out_data(sqrt_out_data),
        .translate_in_valid(translate_in_valid),.translate_in_ready(translate_in_ready),
        .translate_in_data(translate_in_data),.translate_out_valid(translate_out_valid),
        .translate_out_ready(translate_out_ready),.translate_out_data(translate_out_data));

    always @(posedge clk) begin
        if(!resetn) begin
            state<=IDLE; pending_latched<=0; owner_abort_seen<=0; task_config_bad<=0;
            task_geo_valid<=0; task_geometry_a<=0; argument_ok<=0; angle_abort_sent<=0;
            task_fine_numeric_valid<=0; task_status_stage<=0;
            task_theta_valid<=0; task_theta<=0; task_u<=0; task_u_unchecked<=0;
            task_gain_pi<=0; task_u_tolerance<=0; task_domain_clamped<=0;
            task_near_endfire<=0; task_theta_endpoint_snapped<=0;
            fault_code<=0; ack_wait_cycles<=0; task_epoch<=0; task_seq<=0;
            task_config_version<=0; task_frame_seq<=0; task_window_start_id<=0;
            task_frame_start_id<=0; task_event_id<=0; task_bin<=0;
            task_f_hat_hz<=0; task_phase_increment<=0; task_delta<=0;
            task_prominence<=0; task_curvature<=0; task_interpolation_status<=8'hff;
            task_window_present<=0; task_i0<=0; task_q0<=0; task_i1<=0; task_q1<=0;
            task_numeric_valid<=0; task_status<=0; task_calibrated_valid<=0;
            task_calibration_status<=0; task_phase_raw<=0; task_phase_cal<=0; task_profile_id<=0; task_geometry_id<=0;
        end else begin
            if(abort_children) angle_abort_sent<=1;
            if(fine_abort) owner_abort_seen<=1;
            case(state)
                IDLE: if(take) begin
                    task_epoch<=session_epoch; task_seq<=window_offer_seq;
                    task_config_version<=active_config_version; task_frame_seq<=window_offer_meta[63:32];
                    task_window_start_id<=offer_window; task_frame_start_id<=offer_frame;
                    task_event_id<=offer_event; task_bin<={1'b0,window_offer_meta[264:256]};
                    task_config_bad<=bad_quality_encoding || bad_meta;
                    pending_latched<=0; owner_abort_seen<=0; fault_code<=0; ack_wait_cycles<=0;
                    task_numeric_valid<=0; task_calibrated_valid<=0; state<=ACCEPT_WINDOW;
                    task_geo_valid<=active[19]==32'd1 && active[22]==0 && active[23]!=32'd0;
                    task_geometry_id<=active[23];
                    task_geometry_a<={active[21],active[20]}; argument_ok<=0; angle_abort_sent<=0;
                    task_fine_numeric_valid<=0; task_status_stage<=0;
                    task_theta_valid<=0; task_theta<=0; task_u<=0; task_u_unchecked<=0;
                    task_gain_pi<=0; task_u_tolerance<=0; task_domain_clamped<=0;
                    task_near_endfire<=0; task_theta_endpoint_snapped<=0;
                end
                ACCEPT_WINDOW: state<=THREE_BIN;
                FREQ_READY: state<=FINE_4K;
                THREE_BIN,FINE_4K: if(e_result) begin
                    if(e_seq!=task_seq || e_frame_seq!=task_frame_seq ||
                       e_window_id!=task_window_start_id || e_frame_id!=task_frame_start_id ||
                       e_event_id!=task_event_id || e_bin!=task_bin) begin
                        fault_code<=8'he0; state<=FAULT_NOTIFY;
                    end else begin
                        task_numeric_valid<=e_numeric && !task_config_bad;
                        task_status<=task_config_bad ? 8'h90 : e_status;
                        task_status_stage<=(!e_numeric || task_config_bad) ?
                            (e_window_present && !task_config_bad ? 4'd2 : 4'd1) : 4'd0;
                        task_f_hat_hz<=e_freq; task_phase_increment<=e_fcw; task_delta<=e_delta;
                        task_prominence<=e_prominence; task_curvature<=e_curvature;
                        task_interpolation_status<=e_interp; task_window_present<=e_window_present;
                        task_i0<=e_i0; task_q0<=e_q0; task_i1<=e_i1; task_q1<=e_q1;
                        state<=PHASE_START;
                    end
                end
                else if(state==THREE_BIN && e_stage==2'd1) state<=FREQ_READY;
                PHASE_START: if(p_ready) state<=CROSS_PHASE;
                CROSS_PHASE: if(p_result && c_phase_ready) begin
                    if(task_numeric_valid && !p_numeric) task_status_stage<=4'd3;
                    state<=CALIBRATE;
                end
                CALIBRATE: if(c_result) begin
                    if(c_seq!=task_seq || c_version!=task_config_version || c_freq!=task_f_hat_hz) begin
                        fault_code<=8'he0; state<=FAULT_NOTIFY;
                    end else begin
                        task_fine_numeric_valid<=c_numeric; task_status<=c_status;
                        task_calibrated_valid<=c_cal_valid; task_calibration_status<=c_cal_status;
                        task_phase_raw<=c_raw; task_phase_cal<=c_cal; task_profile_id<=c_profile;
                        task_numeric_valid<=0;
                        if(!c_numeric) begin pending_latched<=1; state<=RESULT_PENDING; end
                        else state<=ARG_START;
                    end
                end
                ARG_START: if(d_ready) state<=DOA_ARGUMENT;
                DOA_ARGUMENT: if(d_result) begin
                    if(d_epoch!=task_epoch || d_seq!=task_seq || d_version!=task_config_version) begin
                        fault_code<=8'he0; state<=FAULT_NOTIFY;
                    end else begin
                        argument_ok<=d_valid; task_status<=d_status;
                        task_status_stage<=d_valid ? 4'd0 : 4'd5;
                        task_u<=d_u; task_u_unchecked<=d_raw; task_gain_pi<=d_gain;
                        task_u_tolerance<=d_tau; task_domain_clamped<=d_clamp;
                        state<=ASIN_START;
                    end
                end
                ASIN_START: if(a_ready) state<=ASIN;
                ASIN: if(a_result) begin
                    if(a_epoch!=task_epoch || a_seq!=task_seq || a_version!=task_config_version ||
                       a_u!=task_u || a_tau!=task_u_tolerance || a_clamp!=task_domain_clamped ||
                       a_status!=task_status || a_valid!=argument_ok) begin
                        fault_code<=8'he0; state<=FAULT_NOTIFY;
                    end else begin
                        task_numeric_valid<=a_valid; task_theta_valid<=a_valid;
                        task_theta<=a_theta; task_near_endfire<=a_endfire;
                        task_theta_endpoint_snapped<=a_snap; pending_latched<=1; state<=RESULT_PENDING;
                    end
                end
                RESULT_PENDING: if(!e_busy && !p_busy && !c_busy && !d_busy && !a_busy &&
                                    !fine_rd_req && !fine_rd_valid) state<=WAIT_ACK;
                WAIT_ACK: if(fine_release_ack) begin
                    if(fine_release_granted && fine_release_seq==task_seq) state<=PUBLISH;
                    else begin fault_code<=8'he2; state<=ACK_BLOCKED; end
                end else if(ack_wait_cycles>=RELEASE_TIMEOUT_CYCLES-1) begin
                    fault_code<=8'he3; state<=ACK_BLOCKED;
                end else ack_wait_cycles<=ack_wait_cycles+32'd1;
                PUBLISH: begin pending_latched<=0; state<=IDLE; end
                FAULT_NOTIFY: state<=FAULT_HOLD;
                FAULT_HOLD: if(fault_clear && owner_abort_seen && !fine_abort &&
                               !e_busy && !p_busy && !c_busy && !d_busy && !a_busy && !fine_rd_valid) state<=RECOVER;
                RECOVER: if(e_ready && p_ready && c_start_ready && d_ready && a_ready) begin
                    pending_latched<=0; fault_code<=0; state<=IDLE;
                end
                ACK_BLOCKED: state<=ACK_BLOCKED;
                default: begin fault_code<=8'he1; state<=FAULT_NOTIFY; end
            endcase
            if((e_fault || p_fault || c_fault || d_fault || a_fault) && state!=IDLE && state!=FAULT_NOTIFY &&
               state!=FAULT_HOLD && state!=RECOVER && state!=ACK_BLOCKED) begin
                fault_code<=e_fault ? e_fault_code : p_fault ? p_fault_code : c_fault ? c_fault_code :
                            d_fault ? d_fault_code : a_fault_code;
                pending_latched<=0; task_numeric_valid<=0; task_calibrated_valid<=0;
                task_theta_valid<=0; task_theta<=0;
                state<=FAULT_NOTIFY;
            end
            if(fine_abort && !maintenance_active && state!=IDLE && state!=FAULT_NOTIFY && state!=FAULT_HOLD &&
               state!=RECOVER && state!=ACK_BLOCKED) begin
                fault_code<=8'he4; pending_latched<=0; task_numeric_valid<=0;
                task_theta_valid<=0; task_theta<=0; state<=FAULT_HOLD;
            end
            // Synchronous maintenance cancellation; never gate resetn. Drain
            // children and their RAM responses before RECOVER/ready confirmation.
            if(maintenance_cancel) begin
                pending_latched<=0;task_theta_valid<=0;task_theta<=0;
                owner_abort_seen<=1;state<=FAULT_HOLD;
            end else if(maintenance_active && state==FAULT_HOLD &&
                        !e_busy && !p_busy && !c_busy && !d_busy && !a_busy &&
                        !fine_rd_req && !fine_rd_valid) state<=RECOVER;
        end
    end
endmodule
