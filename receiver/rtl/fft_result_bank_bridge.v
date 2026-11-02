`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// fft_result_bank_bridge - coherent metadata and PS commands across ADC/AXI
//
// GPIO1 output control_word (AXI domain):
//   [0] legacy FFT start toggle, [1] claim toggle, [2] release toggle,
//   [3] bank, [19:4] frame sequence low 16, [23:20] status selector.
// GPIO2 input status_word, selector 0:
//   [31:8]=24'hB25A3C ABI, [7]=release_granted, [6]=claim_granted,
//   [5]=release_ack toggle, [4]=claim_ack toggle,
//   [3:2]=claimed mask, [1:0]=ready mask.
// Selectors 1..5: bank A sequence/start_lo/start_hi/end_lo/end_hi.
// Selectors 6..10: corresponding bank B fields.
// Selector 11: export drop count; 12: aborted export count.
//
// Metadata crosses with one XPM handshake per bank. The owner does not set
// READY until its publish_ack returns, so GPIO never advertises stale data.
// Claims/releases use independent XPM handshakes carrying {bank,seq[15:0]}.
// PS must hold bank and sequence stable until the matching ACK toggle changes.
//////////////////////////////////////////////////////////////////////////////////
module fft_result_bank_bridge (
    input  wire        adc_clk,
    input  wire        adc_resetn,
    input  wire        axi_clk,
    input  wire        axi_resetn,
    input  wire [31:0] control_word,
    output reg  [31:0] status_word,

    input  wire [1:0]  bank_ready_adc,
    input  wire [1:0]  bank_claimed_adc,
    input  wire        published_pulse,
    input  wire        published_bank,
    input  wire [31:0] bank0_sequence,
    input  wire [31:0] bank1_sequence,
    input  wire [47:0] bank0_start_sample_id,
    input  wire [47:0] bank0_end_sample_id,
    input  wire [47:0] bank1_start_sample_id,
    input  wire [47:0] bank1_end_sample_id,
    input  wire [31:0] result_export_drop_count,
    input  wire [31:0] result_abort_count,
    output reg  [1:0]  publish_ack,

    output reg         claim_req,
    output reg         claim_bank,
    output reg  [15:0] claim_sequence,
    input  wire        owner_claim_ack,
    input  wire        owner_claim_granted,
    output reg         release_req,
    output reg         release_bank,
    output reg  [15:0] release_sequence,
    input  wire        owner_release_ack,
    input  wire        owner_release_granted
);
    reg [127:0] meta0_payload_adc, meta1_payload_adc;
    reg meta0_send_adc, meta1_send_adc;
    wire meta0_rcv_adc, meta1_rcv_adc;
    wire [127:0] meta0_out_axi, meta1_out_axi;
    wire meta0_req_axi, meta1_req_axi;
    reg [127:0] meta0_axi, meta1_axi;

    xpm_cdc_handshake #(.WIDTH(128), .DEST_EXT_HSK(0),
        .DEST_SYNC_FF(2), .SRC_SYNC_FF(2), .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(0)) meta0_cdc (
        .src_clk(adc_clk), .src_in(meta0_payload_adc),
        .src_send(meta0_send_adc), .src_rcv(meta0_rcv_adc),
        .dest_clk(axi_clk), .dest_out(meta0_out_axi),
        .dest_req(meta0_req_axi), .dest_ack(1'b1)
    );
    xpm_cdc_handshake #(.WIDTH(128), .DEST_EXT_HSK(0),
        .DEST_SYNC_FF(2), .SRC_SYNC_FF(2), .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(0)) meta1_cdc (
        .src_clk(adc_clk), .src_in(meta1_payload_adc),
        .src_send(meta1_send_adc), .src_rcv(meta1_rcv_adc),
        .dest_clk(axi_clk), .dest_out(meta1_out_axi),
        .dest_req(meta1_req_axi), .dest_ack(1'b1)
    );

    reg [16:0] claim_payload_axi, release_payload_axi;
    reg claim_send_axi, release_send_axi;
    wire claim_rcv_axi, release_rcv_axi;
    wire [16:0] claim_out_adc, release_out_adc;
    wire claim_dest_req_adc, release_dest_req_adc;
    reg claim_dest_ack_adc, release_dest_ack_adc;

    xpm_cdc_handshake #(.WIDTH(17), .DEST_EXT_HSK(1),
        .DEST_SYNC_FF(2), .SRC_SYNC_FF(2), .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(0)) claim_cdc (
        .src_clk(axi_clk), .src_in(claim_payload_axi),
        .src_send(claim_send_axi), .src_rcv(claim_rcv_axi),
        .dest_clk(adc_clk), .dest_out(claim_out_adc),
        .dest_req(claim_dest_req_adc), .dest_ack(claim_dest_ack_adc)
    );
    xpm_cdc_handshake #(.WIDTH(17), .DEST_EXT_HSK(1),
        .DEST_SYNC_FF(2), .SRC_SYNC_FF(2), .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(0)) release_cdc (
        .src_clk(axi_clk), .src_in(release_payload_axi),
        .src_send(release_send_axi), .src_rcv(release_rcv_axi),
        .dest_clk(adc_clk), .dest_out(release_out_adc),
        .dest_req(release_dest_req_adc), .dest_ack(release_dest_ack_adc)
    );

    (* ASYNC_REG = "TRUE" *) reg ready0_sync1, ready0_sync2;
    (* ASYNC_REG = "TRUE" *) reg ready1_sync1, ready1_sync2;
    (* ASYNC_REG = "TRUE" *) reg claimed0_sync1, claimed0_sync2;
    (* ASYNC_REG = "TRUE" *) reg claimed1_sync1, claimed1_sync2;
    wire [1:0] ready_sync2 = {ready1_sync2, ready0_sync2};
    wire [1:0] claimed_sync2 = {claimed1_sync2, claimed0_sync2};
    (* ASYNC_REG = "TRUE" *) reg claim_grant_sync1, claim_grant_sync2;
    (* ASYNC_REG = "TRUE" *) reg release_grant_sync1, release_grant_sync2;
    wire [31:0] drops_axi, aborts_axi;
    xpm_cdc_gray #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(0),
        .REG_OUTPUT(0), .SIM_ASSERT_CHK(0),
        .SIM_LOSSLESS_GRAY_CHK(0), .WIDTH(32)) drop_count_cdc (
        .src_clk(adc_clk), .src_in_bin(result_export_drop_count),
        .dest_clk(axi_clk), .dest_out_bin(drops_axi)
    );
    xpm_cdc_gray #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(0),
        .REG_OUTPUT(0), .SIM_ASSERT_CHK(0),
        .SIM_LOSSLESS_GRAY_CHK(0), .WIDTH(32)) abort_count_cdc (
        .src_clk(adc_clk), .src_in_bin(result_abort_count),
        .dest_clk(axi_clk), .dest_out_bin(aborts_axi)
    );

    reg claim_dest_issued, release_dest_issued;
    reg claim_grant_adc, release_grant_adc;
    always @(posedge adc_clk) begin
        if (!adc_resetn) begin
            meta0_payload_adc <= 128'd0;
            meta1_payload_adc <= 128'd0;
            meta0_send_adc <= 1'b0;
            meta1_send_adc <= 1'b0;
            publish_ack <= 2'b00;
            claim_req <= 1'b0;
            claim_bank <= 1'b0;
            claim_sequence <= 16'd0;
            release_req <= 1'b0;
            release_bank <= 1'b0;
            release_sequence <= 16'd0;
            claim_dest_issued <= 1'b0;
            release_dest_issued <= 1'b0;
            claim_dest_ack_adc <= 1'b0;
            release_dest_ack_adc <= 1'b0;
            claim_grant_adc <= 1'b0;
            release_grant_adc <= 1'b0;
        end else begin
            publish_ack <= 2'b00;
            claim_req <= 1'b0;
            release_req <= 1'b0;

            if (published_pulse && !published_bank) begin
                meta0_payload_adc <= {bank0_sequence, bank0_start_sample_id,
                                      bank0_end_sample_id};
                meta0_send_adc <= 1'b1;
            end else if (meta0_send_adc && meta0_rcv_adc) begin
                meta0_send_adc <= 1'b0;
                publish_ack[0] <= 1'b1;
            end
            if (published_pulse && published_bank) begin
                meta1_payload_adc <= {bank1_sequence, bank1_start_sample_id,
                                      bank1_end_sample_id};
                meta1_send_adc <= 1'b1;
            end else if (meta1_send_adc && meta1_rcv_adc) begin
                meta1_send_adc <= 1'b0;
                publish_ack[1] <= 1'b1;
            end

            if (claim_dest_req_adc && !claim_dest_issued) begin
                claim_bank <= claim_out_adc[16];
                claim_sequence <= claim_out_adc[15:0];
                claim_req <= 1'b1;
                claim_dest_issued <= 1'b1;
            end
            if (claim_dest_issued && owner_claim_ack) begin
                claim_grant_adc <= owner_claim_granted;
                claim_dest_ack_adc <= 1'b1;
            end
            if (!claim_dest_req_adc) begin
                claim_dest_issued <= 1'b0;
                claim_dest_ack_adc <= 1'b0;
            end

            if (release_dest_req_adc && !release_dest_issued) begin
                release_bank <= release_out_adc[16];
                release_sequence <= release_out_adc[15:0];
                release_req <= 1'b1;
                release_dest_issued <= 1'b1;
            end
            if (release_dest_issued && owner_release_ack) begin
                release_grant_adc <= owner_release_granted;
                release_dest_ack_adc <= 1'b1;
            end
            if (!release_dest_req_adc) begin
                release_dest_issued <= 1'b0;
                release_dest_ack_adc <= 1'b0;
            end
        end
    end

    reg claim_seen_toggle, release_seen_toggle;
    reg claim_ack_toggle_axi, release_ack_toggle_axi;
    reg claim_granted_axi, release_granted_axi;
    reg [1:0] claim_return_delay, release_return_delay;
    always @(posedge axi_clk) begin
        if (!axi_resetn) begin
            meta0_axi <= 128'd0;
            meta1_axi <= 128'd0;
            ready0_sync1 <= 1'b0;
            ready0_sync2 <= 1'b0;
            ready1_sync1 <= 1'b0;
            ready1_sync2 <= 1'b0;
            claimed0_sync1 <= 1'b0;
            claimed0_sync2 <= 1'b0;
            claimed1_sync1 <= 1'b0;
            claimed1_sync2 <= 1'b0;
            claim_grant_sync1 <= 1'b0;
            claim_grant_sync2 <= 1'b0;
            release_grant_sync1 <= 1'b0;
            release_grant_sync2 <= 1'b0;
            claim_payload_axi <= 17'd0;
            release_payload_axi <= 17'd0;
            claim_send_axi <= 1'b0;
            release_send_axi <= 1'b0;
            claim_seen_toggle <= 1'b0;
            release_seen_toggle <= 1'b0;
            claim_ack_toggle_axi <= 1'b0;
            release_ack_toggle_axi <= 1'b0;
            claim_granted_axi <= 1'b0;
            release_granted_axi <= 1'b0;
            claim_return_delay <= 2'd0;
            release_return_delay <= 2'd0;
        end else begin
            if (meta0_req_axi) meta0_axi <= meta0_out_axi;
            if (meta1_req_axi) meta1_axi <= meta1_out_axi;
            ready0_sync1 <= bank_ready_adc[0];
            ready0_sync2 <= ready0_sync1;
            ready1_sync1 <= bank_ready_adc[1];
            ready1_sync2 <= ready1_sync1;
            claimed0_sync1 <= bank_claimed_adc[0];
            claimed0_sync2 <= claimed0_sync1;
            claimed1_sync1 <= bank_claimed_adc[1];
            claimed1_sync2 <= claimed1_sync1;
            claim_grant_sync1 <= claim_grant_adc;
            claim_grant_sync2 <= claim_grant_sync1;
            release_grant_sync1 <= release_grant_adc;
            release_grant_sync2 <= release_grant_sync1;

            if (!claim_send_axi && !claim_rcv_axi &&
                control_word[1] != claim_seen_toggle) begin
                claim_payload_axi <= {control_word[3], control_word[19:4]};
                claim_seen_toggle <= control_word[1];
                claim_send_axi <= 1'b1;
            end else if (claim_send_axi && claim_rcv_axi) begin
                claim_send_axi <= 1'b0;
                claim_return_delay <= 2'd3;
            end
            if (claim_return_delay != 2'd0) begin
                claim_return_delay <= claim_return_delay - 1'b1;
                if (claim_return_delay == 2'd1) begin
                    claim_granted_axi <= claim_grant_sync2;
                    claim_ack_toggle_axi <= ~claim_ack_toggle_axi;
                end
            end

            if (!release_send_axi && !release_rcv_axi &&
                control_word[2] != release_seen_toggle) begin
                release_payload_axi <= {control_word[3], control_word[19:4]};
                release_seen_toggle <= control_word[2];
                release_send_axi <= 1'b1;
            end else if (release_send_axi && release_rcv_axi) begin
                release_send_axi <= 1'b0;
                release_return_delay <= 2'd3;
            end
            if (release_return_delay != 2'd0) begin
                release_return_delay <= release_return_delay - 1'b1;
                if (release_return_delay == 2'd1) begin
                    release_granted_axi <= release_grant_sync2;
                    release_ack_toggle_axi <= ~release_ack_toggle_axi;
                end
            end
        end
    end

    always @* begin
        case (control_word[23:20])
            4'd0: status_word = {24'hB25A3C, release_granted_axi,
                                claim_granted_axi, release_ack_toggle_axi,
                                claim_ack_toggle_axi, claimed_sync2, ready_sync2};
            4'd1:  status_word = meta0_axi[127:96];
            4'd2:  status_word = meta0_axi[79:48];
            4'd3:  status_word = {16'd0, meta0_axi[95:80]};
            4'd4:  status_word = meta0_axi[31:0];
            4'd5:  status_word = {16'd0, meta0_axi[47:32]};
            4'd6:  status_word = meta1_axi[127:96];
            4'd7:  status_word = meta1_axi[79:48];
            4'd8:  status_word = {16'd0, meta1_axi[95:80]};
            4'd9:  status_word = meta1_axi[31:0];
            4'd10: status_word = {16'd0, meta1_axi[47:32]};
            4'd11: status_word = drops_axi;
            4'd12: status_word = aborts_axi;
            default: status_word = 32'd0;
        endcase
    end
endmodule
