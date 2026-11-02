`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// One candidate at most per completed dual-channel FFT frame (adc_clk only).
// Observes the *actual* 64-bit result-BRAM write stream from spectrum_fft_ctrl.
// Address 0..511 is CH0; 512..1023 is CH1. Addresses are byte addresses.
// Power units: sat32((signed(Re)^2 + signed(Im)^2) >> 16).
// Tie break: lowest bin. Bin zero and the absent Nyquist bin 512 are invalid.
// Configuration is latched at the first CH0 bin of each frame, and must have
// been transferred atomically into adc_clk by the consumer bridge.
// No noise estimator, cross-frame voting, queue, or hidden default threshold.
//////////////////////////////////////////////////////////////////////////////////
module fft_strongest_valid_detector #(
    parameter integer SESSION_AWARE = 0
) (
    input  wire        adc_clk,
    input  wire        adc_resetn,
    input  wire        session_valid,
    input  wire [63:0] session_epoch,
    input  wire [47:0] session_sample_floor,
    output reg [63:0] candidate_epoch,
    input  wire        frame_done,
    input  wire        frame_abort,
    input  wire        frame_error,
    input  wire [47:0] frame_start_sample_id,
    input  wire        fft_bram_en,
    input  wire [7:0]  fft_bram_we,
    input  wire [31:0] fft_bram_addr,
    input  wire [63:0] fft_bram_data,
    input  wire        cfg_committed,
    input  wire        cfg_enable,
    input  wire [8:0]  cfg_bin_min,
    input  wire [8:0]  cfg_bin_max,
    input  wire [31:0] cfg_ch0_min_power,
    input  wire [31:0] cfg_ch1_min_power,
    input  wire [31:0] cfg_publish_min_power,
    output reg         candidate_valid,
    output reg  [31:0] candidate_seq,
    output reg  [31:0] candidate_frame_seq,
    output reg  [47:0] candidate_frame_start_id,
    output reg  [47:0] candidate_event_id,
    output reg  [8:0]  candidate_bin,
    output reg  [31:0] candidate_pwr_ch0,
    output reg  [31:0] candidate_pwr_ch1,
    output reg  [31:0] candidate_score,
    output reg  [7:0]  candidate_flags,
    output reg  [31:0] invalid_frame_count,
    output reg  [31:0] no_target_frame_count
);
    // A valid write is always an aligned 64-bit full-word FFT result.
    wire raw_valid = fft_bram_en && (fft_bram_we == 8'hff) &&
                     (fft_bram_addr[2:0] == 3'b000) &&
                     (fft_bram_addr[31:13] == 19'd0);
    wire raw_channel = fft_bram_addr[12];
    wire [8:0] raw_bin = fft_bram_addr[11:3];
    reg p0_valid, p0_channel;
    reg [8:0] p0_bin;
    reg signed [31:0] p0_re, p0_im;
    wire signed [63:0] re_square = p0_re * p0_re;
    wire signed [63:0] im_square = p0_im * p0_im;
    wire [64:0] power_full = {1'b0, re_square} + {1'b0, im_square};
    wire power_overflow = |power_full[64:48];
    wire [31:0] power_scaled = power_overflow ? 32'hffff_ffff :
                                                  power_full[47:16];
    reg p1_valid, p1_channel, p1_sat;
    reg [8:0] p1_bin;
    reg [31:0] p1_power;

    (* ram_style = "block" *) reg [32:0] ch0_power [0:511];
    reg [511:0] ch0_seen;
    reg [32:0] ch0_read;
    reg ch0_read_seen, compare_valid;
    reg [8:0] compare_bin;
    reg [31:0] compare_pwr1;
    reg compare_sat1;

    reg active_enable;
    reg [8:0] active_bin_min, active_bin_max;
    reg [31:0] active_ch0_min, active_ch1_min, active_publish_min;
    reg best_valid, best_sat;
    reg [8:0] best_bin;
    reg [31:0] best_pwr0, best_pwr1, best_score;
    wire [32:0] score_wide = {1'b0, ch0_read[31:0]} +
                             {1'b0, compare_pwr1};
    wire [31:0] score = score_wide[32] ? 32'hffff_ffff : score_wide[31:0];
    wire eligible = compare_valid && ch0_read_seen && active_enable &&
                    (active_bin_min <= active_bin_max) &&
                    (compare_bin != 9'd0) &&
                    (compare_bin >= active_bin_min) &&
                    (compare_bin <= active_bin_max) &&
                    (ch0_read[31:0] >= active_ch0_min) &&
                    (compare_pwr1 >= active_ch1_min);
    reg [2:0] flush_count;
    reg pending_error;
    reg frame_open;
    reg [31:0] frame_seq;
    reg [31:0] pending_frame_seq;
    reg [47:0] pending_frame_start;
    reg [63:0] frame_epoch;
    wire [47:0] frame_session_age = pending_frame_start - session_sample_floor;

    function [31:0] sat_inc;
        input [31:0] value;
        begin sat_inc = (&value) ? value : value + 1'b1; end
    endfunction

    always @(posedge adc_clk) begin
        if (!adc_resetn) begin
            p0_valid <= 1'b0;
            p0_channel <= 1'b0;
            p0_bin <= 9'd0;
            p0_re <= 32'sd0;
            p0_im <= 32'sd0;
            p1_valid <= 1'b0;
            p1_channel <= 1'b0;
            p1_bin <= 9'd0;
            p1_power <= 32'd0;
            p1_sat <= 1'b0;
            ch0_seen <= 512'd0;
            ch0_read <= 33'd0;
            ch0_read_seen <= 1'b0;
            compare_valid <= 1'b0;
            compare_bin <= 9'd0;
            compare_pwr1 <= 32'd0;
            compare_sat1 <= 1'b0;
            active_enable <= 1'b0;
            active_bin_min <= 9'd0;
            active_bin_max <= 9'd0;
            active_ch0_min <= 32'd0;
            active_ch1_min <= 32'd0;
            active_publish_min <= 32'd0;
            best_valid <= 1'b0;
            best_sat <= 1'b0;
            best_bin <= 9'd0;
            best_pwr0 <= 32'd0;
            best_pwr1 <= 32'd0;
            best_score <= 32'd0;
            flush_count <= 3'd0;
            pending_error <= 1'b0;
            frame_open <= 1'b0;
            frame_seq <= 32'd0;
            pending_frame_seq <= 32'd0;
            pending_frame_start <= 48'd0;
            candidate_valid <= 1'b0;
            candidate_epoch <= 0;
            frame_epoch <= 0;
            candidate_seq <= 32'd0;
            candidate_frame_seq <= 32'd0;
            candidate_frame_start_id <= 48'd0;
            candidate_event_id <= 48'd0;
            candidate_bin <= 9'd0;
            candidate_pwr_ch0 <= 32'd0;
            candidate_pwr_ch1 <= 32'd0;
            candidate_score <= 32'd0;
            candidate_flags <= 8'd0;
            invalid_frame_count <= 32'd0;
            no_target_frame_count <= 32'd0;
        end else begin
            candidate_valid <= 1'b0;
            p0_valid <= raw_valid;
            if (raw_valid) begin
                p0_channel <= raw_channel;
                p0_bin <= raw_bin;
                p0_re <= fft_bram_data[31:0];
                p0_im <= fft_bram_data[63:32];
                // New frame starts with its first CH0 bin; the preceding
                // frame has already finished the four-cycle drain.
                if (!raw_channel && raw_bin == 9'd0) begin
                    frame_open <= 1'b1;
                    ch0_seen <= 512'd0;
                    best_valid <= 1'b0;
                    best_score <= 32'd0;
                    active_enable <= cfg_committed && cfg_enable &&
                        ((SESSION_AWARE == 0) ||
                         (session_valid && session_epoch != 0 && candidate_seq != 32'hffffffff));
                    frame_epoch <= session_epoch;
                    active_bin_min <= cfg_bin_min;
                    active_bin_max <= cfg_bin_max;
                    active_ch0_min <= cfg_ch0_min_power;
                    active_ch1_min <= cfg_ch1_min_power;
                    active_publish_min <= cfg_publish_min_power;
                end
            end
            p1_valid <= p0_valid;
            if (p0_valid) begin
                p1_channel <= p0_channel;
                p1_bin <= p0_bin;
                p1_power <= power_scaled;
                p1_sat <= power_overflow;
            end
            compare_valid <= p1_valid && p1_channel;
            if (p1_valid) begin
                if (!p1_channel) begin
                    ch0_power[p1_bin] <= {p1_sat, p1_power};
                    ch0_seen[p1_bin] <= 1'b1;
                end else begin
                    ch0_read <= ch0_power[p1_bin];
                    ch0_read_seen <= ch0_seen[p1_bin];
                    compare_bin <= p1_bin;
                    compare_pwr1 <= p1_power;
                    compare_sat1 <= p1_sat;
                end
            end
            if (eligible && (!best_valid || score > best_score)) begin
                best_valid <= 1'b1;
                best_bin <= compare_bin;
                best_pwr0 <= ch0_read[31:0];
                best_pwr1 <= compare_pwr1;
                best_score <= score;
                best_sat <= ch0_read[32] || compare_sat1 || score_wide[32];
            end
            if (frame_abort) begin
                // No candidate can be emitted from an incomplete frame.
                flush_count <= 3'd0;
                frame_open <= 1'b0;
                best_valid <= 1'b0;
                ch0_seen <= 512'd0;
                invalid_frame_count <= sat_inc(invalid_frame_count);
            end else if (frame_done) begin
                flush_count <= 3'd4;
                pending_error <= frame_error || !frame_open;
                frame_open <= 1'b0;
                pending_frame_start <= frame_start_sample_id;
                pending_frame_seq <= sat_inc(frame_seq);
                frame_seq <= sat_inc(frame_seq);
            end else if (flush_count != 3'd0) begin
                flush_count <= flush_count - 1'b1;
                if (flush_count == 3'd1) begin
                    if (pending_error) begin
                        invalid_frame_count <= sat_inc(invalid_frame_count);
                    end else if (best_valid && active_enable &&
                                 best_score >= active_publish_min &&
                                 ((SESSION_AWARE == 0) ||
                                  (session_valid && frame_epoch == session_epoch && !frame_session_age[47] &&
                                   candidate_seq != 32'hffffffff))) begin
                        candidate_valid <= 1'b1;
                        candidate_epoch <= frame_epoch;
                        // A sequence tag must not saturate: otherwise two
                        // different windows eventually share the same tag.
                        candidate_seq <= candidate_seq + 1'b1;
                        candidate_frame_seq <= pending_frame_seq;
                        candidate_frame_start_id <= pending_frame_start;
                        candidate_event_id <= pending_frame_start + 48'd512;
                        candidate_bin <= best_bin;
                        candidate_pwr_ch0 <= best_pwr0;
                        candidate_pwr_ch1 <= best_pwr1;
                        candidate_score <= best_score;
                        candidate_flags <= {7'd0, best_sat};
                    end else begin
                        no_target_frame_count <= sat_inc(no_target_frame_count);
                    end
                end
            end
        end
    end
endmodule
