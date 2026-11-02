`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// single_candidate_manager - one ADC-domain candidate, no waiting queue
//
// A descriptor is accepted only in IDLE. Every descriptor presented while
// active (including a frozen window awaiting fine/PS release) is dropped and
// counted. Ring/FFT must share the same 48-bit sample_timebase.
//
// The twofold retention target is an ADMISSION rule, not an assertion that
// every FFT result arrives in time. A late candidate is dropped before Copy.
// With R=32768, W=4096, one collision guard and one ADC sample per clock:
//   budget = floor((R-W-1)/2) = 14335 sample clocks.
//   Copy reserve = W+3 = 4099 clocks (launch, pipeline, response observation).
// Actual completion is checked again against the absolute ready ID. A Copy
// timeout or post-admission fault leaves the manager in FAULT until a tagged
// CLEAR_FAULT; no
// partial/stale window can be advertised as ready.
//
// All interfaces are adc_clk. The separate candidate_gpio_bridge implements
// PS CDC and tagged RELEASE/CLEAR_FAULT acknowledgments.
//////////////////////////////////////////////////////////////////////////////////
module single_candidate_manager #(
    parameter integer RING_ADDR_BITS = 15,
    parameter integer WINDOW_BITS = 12,
    parameter integer ENABLE_CONSUMER_FAULT = 0,
    parameter integer ENABLE_MAINTENANCE = 0
) (
    input  wire                         adc_clk,
    input  wire                         adc_resetn,
    input  wire                         maintenance_clear,
    input  wire [47:0]                  current_sample_id,
    input  wire                         current_valid,
    input  wire [RING_ADDR_BITS:0]      ring_valid_entries,

    input  wire                         candidate_valid, // one-cycle pulse
    input  wire [31:0]                  candidate_seq,
    input  wire [31:0]                  candidate_frame_seq,
    input  wire [47:0]                  candidate_frame_start_id,
    input  wire [47:0]                  candidate_event_id,
    input  wire [8:0]                   candidate_coarse_bin,
    input  wire [31:0]                  candidate_pwr_ch0,
    input  wire [31:0]                  candidate_pwr_ch1,
    input  wire [31:0]                  candidate_power,
    input  wire [7:0]                   candidate_flags,

    input  wire                         copy_busy,
    input  wire                         copy_done,
    input  wire                         copy_abort,
    input  wire                         copy_candidate_valid,
    input  wire [2:0]                   copy_abort_reason,
    input  wire [31:0]                  copy_progress,
    input  wire                         consumer_fault_valid,
    input  wire [31:0]                  consumer_fault_seq,
    input  wire                         release_valid,
    input  wire [31:0]                  release_seq,
    output reg                          release_ack,
    output reg                          release_granted,
    input  wire                         clear_fault_valid,
    input  wire [31:0]                  clear_fault_seq,
    output reg                          clear_fault_ack,
    output reg                          clear_fault_granted,
    output wire                         copy_start,
    output wire                         copy_cancel,
    output wire [47:0]                  copy_first_sample_id,
    output wire                         copy_release,
    output wire                         active,
    output wire                         window_ready,
    output wire                         fault_latched,
    output reg  [31:0]                  fault_seq,
    output reg  [7:0]                   fault_code,
    output reg  [47:0]                  fault_sample_id,
    output reg  [31:0]                  fault_copy_progress,
    output reg  [31:0]                  last_drop_seq,
    output reg  [7:0]                   last_drop_reason,
    output reg  [31:0]                  drop_pre_admission_count,
    output reg  [31:0]                  protocol_error_count,

    output reg  [31:0]                  active_candidate_seq,
    output reg  [31:0]                  active_frame_seq,
    output reg  [47:0]                  active_frame_start_id,
    output reg  [47:0]                  active_event_id,
    output reg  [47:0]                  active_first_id,
    output reg  [47:0]                  copy_done_sample_id,
    output reg  [8:0]                   active_coarse_bin,
    output reg  [31:0]                  active_pwr_ch0,
    output reg  [31:0]                  active_pwr_ch1,
    output reg  [31:0]                  active_power,
    output reg  [7:0]                   active_flags,
    output reg  [31:0]                  accepted_count,
    output reg  [31:0]                  admitted_count,
    output reg  [31:0]                  busy_drop_count,
    output reg  [31:0]                  deadline_drop_count,
    output reg  [31:0]                  history_drop_count,
    output reg  [31:0]                  copy_abort_count,
    output reg  [31:0]                  timeout_count,
    output reg  [31:0]                  budget_violation_count,
    output reg  [31:0]                  max_occupancy_cycles
);
    localparam integer RING_DEPTH = (1 << RING_ADDR_BITS);
    localparam integer WINDOW_DEPTH = (1 << WINDOW_BITS);
    localparam integer HALF_WINDOW = WINDOW_DEPTH / 2;
    localparam integer BUDGET_CYCLES =
        (RING_DEPTH - WINDOW_DEPTH - 1) / 2;
    localparam integer COPY_RESERVE_CYCLES = WINDOW_DEPTH + 3;
    localparam integer LATEST_START_AGE =
        BUDGET_CYCLES - COPY_RESERVE_CYCLES;
    localparam [47:0] RING_DEPTH_48 = RING_DEPTH;
    localparam [47:0] BUDGET_48 = BUDGET_CYCLES;
    localparam [47:0] LATEST_START_48 = LATEST_START_AGE;

    localparam [2:0] ST_IDLE   = 3'd0;
    localparam [2:0] ST_POST   = 3'd1;
    localparam [2:0] ST_LAUNCH = 3'd2;
    localparam [2:0] ST_COPY   = 3'd3;
    localparam [2:0] ST_FROZEN = 3'd4;
    localparam [2:0] ST_DRAIN  = 3'd5;
    localparam [2:0] ST_FAULT  = 3'd6;

    reg [2:0] state;
    reg [47:0] active_ready_id;
    reg [31:0] copy_cycles;
    wire [47:0] candidate_age = current_sample_id - candidate_event_id;
    wire [47:0] ready_age = current_sample_id - active_ready_id;
    wire [47:0] oldest_age = current_sample_id - active_first_id;
    wire history_missing = oldest_age[47] ||
                           (oldest_age >= RING_DEPTH_48) ||
                           (oldest_age >= ring_valid_entries);

    assign copy_start = (state == ST_LAUNCH);
    assign copy_first_sample_id = active_first_id;
    wire release_match = (state == ST_FROZEN) &&
                         copy_candidate_valid && release_valid &&
                         (release_seq == active_candidate_seq);
    wire clear_match = (state == ST_FAULT) &&
                       clear_fault_valid &&
                       (clear_fault_seq == fault_seq) &&
                       !copy_busy && !copy_candidate_valid;
    wire copy_bad_done = copy_done &&
                         (!copy_candidate_valid || ready_age[47] ||
                          (ready_age > BUDGET_48));
    wire copy_timed_out = !copy_done &&
                          (!copy_busy || (copy_cycles >= COPY_RESERVE_CYCLES));
    wire consumer_fault_match = (ENABLE_CONSUMER_FAULT != 0) &&
        (state == ST_FROZEN) && consumer_fault_valid &&
        (consumer_fault_seq == active_candidate_seq);
    assign copy_cancel = (state == ST_COPY) &&
                         (copy_bad_done || copy_timed_out) ||
                         consumer_fault_match ||
                         (state == 3'd7);
    assign copy_release = release_match;
    assign active = (state != ST_IDLE);
    assign window_ready = (state == ST_FROZEN) && copy_candidate_valid;
    assign fault_latched = (state == ST_FAULT);

    function [31:0] sat_inc;
        input [31:0] value;
        begin
            sat_inc = (value == 32'hffff_ffff) ? value : value + 1'b1;
        end
    endfunction

    always @(posedge adc_clk) begin
        if (!adc_resetn) begin
            state                  <= ST_IDLE;
            active_ready_id        <= 48'd0;
            active_candidate_seq   <= 32'd0;
            active_frame_seq       <= 32'd0;
            active_frame_start_id  <= 48'd0;
            active_event_id        <= 48'd0;
            active_first_id        <= 48'd0;
            copy_done_sample_id    <= 48'd0;
            active_coarse_bin      <= 9'd0;
            active_pwr_ch0         <= 32'd0;
            active_pwr_ch1         <= 32'd0;
            active_power           <= 32'd0;
            active_flags           <= 8'd0;
            copy_cycles            <= 32'd0;
            accepted_count         <= 32'd0;
            admitted_count         <= 32'd0;
            busy_drop_count        <= 32'd0;
            deadline_drop_count    <= 32'd0;
            history_drop_count     <= 32'd0;
            copy_abort_count       <= 32'd0;
            timeout_count          <= 32'd0;
            budget_violation_count <= 32'd0;
            max_occupancy_cycles   <= 32'd0;
            release_ack            <= 1'b0;
            release_granted        <= 1'b0;
            clear_fault_ack        <= 1'b0;
            clear_fault_granted    <= 1'b0;
            fault_seq              <= 32'd0;
            fault_code             <= 8'd0;
            fault_sample_id        <= 48'd0;
            fault_copy_progress    <= 32'd0;
            last_drop_seq          <= 32'd0;
            last_drop_reason       <= 8'd0;
            drop_pre_admission_count <= 32'd0;
            protocol_error_count   <= 32'd0;
        end else if(ENABLE_MAINTENANCE && maintenance_clear) begin
            // Ownership invalidation after the wrapper has fenced traffic.
            // KEEP diagnostic counters: STOP is not hardware reset.
            state<=ST_IDLE;copy_cycles<=0;
            release_ack<=0;release_granted<=0;clear_fault_ack<=0;clear_fault_granted<=0;
        end else begin
            release_ack <= release_valid;
            release_granted <= release_match;
            clear_fault_ack <= clear_fault_valid;
            clear_fault_granted <= clear_match;
            if ((release_valid && !release_match) ||
                (clear_fault_valid && !clear_match))
                protocol_error_count <= sat_inc(protocol_error_count);
            if (candidate_valid && ((state != ST_IDLE) || copy_busy))
                busy_drop_count <= sat_inc(busy_drop_count);

            case (state)
                ST_IDLE: if (candidate_valid && !copy_busy) begin
                    if (!current_valid || candidate_age[47]) begin
                        history_drop_count <= sat_inc(history_drop_count);
                        drop_pre_admission_count <=
                            sat_inc(drop_pre_admission_count);
                        last_drop_seq <= candidate_seq;
                        last_drop_reason <= 8'd1; // no/future history
                    end else begin
                        active_candidate_seq <= candidate_seq;
                        active_frame_seq  <= candidate_frame_seq;
                        active_frame_start_id <= candidate_frame_start_id;
                        active_event_id   <= candidate_event_id;
                        active_first_id   <= candidate_event_id - HALF_WINDOW;
                        active_ready_id   <= candidate_event_id + HALF_WINDOW - 1;
                        active_coarse_bin <= candidate_coarse_bin;
                        active_pwr_ch0    <= candidate_pwr_ch0;
                        active_pwr_ch1    <= candidate_pwr_ch1;
                        active_power      <= candidate_power;
                        active_flags      <= candidate_flags;
                        accepted_count    <= sat_inc(accepted_count);
                        state             <= ST_POST;
                    end
                end

                ST_POST: if (current_valid && !ready_age[47]) begin
                    if (history_missing) begin
                        history_drop_count <= sat_inc(history_drop_count);
                        drop_pre_admission_count <=
                            sat_inc(drop_pre_admission_count);
                        last_drop_seq <= active_candidate_seq;
                        last_drop_reason <= 8'd2; // history expired
                        state <= ST_IDLE;
                    end else if ((COPY_RESERVE_CYCLES > BUDGET_CYCLES) ||
                                 (ready_age > LATEST_START_48)) begin
                        deadline_drop_count <= sat_inc(deadline_drop_count);
                        drop_pre_admission_count <=
                            sat_inc(drop_pre_admission_count);
                        last_drop_seq <= active_candidate_seq;
                        last_drop_reason <= 8'd3; // admission deadline
                        state <= ST_IDLE;
                    end else if (!copy_busy) begin
                        admitted_count <= sat_inc(admitted_count);
                        state <= ST_LAUNCH;
                    end
                end

                ST_LAUNCH: begin
                    // Copy sees copy_start on this edge; it begins issuing
                    // Ring requests on following edges.
                    copy_cycles <= 32'd0;
                    state <= ST_COPY;
                end

                ST_COPY: begin
                    if (copy_abort) begin
                        copy_abort_count <= sat_inc(copy_abort_count);
                        fault_seq <= active_candidate_seq;
                        fault_code <= {5'b00010, copy_abort_reason};
                        fault_sample_id <= current_sample_id;
                        fault_copy_progress <= copy_progress;
                        state <= ST_DRAIN;
                    end else if (copy_done) begin
                        if (copy_bad_done) begin
                            budget_violation_count <=
                                sat_inc(budget_violation_count);
                            fault_seq <= active_candidate_seq;
                            fault_code <= 8'h30;
                            fault_sample_id <= current_sample_id;
                            fault_copy_progress <= copy_progress;
                            state <= ST_DRAIN;
                        end else begin
                            if ((ready_age[47:32] == 16'd0) &&
                                (ready_age[31:0] > max_occupancy_cycles))
                                max_occupancy_cycles <= ready_age[31:0];
                            copy_done_sample_id <= current_sample_id;
                            state <= ST_FROZEN;
                        end
                    end else if (copy_timed_out) begin
                        timeout_count <= sat_inc(timeout_count);
                        fault_seq <= active_candidate_seq;
                        fault_code <= 8'h20;
                        fault_sample_id <= current_sample_id;
                        fault_copy_progress <= copy_progress;
                        state <= ST_DRAIN;
                    end else begin
                        copy_cycles <= copy_cycles + 1'b1;
                    end
                end

                ST_FROZEN: if (consumer_fault_match) begin
                    fault_seq <= active_candidate_seq;
                    fault_code <= 8'h50; // PL consumer fault; Copy semantics unchanged
                    fault_sample_id <= current_sample_id;
                    fault_copy_progress <= copy_progress;
                    state <= ST_DRAIN;
                end else if (release_match) state <= ST_IDLE;

                ST_DRAIN: if (!copy_busy && !copy_candidate_valid)
                    state <= ST_FAULT;

                // The diagnostic snapshot stays immutable until the tagged
                // clear has crossed CDC and the Copy has completely drained.
                ST_FAULT: if (clear_match)
                    state <= ST_IDLE;
                default: begin
                    // An illegal encoding is an internal consistency fault.
                    // Abort any in-flight Copy before exposing the snapshot.
                    fault_seq <= active_candidate_seq;
                    fault_code <= 8'h40;
                    fault_sample_id <= current_sample_id;
                    fault_copy_progress <= copy_progress;
                    state <= ST_DRAIN;
                end
            endcase
        end
    end
endmodule
