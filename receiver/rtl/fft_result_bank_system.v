`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// fft_result_bank_system - BD-facing wrapper for one shared ADC timeline and
// two atomic, PS-claimed FFT result banks. All BRAM writes pass through owner.
//////////////////////////////////////////////////////////////////////////////////
module fft_result_bank_system (
    input  wire        adc_clk,
    input  wire        adc_resetn,
    input  wire        axi_clk,
    input  wire        axi_resetn,
    output wire        sample_tick,
    output wire [47:0] sample_id,
    // Same sample_timebase instance, exposed for the Ring/Copy candidate
    // chain. Do not create a second absolute counter in the new BD cell.
    output wire [47:0] committed_sample_id,
    output wire        committed_sample_valid,
    output wire        legacy_start_toggle,
    input  wire [31:0] control_word,
    output wire [31:0] status_word,
    input  wire        frame_begin,
    input  wire        frame_done,
    input  wire        frame_abort,
    input  wire        frame_error,
    input  wire [47:0] frame_start_sample_id,
    input  wire [47:0] frame_end_sample_id,
    input  wire        raw_bram_en,
    input  wire [7:0]  raw_bram_we,
    input  wire [31:0] raw_bram_addr,
    input  wire [63:0] raw_bram_data,
    output wire        banked_bram_en,
    output wire [7:0]  banked_bram_we,
    output wire [31:0] banked_bram_addr,
    output wire [63:0] banked_bram_data
);
    wire [47:0] next_sample_id, current_sample_id;
    wire current_valid;
    assign committed_sample_id = current_sample_id;
    assign committed_sample_valid = current_valid;
    assign sample_tick = 1'b1; // registered AD9238 pair arrives every ADC edge
    // The BD port name is historical. The current AUTO_RESTART=1 controller
    // interprets bit 0 as a persistent search run-enable; legacy one-shot
    // AUTO_RESTART=0 still interprets it as a start toggle.
    assign legacy_start_toggle = control_word[0];
    sample_timebase u_sample_timebase (
        .adc_clk(adc_clk), .adc_resetn(adc_resetn),
        .sample_tick(sample_tick), .sample_id(sample_id),
        .next_sample_id(next_sample_id),
        .current_sample_id(current_sample_id),
        .current_valid(current_valid)
    );

    wire [1:0] ready, claimed, publish_ack;
    wire [31:0] sequence0, sequence1, drops, aborts;
    wire [47:0] start0, end0, start1, end1;
    wire published, published_bank;
    wire claim_req, claim_bank, claim_ack, claim_granted;
    wire [15:0] claim_sequence;
    wire release_req, release_bank, release_ack, release_granted;
    wire [15:0] release_sequence;

    fft_result_bank_owner u_owner (
        .adc_clk(adc_clk), .adc_resetn(adc_resetn),
        .frame_begin(frame_begin), .frame_done(frame_done),
        .frame_abort(frame_abort), .frame_error(frame_error),
        .frame_start_sample_id(frame_start_sample_id),
        .frame_end_sample_id(frame_end_sample_id),
        .publish_ack(publish_ack),
        .raw_bram_en(raw_bram_en), .raw_bram_we(raw_bram_we),
        .raw_bram_addr(raw_bram_addr), .raw_bram_data(raw_bram_data),
        .banked_bram_en(banked_bram_en),
        .banked_bram_we(banked_bram_we),
        .banked_bram_addr(banked_bram_addr),
        .banked_bram_data(banked_bram_data),
        .claim_req(claim_req), .claim_bank(claim_bank),
        .claim_sequence(claim_sequence), .claim_ack(claim_ack),
        .claim_granted(claim_granted), .release_req(release_req),
        .release_bank(release_bank),
        .release_sequence(release_sequence),
        .release_ack(release_ack),
        .release_granted(release_granted),
        .bank_ready(ready), .bank_claimed(claimed),
        .bank0_sequence(sequence0), .bank1_sequence(sequence1),
        .bank0_start_sample_id(start0), .bank0_end_sample_id(end0),
        .bank1_start_sample_id(start1), .bank1_end_sample_id(end1),
        .published_pulse(published), .published_bank(published_bank),
        .result_export_drop_count(drops),
        .result_abort_count(aborts)
    );

    fft_result_bank_bridge u_bridge (
        .adc_clk(adc_clk), .adc_resetn(adc_resetn),
        .axi_clk(axi_clk), .axi_resetn(axi_resetn),
        .control_word(control_word), .status_word(status_word),
        .bank_ready_adc(ready), .bank_claimed_adc(claimed),
        .published_pulse(published), .published_bank(published_bank),
        .bank0_sequence(sequence0), .bank1_sequence(sequence1),
        .bank0_start_sample_id(start0), .bank0_end_sample_id(end0),
        .bank1_start_sample_id(start1), .bank1_end_sample_id(end1),
        .result_export_drop_count(drops),
        .result_abort_count(aborts), .publish_ack(publish_ack),
        .claim_req(claim_req), .claim_bank(claim_bank),
        .claim_sequence(claim_sequence),
        .owner_claim_ack(claim_ack),
        .owner_claim_granted(claim_granted),
        .release_req(release_req), .release_bank(release_bank),
        .release_sequence(release_sequence),
        .owner_release_ack(release_ack),
        .owner_release_granted(release_granted)
    );
endmodule
