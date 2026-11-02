`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// ADC-domain production candidate path, with an AXI-domain PS consumer bridge.
// Uses the existing FFT/result-bank system's one and only sample_timebase.
// FFT controller is never backpressured by this path. One candidate/window;
// busy FFT candidates are dropped and counted. PS must explicitly release
// the frozen copy using its candidate_seq tag; there is no auto-release.
//////////////////////////////////////////////////////////////////////////////////
module fft_candidate_chain #(
    // Legacy instantiations remain PS_DEBUG even with unconnected Fine pins.
    parameter integer ENABLE_PL_CONSUMER = 0,
    parameter integer PRODUCTION_CONTROL = 0
) (
    input  wire        adc_clk, adc_resetn, axi_clk, axi_resetn,
    input  wire        sample_tick,
    input  wire [47:0] sample_id, current_sample_id,
    input  wire        current_valid,
    input  wire [11:0] adc_ch0_data, adc_ch1_data,
    input  wire        frame_done, frame_abort, frame_error,
    input  wire [47:0] frame_start_sample_id,
    input  wire        fft_bram_en,
    input  wire [7:0]  fft_bram_we,
    input  wire [31:0] fft_bram_addr,
    input  wire [63:0] fft_bram_data,
    input  wire [31:0] ps_command_word, ps_payload_word,
    output wire [31:0] ps_status_word, ps_response_word,
    // All following interfaces are adc_clk (62.499374 MHz in production).
    input wire consumer_mode_valid, consumer_mode,
    output wire consumer_mode_ack, consumer_mode_granted, consumer_mode_active,
    output wire window_offer_valid,
    input wire window_offer_ready,
    output wire [31:0] window_offer_seq,
    output wire [479:0] window_offer_meta,
    input wire fine_rd_req,
    input wire [11:0] fine_rd_addr,
    output wire fine_rd_ready, fine_rd_valid,
    output wire [31:0] fine_rd_data,
    output wire [11:0] fine_rd_index,
    input wire fine_busy, fine_done, fine_fault, fine_result_latched,
    input wire [31:0] fine_seq,
    output wire fine_abort, fine_release_ack, fine_release_granted,
    output wire [31:0] fine_release_seq, consumer_protocol_error_count,
    // ADC synchronous production controller. Legacy defaults stay unchanged.
    input wire session_valid,
    input wire maintenance_hold_adc,maintenance_hold_axi,
    output wire maintenance_ready_adc,
    input wire [63:0] session_epoch,
    input wire [47:0] session_sample_floor,
    input wire external_cfg_committed, external_cfg_enable,
    input wire [8:0] external_bin_min, external_bin_max,
    input wire [31:0] external_ch0_min, external_ch1_min, external_publish_min,
    input wire external_release_valid, external_clear_valid,
    input wire [63:0] external_command_epoch,
    input wire [31:0] external_command_seq,
    output wire external_release_ack, external_release_granted,
    output wire external_clear_ack, external_clear_granted,
    output wire production_active, production_fault,
    output wire [31:0] production_fault_seq,
    output wire [31:0] production_busy_drop_count,
    output wire [223:0] production_fault_meta,
    output reg [63:0] window_offer_epoch
);
    wire cfg_committed, cfg_enable;
    wire hold_adc=PRODUCTION_CONTROL && maintenance_hold_adc;
    reg hold_seen_adc;
    wire maintenance_cancel=hold_adc && !hold_seen_adc;
    always @(posedge adc_clk) begin
        if(!adc_resetn) hold_seen_adc<=0;
        else hold_seen_adc<=hold_adc;
    end
    wire ps_drain_ready;
    wire [8:0] cfg_bin_min, cfg_bin_max;
    wire [31:0] cfg_ch0_min, cfg_ch1_min, cfg_publish_min;
    wire legacy_committed, legacy_enable;
    wire [8:0] legacy_bin_min, legacy_bin_max;
    wire [31:0] legacy_ch0_min, legacy_ch1_min, legacy_publish_min;
    assign cfg_committed = PRODUCTION_CONTROL ? external_cfg_committed : legacy_committed;
    assign cfg_enable = PRODUCTION_CONTROL ? (external_cfg_enable && session_valid && !hold_adc) : legacy_enable;
    assign cfg_bin_min = PRODUCTION_CONTROL ? external_bin_min : legacy_bin_min;
    assign cfg_bin_max = PRODUCTION_CONTROL ? external_bin_max : legacy_bin_max;
    assign cfg_ch0_min = PRODUCTION_CONTROL ? external_ch0_min : legacy_ch0_min;
    assign cfg_ch1_min = PRODUCTION_CONTROL ? external_ch1_min : legacy_ch1_min;
    assign cfg_publish_min = PRODUCTION_CONTROL ? external_publish_min : legacy_publish_min;
    wire detect_valid;
    wire [31:0] detect_seq, detect_frame_seq;
    wire [47:0] detect_frame_start, detect_event_id;
    wire [8:0] detect_bin;
    wire [31:0] detect_pwr0, detect_pwr1, detect_score;
    wire [7:0] detect_flags;
    wire [63:0] detect_epoch;
    fft_strongest_valid_detector #(.SESSION_AWARE(PRODUCTION_CONTROL)) u_detector (
        .adc_clk(adc_clk), .adc_resetn(adc_resetn),
        .session_valid(session_valid), .session_epoch(session_epoch), .candidate_epoch(detect_epoch),
        .session_sample_floor(session_sample_floor),
        .frame_done(frame_done), .frame_abort(frame_abort),
        .frame_error(frame_error),
        .frame_start_sample_id(frame_start_sample_id),
        .fft_bram_en(fft_bram_en), .fft_bram_we(fft_bram_we),
        .fft_bram_addr(fft_bram_addr), .fft_bram_data(fft_bram_data),
        .cfg_committed(cfg_committed), .cfg_enable(cfg_enable),
        .cfg_bin_min(cfg_bin_min), .cfg_bin_max(cfg_bin_max),
        .cfg_ch0_min_power(cfg_ch0_min),
        .cfg_ch1_min_power(cfg_ch1_min),
        .cfg_publish_min_power(cfg_publish_min),
        .candidate_valid(detect_valid), .candidate_seq(detect_seq),
        .candidate_frame_seq(detect_frame_seq),
        .candidate_frame_start_id(detect_frame_start),
        .candidate_event_id(detect_event_id),
        .candidate_bin(detect_bin),
        .candidate_pwr_ch0(detect_pwr0),
        .candidate_pwr_ch1(detect_pwr1),
        .candidate_score(detect_score), .candidate_flags(detect_flags),
        .invalid_frame_count(), .no_target_frame_count()
    );

    wire [15:0] ring_entries;
    wire ring_req, ring_valid, ring_expired, ring_collision;
    wire ring_not_ready, ring_invalid;
    wire [47:0] ring_req_id, ring_return_id;
    wire [31:0] ring_data;
    sample_ring_buffer #(.ADDR_BITS(15)) u_ring (
        .adc_clk(adc_clk), .adc_resetn(adc_resetn),
        .sample_tick(sample_tick), .sample_id(sample_id),
        .adc_ch0(adc_ch0_data), .adc_ch1(adc_ch1_data),
        .valid_entries(ring_entries), .rd_req(ring_req),
        .rd_sample_id(ring_req_id), .rd_valid(ring_valid),
        .rd_return_id(ring_return_id), .rd_data(ring_data),
        .rd_expired(ring_expired), .rd_collision(ring_collision),
        .rd_not_ready(ring_not_ready), .rd_invalid(ring_invalid)
    );

    wire copy_start, copy_cancel, copy_release, copy_busy, copy_done, copy_abort;
    wire [2:0] copy_abort_reason;
    wire [31:0] copy_progress;
    wire copy_valid;
    wire [47:0] copy_first_id;
    wire window_rd_req_axi, window_rd_valid_axi;
    wire [11:0] window_rd_addr_axi;
    wire [31:0] window_rd_data_axi;
    sample_window_copy #(.RING_ADDR_BITS(15), .WINDOW_BITS(12),
                         .USE_AXI_READ(1)) u_copy (
        .adc_clk(adc_clk), .adc_resetn(adc_resetn),
        .sample_tick(sample_tick), .next_sample_id(sample_id),
        .current_sample_id(current_sample_id),
        .current_valid(current_valid), .ring_valid_entries(ring_entries),
        .copy_start(copy_start && !hold_adc), .cancel_copy(copy_cancel || maintenance_cancel),
        .copy_first_sample_id(copy_first_id),
        .release_candidate(copy_release), .copy_busy(copy_busy),
        .copy_done(copy_done), .copy_abort(copy_abort),
        .candidate_valid(copy_valid), .candidate_first_sample_id(),
        .abort_reason(copy_abort_reason), .copy_progress(copy_progress),
        .abort_count(), .no_history_count(),
        .future_count(), .expired_count(), .collision_count(),
        .not_ready_count(), .protocol_count(),
        .ring_rd_req(ring_req), .ring_rd_sample_id(ring_req_id),
        .ring_rd_valid(ring_valid), .ring_rd_return_id(ring_return_id),
        .ring_rd_data(ring_data), .ring_rd_expired(ring_expired),
        .ring_rd_collision(ring_collision),
        .ring_rd_not_ready(ring_not_ready),
        .ring_rd_invalid(ring_invalid),
        .window_rd_req((ENABLE_PL_CONSUMER != 0) && !hold_adc && fine_rd_req && fine_rd_ready),
        .window_rd_addr(fine_rd_addr),
        .window_rd_valid(fine_rd_valid), .window_rd_data(fine_rd_data),
        .window_rd_index(fine_rd_index),
        .axi_clk(axi_clk), .axi_window_rd_req(window_rd_req_axi),
        .axi_window_rd_addr(window_rd_addr_axi),
        .axi_window_rd_valid(window_rd_valid_axi),
        .axi_window_rd_data(window_rd_data_axi)
    );

    wire manager_active, window_ready, fault;
    wire release_valid, release_ack, release_granted;
    wire [31:0] release_seq;
    wire legacy_release_valid, legacy_clear_valid;
    wire [31:0] legacy_release_seq, legacy_clear_seq;
    wire manager_release_valid, manager_release_ack, manager_release_granted;
    wire [31:0] manager_release_seq;
    wire retire_req, retire_ack, consumer_fault_valid, consumer_idle;
    assign maintenance_ready_adc=!manager_active && !copy_busy && consumer_idle &&
                                  !fine_rd_req && !fine_rd_valid && ps_drain_ready;
    wire [31:0] held_seq, consumer_fault_seq;
    wire clear_fault_valid, clear_fault_ack, clear_fault_granted;
    wire [31:0] clear_fault_seq;
    wire [31:0] fault_seq, fault_progress, last_drop_seq;
    wire [47:0] fault_sample_id;
    wire [7:0] fault_code, last_drop_reason;
    wire [31:0] drop_pre_count, protocol_error_count;
    wire [31:0] active_seq, active_frame_seq, active_pwr0,
                active_pwr1, active_score;
    wire [47:0] active_frame_start, active_event, active_first,
                copy_done_id;
    wire [8:0] active_bin;
    wire [7:0] active_flags;
    wire [31:0] accepted_count, busy_count, deadline_count, history_count;
    reg [63:0] fault_epoch;
    always @(posedge adc_clk) begin
        if (!adc_resetn) begin window_offer_epoch <= 0; fault_epoch <= 0; end
        else begin
            // The descriptor's epoch originates in detector, never at result publication.
            if (detect_valid && !manager_active && !copy_busy) window_offer_epoch <= detect_epoch;
            if (manager_active && !fault) fault_epoch <= window_offer_epoch;
        end
    end
    assign production_active = manager_active;
    assign production_fault = fault;
    assign production_fault_seq = fault_seq;
    assign production_busy_drop_count = busy_count;
    assign production_fault_meta = {fault_epoch, fault_progress,
        {16'd0,fault_sample_id[47:32]},fault_sample_id[31:0],{24'd0,fault_code},fault_seq};
    // No seq-only bypass survives in the production specialization. Matching
    // the epoch here is sufficient: session replacement resets/drains the
    // entire candidate owner before installing a new epoch.
    assign release_valid = PRODUCTION_CONTROL ?
        (external_release_valid && session_valid && external_command_epoch == window_offer_epoch) : legacy_release_valid;
    assign release_seq = PRODUCTION_CONTROL ? external_command_seq : legacy_release_seq;
    assign clear_fault_valid = PRODUCTION_CONTROL ?
        (external_clear_valid && session_valid && external_command_epoch == fault_epoch) : legacy_clear_valid;
    assign clear_fault_seq = PRODUCTION_CONTROL ? external_command_seq : legacy_clear_seq;
    assign external_release_ack = release_ack;
    assign external_release_granted = release_granted;
    assign external_clear_ack = clear_fault_ack;
    assign external_clear_granted = clear_fault_granted;
    assign window_offer_seq = active_seq;
    // Same immutable descriptor layout as PS metadata words 0..14 (ABI v1).
    assign window_offer_meta = {32'h0001_0000, {16'd0,copy_done_id[47:32]},
        copy_done_id[31:0], active_score, active_pwr1, active_pwr0,
        {15'd0,active_flags,active_bin}, {16'd0,active_first[47:32]},
        active_first[31:0], {16'd0,active_event[47:32]},active_event[31:0],
        {16'd0,active_frame_start[47:32]},active_frame_start[31:0],
        active_frame_seq,active_seq};
    candidate_window_consumer #(.ENABLE_MAINTENANCE(PRODUCTION_CONTROL)) u_consumer (
        .adc_clk(adc_clk), .adc_resetn(adc_resetn),
        .maintenance_clear(maintenance_cancel),
        .manager_active(manager_active), .copy_busy(copy_busy),
        .candidate_arriving(detect_valid), .window_ready(window_ready),
        .active_seq(active_seq),
        .consumer_mode_valid((ENABLE_PL_CONSUMER != 0) && consumer_mode_valid),
        .consumer_mode(consumer_mode), .consumer_mode_ack(consumer_mode_ack),
        .consumer_mode_granted(consumer_mode_granted),
        .consumer_mode_active(consumer_mode_active),
        .window_offer_valid(window_offer_valid),
        .window_offer_ready((ENABLE_PL_CONSUMER != 0) && window_offer_ready),
        .held_seq(held_seq), .fine_rd_ready(fine_rd_ready),
        .fine_rd_req((ENABLE_PL_CONSUMER != 0) && fine_rd_req),
        .fine_rd_valid(fine_rd_valid),
        .fine_busy((ENABLE_PL_CONSUMER != 0) && fine_busy),
        .fine_done((ENABLE_PL_CONSUMER != 0) && fine_done),
        .fine_fault((ENABLE_PL_CONSUMER != 0) && fine_fault),
        .fine_result_latched(fine_result_latched), .fine_seq(fine_seq),
        .fine_abort(fine_abort),
        .ps_release_valid(release_valid), .ps_release_seq(release_seq),
        .manager_release_valid(manager_release_valid),
        .manager_release_seq(manager_release_seq),
        .manager_release_ack(manager_release_ack),
        .manager_release_granted(manager_release_granted),
        .ps_release_ack(release_ack), .ps_release_granted(release_granted),
        .fine_release_ack(fine_release_ack),
        .fine_release_granted(fine_release_granted),
        .fine_release_seq(fine_release_seq),
        .retire_req(retire_req), .retire_ack(retire_ack),
        .consumer_fault_valid(consumer_fault_valid),
        .consumer_fault_seq(consumer_fault_seq),
        .consumer_idle(consumer_idle),
        .protocol_error_count(consumer_protocol_error_count)
    );
    single_candidate_manager #(.RING_ADDR_BITS(15), .WINDOW_BITS(12),
        .ENABLE_CONSUMER_FAULT(ENABLE_PL_CONSUMER),.ENABLE_MAINTENANCE(PRODUCTION_CONTROL))
        u_manager (
        .adc_clk(adc_clk), .adc_resetn(adc_resetn),
        .maintenance_clear(maintenance_cancel),
        .current_sample_id(current_sample_id),
        .current_valid(current_valid), .ring_valid_entries(ring_entries),
        .candidate_valid(detect_valid && !hold_adc), .candidate_seq(detect_seq),
        .candidate_frame_seq(detect_frame_seq),
        .candidate_frame_start_id(detect_frame_start),
        .candidate_event_id(detect_event_id),
        .candidate_coarse_bin(detect_bin),
        .candidate_pwr_ch0(detect_pwr0),
        .candidate_pwr_ch1(detect_pwr1),
        .candidate_power(detect_score), .candidate_flags(detect_flags),
        .copy_busy(copy_busy), .copy_done(copy_done),
        .copy_abort(copy_abort), .copy_candidate_valid(copy_valid),
        .copy_abort_reason(copy_abort_reason),
        .copy_progress(copy_progress),
        .consumer_fault_valid(consumer_fault_valid),
        .consumer_fault_seq(consumer_fault_seq),
        .release_valid(manager_release_valid), .release_seq(manager_release_seq),
        .release_ack(manager_release_ack), .release_granted(manager_release_granted),
        .clear_fault_valid(clear_fault_valid),
        .clear_fault_seq(clear_fault_seq),
        .clear_fault_ack(clear_fault_ack),
        .clear_fault_granted(clear_fault_granted),
        .copy_start(copy_start), .copy_first_sample_id(copy_first_id),
        .copy_cancel(copy_cancel),
        .copy_release(copy_release), .active(manager_active),
        .window_ready(window_ready), .fault_latched(fault),
        .fault_seq(fault_seq), .fault_code(fault_code),
        .fault_sample_id(fault_sample_id),
        .fault_copy_progress(fault_progress),
        .last_drop_seq(last_drop_seq),
        .last_drop_reason(last_drop_reason),
        .drop_pre_admission_count(drop_pre_count),
        .protocol_error_count(protocol_error_count),
        .active_candidate_seq(active_seq),
        .active_frame_seq(active_frame_seq),
        .active_frame_start_id(active_frame_start),
        .active_event_id(active_event), .active_first_id(active_first),
        .copy_done_sample_id(copy_done_id),
        .active_coarse_bin(active_bin),
        .active_pwr_ch0(active_pwr0), .active_pwr_ch1(active_pwr1),
        .active_power(active_score), .active_flags(active_flags),
        .accepted_count(accepted_count), .admitted_count(),
        .busy_drop_count(busy_count),
        .deadline_drop_count(deadline_count),
        .history_drop_count(history_count), .copy_abort_count(),
        .timeout_count(), .budget_violation_count(),
        .max_occupancy_cycles()
    );

    candidate_gpio_bridge #(.ENABLE_RETIRE(ENABLE_PL_CONSUMER),.ENABLE_MAINTENANCE(PRODUCTION_CONTROL)) u_ps_bridge (
        .adc_clk(adc_clk), .adc_resetn(adc_resetn),
        .axi_clk(axi_clk), .axi_resetn(axi_resetn),
        .maintenance_hold_adc(hold_adc),.maintenance_hold_axi(maintenance_hold_axi),
        .maintenance_ready_adc(ps_drain_ready),
        .command_word(ps_command_word), .payload_word(ps_payload_word),
        .status_word(ps_status_word), .response_word(ps_response_word),
        .cfg_committed_adc(legacy_committed), .cfg_enable_adc(legacy_enable),
        .cfg_bin_min_adc(legacy_bin_min), .cfg_bin_max_adc(legacy_bin_max),
        .cfg_ch0_min_adc(legacy_ch0_min), .cfg_ch1_min_adc(legacy_ch1_min),
        .cfg_publish_min_adc(legacy_publish_min),
        .window_ready_adc(window_ready), .active_adc(manager_active),
        .retire_req_adc(retire_req), .retire_ack_adc(retire_ack),
        .fault_adc(fault),
        .fault_seq_adc(fault_seq), .fault_code_adc(fault_code),
        .fault_sample_id_adc(fault_sample_id),
        .fault_copy_progress_adc(fault_progress),
        .last_drop_seq_adc(last_drop_seq),
        .last_drop_reason_adc(last_drop_reason),
        .count_drop_pre_adc(drop_pre_count),
        .count_drop_deadline_adc(deadline_count),
        .count_drop_history_adc(history_count),
        .count_protocol_error_adc(protocol_error_count),
        .meta_candidate_seq_adc(active_seq),
        .meta_frame_seq_adc(active_frame_seq),
        .meta_frame_start_adc(active_frame_start),
        .meta_event_id_adc(active_event),
        .meta_window_start_adc(active_first),
        .meta_bin_adc(active_bin),
        .meta_pwr_ch0_adc(active_pwr0),
        .meta_pwr_ch1_adc(active_pwr1),
        .meta_score_adc(active_score),
        .meta_copy_done_id_adc(copy_done_id),
        .meta_flags_adc(active_flags),
        .count_candidate_adc(detect_seq),
        .count_accepted_adc(accepted_count),
        .count_busy_adc(busy_count),
        .release_valid_adc(legacy_release_valid),
        .release_seq_adc(legacy_release_seq),
        .release_ack_adc(PRODUCTION_CONTROL ? legacy_release_valid : release_ack),
        .release_granted_adc(PRODUCTION_CONTROL ? 1'b0 : release_granted),
        .clear_fault_valid_adc(legacy_clear_valid),
        .clear_fault_seq_adc(legacy_clear_seq),
        .clear_fault_ack_adc(PRODUCTION_CONTROL ? legacy_clear_valid : clear_fault_ack),
        .clear_fault_granted_adc(PRODUCTION_CONTROL ? 1'b0 : clear_fault_granted),
        .window_rd_req_axi(window_rd_req_axi),
        .window_rd_addr_axi(window_rd_addr_axi),
        .window_rd_valid_axi(window_rd_valid_axi),
        .window_rd_data_axi(window_rd_data_axi)
    );
endmodule
