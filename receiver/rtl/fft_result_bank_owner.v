`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// fft_result_bank_owner - ADC-domain ownership of two complete FFT result banks
//
// One bank is 1024 x 64 bits: CH0 bins 0..511, CH1 bins 512..1023. The
// incoming BRAM address is a byte address 0..8191; bit 13 selects the bank.
// No signal from this module backpressures the FFT. At frame_begin, a FREE
// bank is preferred. Otherwise an unclaimed READY bank may be replaced (the
// older READY bank first). WRITING, PUBLISH and READING are never overwritten.
// The drop counter counts both replaced READY results and frames for which no
// export bank can be reserved.
//
// This module is ADC-domain only. Claim/release pulses and metadata must cross
// the PS AXI clock boundary through an acknowledged protocol in integration.
//////////////////////////////////////////////////////////////////////////////////
module fft_result_bank_owner (
    input  wire        adc_clk,
    input  wire        adc_resetn,
    input  wire        frame_begin,
    input  wire        frame_done,
    input  wire        frame_abort,
    input  wire        frame_error,
    input  wire [47:0] frame_start_sample_id,
    input  wire [47:0] frame_end_sample_id,
    input  wire [1:0]  publish_ack, // metadata has reached the AXI domain

    input  wire        raw_bram_en,
    input  wire [7:0]  raw_bram_we,
    input  wire [31:0] raw_bram_addr,
    input  wire [63:0] raw_bram_data,
    output wire        banked_bram_en,
    output wire [7:0]  banked_bram_we,
    output wire [31:0] banked_bram_addr,
    output wire [63:0] banked_bram_data,

    input  wire        claim_req,
    input  wire        claim_bank,
    input  wire [15:0] claim_sequence,
    output reg         claim_ack,
    output reg         claim_granted,
    input  wire        release_req,
    input  wire        release_bank,
    input  wire [15:0] release_sequence,
    output reg         release_ack,
    output reg         release_granted,

    output reg  [1:0]  bank_ready,
    output reg  [1:0]  bank_claimed,
    output reg  [31:0] bank0_sequence,
    output reg  [31:0] bank1_sequence,
    output reg  [47:0] bank0_start_sample_id,
    output reg  [47:0] bank0_end_sample_id,
    output reg  [47:0] bank1_start_sample_id,
    output reg  [47:0] bank1_end_sample_id,
    output reg         published_pulse,
    output reg         published_bank,
    output reg  [31:0] result_export_drop_count,
    output reg  [31:0] result_abort_count
);
    localparam [2:0] FREE    = 3'd0;
    localparam [2:0] WRITING = 3'd1;
    localparam [2:0] PUBLISH = 3'd2;
    localparam [2:0] READY   = 3'd3;
    localparam [2:0] READING = 3'd4;

    reg [2:0] bank0_state;
    reg [2:0] bank1_state;
    reg       active_export;
    reg       active_bank;
    reg [31:0] active_sequence;
    reg [31:0] next_sequence;
    // A claim arriving on this very edge has priority over READY eviction.
    // A stale claim can still be rejected after a prior eviction; PS checks
    // the full sequence again after the owner acknowledges a successful claim.
    wire bank0_evictable = (bank0_state == READY) &&
        !(claim_req && !claim_bank &&
          bank0_sequence[15:0] == claim_sequence);
    wire bank1_evictable = (bank1_state == READY) &&
        !(claim_req && claim_bank &&
          bank1_sequence[15:0] == claim_sequence);

    // Register the decoded flags in the source clock domain. A one-cycle
    // advisory delay is safe: claim/release is checked against owner state,
    // while this avoids a LUT before the AXI-domain two-flop synchronizers.
    assign banked_bram_en = adc_resetn && active_export && raw_bram_en &&
                           (active_bank ? (bank1_state == WRITING) :
                                          (bank0_state == WRITING)) &&
                           (raw_bram_addr[31:13] == 19'd0);
    assign banked_bram_we   = banked_bram_en ? raw_bram_we : 8'd0;
    assign banked_bram_addr = {18'd0, active_bank, raw_bram_addr[12:0]};
    assign banked_bram_data = raw_bram_data;

    always @(posedge adc_clk) begin
        if (!adc_resetn) begin
            bank0_state              <= FREE;
            bank1_state              <= FREE;
            bank_ready               <= 2'b00;
            bank_claimed             <= 2'b00;
            active_export            <= 1'b0;
            active_bank              <= 1'b0;
            active_sequence          <= 32'd0;
            next_sequence            <= 32'd0;
            bank0_sequence           <= 32'd0;
            bank1_sequence           <= 32'd0;
            bank0_start_sample_id    <= 48'd0;
            bank0_end_sample_id      <= 48'd0;
            bank1_start_sample_id    <= 48'd0;
            bank1_end_sample_id      <= 48'd0;
            claim_ack                <= 1'b0;
            claim_granted            <= 1'b0;
            release_ack              <= 1'b0;
            release_granted          <= 1'b0;
            published_pulse          <= 1'b0;
            published_bank           <= 1'b0;
            result_export_drop_count <= 32'd0;
            result_abort_count       <= 32'd0;
        end else begin
            bank_ready   <= {bank1_state == READY, bank0_state == READY};
            bank_claimed <= {bank1_state == READING, bank0_state == READING};
            claim_ack       <= 1'b0;
            release_ack     <= 1'b0;
            published_pulse <= 1'b0;

            if (publish_ack[0] && bank0_state == PUBLISH)
                bank0_state <= READY;
            if (publish_ack[1] && bank1_state == PUBLISH)
                bank1_state <= READY;

            // Claim/release touch only READY/READING respectively. The active
            // WRITING bank is distinct, so an unrelated frame completion or
            // next-frame reservation must not reject a valid PS release.
            if (claim_req) begin
                claim_ack <= 1'b1;
                claim_granted <= 1'b0;
                if (!claim_bank && bank0_state == READY &&
                    bank0_sequence[15:0] == claim_sequence) begin
                    bank0_state   <= READING;
                    claim_granted <= 1'b1;
                end else if (claim_bank && bank1_state == READY &&
                             bank1_sequence[15:0] == claim_sequence) begin
                    bank1_state   <= READING;
                    claim_granted <= 1'b1;
                end
            end
            if (release_req) begin
                release_ack <= 1'b1;
                release_granted <= 1'b0;
                if (!release_bank && bank0_state == READING &&
                    bank0_sequence[15:0] == release_sequence) begin
                    bank0_state     <= FREE;
                    release_granted <= 1'b1;
                end else if (release_bank && bank1_state == READING &&
                             bank1_sequence[15:0] == release_sequence) begin
                    bank1_state     <= FREE;
                    release_granted <= 1'b1;
                end
            end

            if (frame_abort || frame_done) begin
                if (active_export) begin
                    if (frame_abort || frame_error) begin
                        if (active_bank) bank1_state <= FREE;
                        else             bank0_state <= FREE;
                        if (result_abort_count != 32'hffff_ffff)
                            result_abort_count <= result_abort_count + 1'b1;
                    end else begin
                        if (active_bank) begin
                            bank1_state           <= PUBLISH;
                            bank1_sequence        <= active_sequence;
                            bank1_start_sample_id <= frame_start_sample_id;
                            bank1_end_sample_id   <= frame_end_sample_id;
                        end else begin
                            bank0_state           <= PUBLISH;
                            bank0_sequence        <= active_sequence;
                            bank0_start_sample_id <= frame_start_sample_id;
                            bank0_end_sample_id   <= frame_end_sample_id;
                        end
                        published_pulse <= 1'b1;
                        published_bank  <= active_bank;
                    end
                end
                active_export <= 1'b0;
            end

            if (frame_begin) begin
                // Sequence counts every attempted frame, including export
                // drops, so software can see gaps in delivered metadata.
                active_sequence <= next_sequence;
                next_sequence   <= next_sequence + 1'b1;
                if (bank0_state == FREE) begin
                    bank0_state   <= WRITING;
                    active_export <= 1'b1;
                    active_bank   <= 1'b0;
                end else if (bank1_state == FREE) begin
                    bank1_state   <= WRITING;
                    active_export <= 1'b1;
                    active_bank   <= 1'b1;
                end else if (bank0_evictable && bank1_evictable) begin
                    // Signed modular order is valid because two READY frames
                    // cannot be separated by 2^31 attempted frames: each new
                    // frame replaces the older READY result.
                    if ($signed(bank0_sequence - bank1_sequence) <= 0) begin
                        bank0_state <= WRITING;
                        active_bank <= 1'b0;
                    end else begin
                        bank1_state <= WRITING;
                        active_bank <= 1'b1;
                    end
                    active_export <= 1'b1;
                    if (result_export_drop_count != 32'hffff_ffff)
                        result_export_drop_count <= result_export_drop_count + 1'b1;
                end else if (bank0_evictable || bank1_evictable) begin
                    if (bank0_evictable) bank0_state <= WRITING;
                    else                 bank1_state <= WRITING;
                    active_export <= 1'b1;
                    active_bank   <= bank1_evictable && !bank0_evictable;
                    if (result_export_drop_count != 32'hffff_ffff)
                        result_export_drop_count <= result_export_drop_count + 1'b1;
                end else begin
                    active_export <= 1'b0;
                    if (result_export_drop_count != 32'hffff_ffff)
                        result_export_drop_count <= result_export_drop_count + 1'b1;
                end
            end
        end
    end
endmodule
