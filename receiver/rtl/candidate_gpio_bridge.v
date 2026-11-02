`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// One frozen-window PS consumer, transported by two dual-channel AXI GPIOs.
// GPIO command outputs: {command_word, payload_word}; status inputs:
// {status_word, response_word}. Command[31] toggles per request; [30:28]
// opcode; [15:0] word index. Write payload first, then command, wait for
// status[0] ACK toggle. One request at a time. Opcodes: 1=config write,
// 2=commit all four config words, 3=metadata read, 4=window read,
// 5=tagged release, 6=counter read, 7=fault read/tagged clear. An
// uncommitted detector stays disabled.
// Multibit ADC/AXI crossings use XPM handshakes; frozen data uses a separate
// AXI-clock read port of the immutable Copy RAM, never the live Ring.
//////////////////////////////////////////////////////////////////////////////////
module candidate_gpio_bridge #(
    parameter integer ENABLE_RETIRE = 0,
    parameter integer ENABLE_MAINTENANCE = 0
) (
    input wire adc_clk, adc_resetn, axi_clk, axi_resetn,
    input wire maintenance_hold_adc,maintenance_hold_axi,
    output wire maintenance_ready_adc,
    input wire [31:0] command_word, payload_word,
    output wire [31:0] status_word,
    output reg [31:0] response_word,
    output reg cfg_committed_adc, cfg_enable_adc,
    output reg [8:0] cfg_bin_min_adc, cfg_bin_max_adc,
    output reg [31:0] cfg_ch0_min_adc, cfg_ch1_min_adc,
                      cfg_publish_min_adc,
    input wire window_ready_adc, active_adc, fault_adc,
    // PL owner must retire PS metadata/read capability before internal release.
    input wire retire_req_adc,
    output wire retire_ack_adc,
    input wire [31:0] fault_seq_adc, fault_copy_progress_adc,
    input wire [7:0] fault_code_adc,
    input wire [47:0] fault_sample_id_adc,
    input wire [31:0] last_drop_seq_adc,
    input wire [7:0] last_drop_reason_adc,
    input wire [31:0] count_drop_pre_adc,
                      count_drop_deadline_adc,
                      count_drop_history_adc,
                      count_protocol_error_adc,
    input wire [31:0] meta_candidate_seq_adc, meta_frame_seq_adc,
    input wire [47:0] meta_frame_start_adc, meta_event_id_adc,
                      meta_window_start_adc, meta_copy_done_id_adc,
    input wire [8:0] meta_bin_adc,
    input wire [31:0] meta_pwr_ch0_adc, meta_pwr_ch1_adc, meta_score_adc,
    input wire [7:0] meta_flags_adc,
    input wire [31:0] count_candidate_adc, count_accepted_adc,
                      count_busy_adc,
    output reg release_valid_adc,
    output reg [31:0] release_seq_adc,
    input wire release_ack_adc, release_granted_adc,
    output reg clear_fault_valid_adc,
    output reg [31:0] clear_fault_seq_adc,
    input wire clear_fault_ack_adc, clear_fault_granted_adc,
    output reg window_rd_req_axi,
    output reg [11:0] window_rd_addr_axi,
    input wire window_rd_valid_axi,
    input wire [31:0] window_rd_data_axi
);
    localparam [2:0] IDLE=0, CFG_WAIT=1, READ_WAIT=2,
                     RELEASE_WAIT=3, RELEASE_SETTLE=4,
                     CLEAR_WAIT=5, CLEAR_SETTLE=6;
    reg [2:0] state;
    reg command_seen, ack_toggle, command_ok, release_granted_axi;
    reg [1:0] settle;
    reg [31:0] cfg0, cfg1, cfg2, cfg3;
    reg [3:0] cfg_mask;
    reg cfg_ready_axi;
    reg [114:0] cfg_payload_axi=0;
    reg cfg_send_axi=0;
    wire cfg_rcv_axi, cfg_req_adc;
    wire [114:0] cfg_payload_adc;
    reg cfg_ack_adc, cfg_seen_adc;
    reg [31:0] release_payload_axi=0;
    reg release_send_axi=0, release_dest_ack_adc, release_seen_adc;
    wire release_rcv_axi, release_req_adc;
    wire [31:0] release_payload_adc;
    reg release_grant_hold_adc;
    reg [31:0] clear_payload_axi=0;
    reg clear_send_axi=0, clear_dest_ack_adc, clear_seen_adc;
    wire clear_rcv_axi, clear_req_adc;
    wire [31:0] clear_payload_adc;
    reg clear_grant_hold_adc;
    (* ASYNC_REG="TRUE" *) reg grant_sync1, grant_sync2;
    (* ASYNC_REG="TRUE" *) reg clear_grant_sync1, clear_grant_sync2;
    (* ASYNC_REG="TRUE" *) reg active_sync1, active_sync2;
    // Manager fault is a combinational FSM decode. Register it in its
    // SOURCE domain before crossing: decode -> ADC FF -> AXI sync1/sync2.
    // FAULT is a held level until tagged CLEAR, not a pulse. The extra ADC
    // cycle cannot lose it; fault metadata still uses the atomic handshake.
    reg fault_level_adc;
    (* ASYNC_REG="TRUE" *) reg fault_sync1, fault_sync2;
    (* ASYNC_REG="TRUE" *) reg adc_up_sync1, adc_up_sync2;
    reg [479:0] meta_payload_adc=0, meta_axi;
    reg meta_send_adc=0, meta_sent_adc, meta_ack_axi, meta_seen_axi,
        meta_valid_axi;
    wire meta_rcv_adc, meta_req_axi;
    wire [479:0] meta_payload_axi;
    wire [31:0] candidate_count_axi, accepted_count_axi, busy_count_axi;
    reg [159:0] fault_payload_adc=0, fault_meta_axi;
    reg fault_send_adc=0, fault_sent_adc, fault_ack_axi, fault_seen_axi,
        fault_meta_valid_axi;
    wire fault_rcv_adc, fault_req_axi;
    wire [159:0] fault_payload_axi;
    reg [63:0] drop_payload_adc=0, drop_meta_axi;
    reg drop_send_adc=0, drop_ack_axi, drop_seen_axi;
    reg [31:0] drop_sent_count_adc;
    wire drop_rcv_adc, drop_req_axi;
    wire [63:0] drop_payload_axi;
    wire [31:0] drop_pre_count_axi, drop_deadline_count_axi,
                drop_history_count_axi, protocol_error_count_axi;
    reg [31:0] protocol_reject_count_axi;
    wire [32:0] protocol_total_axi =
        {1'b0, protocol_error_count_axi} +
        {1'b0, protocol_reject_count_axi};
    wire [31:0] protocol_total_sat_axi = protocol_total_axi[32] ?
        32'hffff_ffff : protocol_total_axi[31:0];
    wire retire_enabled_adc = (ENABLE_RETIRE != 0) && retire_req_adc;
    reg retire_send_adc=0, retire_completed_adc;
    wire retire_rcv_adc, retire_req_axi;
    wire retire_data_axi;
    reg retire_ack_axi;
    wire hold_adc=(ENABLE_MAINTENANCE!=0) && maintenance_hold_adc;
    wire hold_axi=(ENABLE_MAINTENANCE!=0) && maintenance_hold_axi;
    reg drain_ready_axi=0;
    wire drain_ready_adc;
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1)) debug_drain_cdc (
        .src_clk(axi_clk),.src_in(drain_ready_axi),.dest_clk(adc_clk),.dest_out(drain_ready_adc));
    always @(posedge axi_clk) begin
        drain_ready_axi<=axi_resetn && hold_axi && state==IDLE &&
            !window_rd_req_axi && !window_rd_valid_axi && !meta_valid_axi &&
            !cfg_send_axi && !cfg_rcv_axi && !release_send_axi && !release_rcv_axi &&
            !clear_send_axi && !clear_rcv_axi && !meta_req_axi && !meta_ack_axi &&
            !fault_req_axi && !fault_ack_axi && !drop_req_axi && !drop_ack_axi &&
            !retire_req_axi && !retire_ack_axi;
    end
    assign maintenance_ready_adc=drain_ready_adc &&
        !meta_send_adc && !meta_rcv_adc && !fault_send_adc && !fault_rcv_adc &&
        !drop_send_adc && !drop_rcv_adc && !retire_send_adc && !retire_rcv_adc &&
        !cfg_req_adc && !cfg_ack_adc && !release_req_adc && !release_dest_ack_adc &&
        !clear_req_adc && !clear_dest_ack_adc;
    assign retire_ack_adc = retire_enabled_adc && retire_completed_adc &&
                            !meta_send_adc && !meta_rcv_adc;
    generate if (ENABLE_RETIRE != 0) begin : g_retire
        xpm_cdc_handshake #(.WIDTH(1), .DEST_EXT_HSK(1),
            .DEST_SYNC_FF(2), .SRC_SYNC_FF(2), .INIT_SYNC_FF(0),
            .SIM_ASSERT_CHK(0)) retire_cdc (
            .src_clk(adc_clk), .src_in(1'b1),
            .src_send(retire_send_adc), .src_rcv(retire_rcv_adc),
            .dest_clk(axi_clk), .dest_out(retire_data_axi),
            .dest_req(retire_req_axi), .dest_ack(retire_ack_axi));
    end else begin : g_no_retire
        assign retire_rcv_adc = 1'b0;
        assign retire_req_axi = 1'b0;
        assign retire_data_axi = 1'b0;
    end endgenerate

    xpm_cdc_handshake #(.WIDTH(115), .DEST_EXT_HSK(1),
        .DEST_SYNC_FF(2), .SRC_SYNC_FF(2), .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(0)) cfg_cdc (
        .src_clk(axi_clk), .src_in(cfg_payload_axi),
        .src_send(cfg_send_axi), .src_rcv(cfg_rcv_axi),
        .dest_clk(adc_clk), .dest_out(cfg_payload_adc),
        .dest_req(cfg_req_adc), .dest_ack(cfg_ack_adc));
    xpm_cdc_handshake #(.WIDTH(32), .DEST_EXT_HSK(1),
        .DEST_SYNC_FF(2), .SRC_SYNC_FF(2), .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(0)) release_cdc (
        .src_clk(axi_clk), .src_in(release_payload_axi),
        .src_send(release_send_axi), .src_rcv(release_rcv_axi),
        .dest_clk(adc_clk), .dest_out(release_payload_adc),
        .dest_req(release_req_adc), .dest_ack(release_dest_ack_adc));
    xpm_cdc_handshake #(.WIDTH(32), .DEST_EXT_HSK(1),
        .DEST_SYNC_FF(2), .SRC_SYNC_FF(2), .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(0)) clear_fault_cdc (
        .src_clk(axi_clk), .src_in(clear_payload_axi),
        .src_send(clear_send_axi), .src_rcv(clear_rcv_axi),
        .dest_clk(adc_clk), .dest_out(clear_payload_adc),
        .dest_req(clear_req_adc), .dest_ack(clear_dest_ack_adc));
    xpm_cdc_handshake #(.WIDTH(480), .DEST_EXT_HSK(1),
        .DEST_SYNC_FF(2), .SRC_SYNC_FF(2), .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(0)) meta_cdc (
        .src_clk(adc_clk), .src_in(meta_payload_adc),
        .src_send(meta_send_adc), .src_rcv(meta_rcv_adc),
        .dest_clk(axi_clk), .dest_out(meta_payload_axi),
        .dest_req(meta_req_axi), .dest_ack(meta_ack_axi));
    xpm_cdc_handshake #(.WIDTH(160), .DEST_EXT_HSK(1),
        .DEST_SYNC_FF(2), .SRC_SYNC_FF(2), .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(0)) fault_meta_cdc (
        .src_clk(adc_clk), .src_in(fault_payload_adc),
        .src_send(fault_send_adc), .src_rcv(fault_rcv_adc),
        .dest_clk(axi_clk), .dest_out(fault_payload_axi),
        .dest_req(fault_req_axi), .dest_ack(fault_ack_axi));
    xpm_cdc_handshake #(.WIDTH(64), .DEST_EXT_HSK(1),
        .DEST_SYNC_FF(2), .SRC_SYNC_FF(2), .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(0)) drop_meta_cdc (
        .src_clk(adc_clk), .src_in(drop_payload_adc),
        .src_send(drop_send_adc), .src_rcv(drop_rcv_adc),
        .dest_clk(axi_clk), .dest_out(drop_payload_axi),
        .dest_req(drop_req_axi), .dest_ack(drop_ack_axi));
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(2), .INIT_SYNC_FF(0),
        .REG_OUTPUT(0), .SIM_ASSERT_CHK(0), .SIM_LOSSLESS_GRAY_CHK(0))
        count0_cdc (.src_clk(adc_clk), .src_in_bin(count_candidate_adc),
                    .dest_clk(axi_clk), .dest_out_bin(candidate_count_axi));
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(2), .INIT_SYNC_FF(0),
        .REG_OUTPUT(0), .SIM_ASSERT_CHK(0), .SIM_LOSSLESS_GRAY_CHK(0))
        count1_cdc (.src_clk(adc_clk), .src_in_bin(count_accepted_adc),
                    .dest_clk(axi_clk), .dest_out_bin(accepted_count_axi));
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(2), .INIT_SYNC_FF(0),
        .REG_OUTPUT(0), .SIM_ASSERT_CHK(0), .SIM_LOSSLESS_GRAY_CHK(0))
        count2_cdc (.src_clk(adc_clk), .src_in_bin(count_busy_adc),
                    .dest_clk(axi_clk), .dest_out_bin(busy_count_axi));

    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(2), .INIT_SYNC_FF(0),
        .REG_OUTPUT(0), .SIM_ASSERT_CHK(0), .SIM_LOSSLESS_GRAY_CHK(0))
        count3_cdc (.src_clk(adc_clk), .src_in_bin(count_drop_pre_adc),
                    .dest_clk(axi_clk), .dest_out_bin(drop_pre_count_axi));
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(2), .INIT_SYNC_FF(0),
        .REG_OUTPUT(0), .SIM_ASSERT_CHK(0), .SIM_LOSSLESS_GRAY_CHK(0))
        count4_cdc (.src_clk(adc_clk), .src_in_bin(count_drop_deadline_adc),
                    .dest_clk(axi_clk), .dest_out_bin(drop_deadline_count_axi));
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(2), .INIT_SYNC_FF(0),
        .REG_OUTPUT(0), .SIM_ASSERT_CHK(0), .SIM_LOSSLESS_GRAY_CHK(0))
        count5_cdc (.src_clk(adc_clk), .src_in_bin(count_drop_history_adc),
                    .dest_clk(axi_clk), .dest_out_bin(drop_history_count_axi));
    xpm_cdc_gray #(.WIDTH(32), .DEST_SYNC_FF(2), .INIT_SYNC_FF(0),
        .REG_OUTPUT(0), .SIM_ASSERT_CHK(0), .SIM_LOSSLESS_GRAY_CHK(0))
        count6_cdc (.src_clk(adc_clk), .src_in_bin(count_protocol_error_adc),
                    .dest_clk(axi_clk), .dest_out_bin(protocol_error_count_axi));

    always @(posedge adc_clk) begin
        if (!adc_resetn)
            fault_level_adc <= 1'b0;
        else
            fault_level_adc <= fault_adc;
    end

    assign status_word = {16'hca17, 8'd0, active_sync2, fault_sync2,
        cfg_ready_axi, meta_valid_axi, release_granted_axi, fault_meta_valid_axi,
        command_ok, ack_toggle};

    always @(posedge adc_clk) begin
        if (!adc_resetn) begin
            cfg_committed_adc <= 1'b0; cfg_enable_adc <= 1'b0;
            cfg_bin_min_adc <= 9'd0; cfg_bin_max_adc <= 9'd0;
            cfg_ch0_min_adc <= 32'd0; cfg_ch1_min_adc <= 32'd0;
            cfg_publish_min_adc <= 32'd0;
            cfg_ack_adc <= 1'b0; cfg_seen_adc <= 1'b0;
            release_valid_adc <= 1'b0; release_seq_adc <= 32'd0;
            release_dest_ack_adc <= 1'b0; release_seen_adc <= 1'b0;
            release_grant_hold_adc <= 1'b0;
            clear_fault_valid_adc <= 1'b0; clear_fault_seq_adc <= 32'd0;
            clear_dest_ack_adc <= 1'b0; clear_seen_adc <= 1'b0;
            clear_grant_hold_adc <= 1'b0;
            meta_sent_adc <= 1'b0;
            retire_completed_adc <= 0;
            fault_sent_adc <= 1'b0;
            drop_sent_count_adc <= 32'd0;
        end else begin
            release_valid_adc <= 1'b0;
            clear_fault_valid_adc <= 1'b0;
            if (cfg_req_adc && !cfg_seen_adc) begin
                {cfg_enable_adc, cfg_bin_min_adc, cfg_bin_max_adc,
                 cfg_ch0_min_adc, cfg_ch1_min_adc, cfg_publish_min_adc}
                    <= cfg_payload_adc;
                cfg_committed_adc <= 1'b1;
                cfg_seen_adc <= 1'b1; cfg_ack_adc <= 1'b1;
            end else if (!cfg_req_adc) begin
                cfg_seen_adc <= 1'b0; cfg_ack_adc <= 1'b0;
            end
            if (release_req_adc && !release_seen_adc) begin
                release_seq_adc <= release_payload_adc;
                release_valid_adc <= 1'b1;
                release_seen_adc <= 1'b1;
            end
            if (release_seen_adc && release_ack_adc) begin
                release_grant_hold_adc <= release_granted_adc;
                release_dest_ack_adc <= 1'b1;
            end
            if (!release_req_adc) begin
                release_seen_adc <= 1'b0;
                release_dest_ack_adc <= 1'b0;
            end
            if (clear_req_adc && !clear_seen_adc) begin
                clear_fault_seq_adc <= clear_payload_adc;
                clear_fault_valid_adc <= 1'b1;
                clear_seen_adc <= 1'b1;
            end
            if (clear_seen_adc && clear_fault_ack_adc) begin
                clear_grant_hold_adc <= clear_fault_granted_adc;
                clear_dest_ack_adc <= 1'b1;
            end
            if (!clear_req_adc) begin
                clear_seen_adc <= 1'b0;
                clear_dest_ack_adc <= 1'b0;
            end
            // Serialize retirement after the ENTIRE metadata handshake, even
            // if Fine finishes before PS has observed the descriptor.
            if (!hold_adc && retire_enabled_adc && !retire_completed_adc &&
                !retire_send_adc && !retire_rcv_adc &&
                !meta_send_adc && !meta_rcv_adc) retire_send_adc <= 1;
            if (retire_send_adc && retire_rcv_adc) begin
                retire_send_adc <= 0; retire_completed_adc <= 1;
            end
            if (!retire_enabled_adc && !retire_send_adc && !retire_rcv_adc)
                retire_completed_adc <= 0;
            if (!hold_adc && window_ready_adc && !retire_enabled_adc &&
                !retire_completed_adc && !retire_rcv_adc &&
                !meta_sent_adc && !meta_send_adc && !meta_rcv_adc) begin
                meta_payload_adc <= {
                    32'h0001_0000,
                    {16'd0, meta_copy_done_id_adc[47:32]},
                    meta_copy_done_id_adc[31:0], meta_score_adc,
                    meta_pwr_ch1_adc, meta_pwr_ch0_adc,
                    {15'd0, meta_flags_adc, meta_bin_adc},
                    {16'd0, meta_window_start_adc[47:32]},
                    meta_window_start_adc[31:0],
                    {16'd0, meta_event_id_adc[47:32]},
                    meta_event_id_adc[31:0],
                    {16'd0, meta_frame_start_adc[47:32]},
                    meta_frame_start_adc[31:0], meta_frame_seq_adc,
                    meta_candidate_seq_adc};
                meta_send_adc <= 1'b1;
            end else if (meta_send_adc && meta_rcv_adc) begin
                meta_send_adc <= 1'b0; meta_sent_adc <= 1'b1;
            end
            if (!window_ready_adc && !meta_send_adc)
                meta_sent_adc <= 1'b0;
            if (!hold_adc && fault_adc && !fault_sent_adc && !fault_send_adc) begin
                fault_payload_adc <= {
                    fault_copy_progress_adc,
                    {16'd0, fault_sample_id_adc[47:32]},
                    fault_sample_id_adc[31:0],
                    {24'd0, fault_code_adc}, fault_seq_adc};
                fault_send_adc <= 1'b1;
            end else if (fault_send_adc && fault_rcv_adc) begin
                fault_send_adc <= 1'b0;
                fault_sent_adc <= 1'b1;
            end
            if (!fault_adc && !fault_send_adc)
                fault_sent_adc <= 1'b0;
            if (!hold_adc && !drop_send_adc && !drop_rcv_adc &&
                count_drop_pre_adc != drop_sent_count_adc) begin
                drop_payload_adc <= {{24'd0, last_drop_reason_adc},
                                     last_drop_seq_adc};
                drop_sent_count_adc <= count_drop_pre_adc;
                drop_send_adc <= 1'b1;
            end else if (drop_send_adc && drop_rcv_adc) begin
                drop_send_adc <= 1'b0;
            end
        end
    end

    always @(posedge axi_clk) begin
        if (!axi_resetn) begin
            state <= IDLE; command_seen <= 1'b0; ack_toggle <= 1'b0;
            command_ok <= 1'b0; release_granted_axi <= 1'b0;
            settle <= 2'd0; cfg0 <= 32'd0; cfg1 <= 32'd0;
            cfg2 <= 32'd0; cfg3 <= 32'd0; cfg_mask <= 4'd0;
            cfg_ready_axi <= 1'b0; grant_sync1 <= 1'b0;
            grant_sync2 <= 1'b0; active_sync1 <= 1'b0;
            clear_grant_sync1 <= 1'b0; clear_grant_sync2 <= 1'b0;
            active_sync2 <= 1'b0; fault_sync1 <= 1'b0;
            fault_sync2 <= 1'b0; adc_up_sync1 <= 1'b0;
            adc_up_sync2 <= 1'b0; meta_ack_axi <= 1'b0;
            meta_seen_axi <= 1'b0; meta_valid_axi <= 1'b0;
            meta_axi <= 480'd0; response_word <= 32'd0;
            fault_ack_axi <= 1'b0; fault_seen_axi <= 1'b0;
            fault_meta_valid_axi <= 1'b0; fault_meta_axi <= 160'd0;
            drop_ack_axi <= 1'b0; drop_seen_axi <= 1'b0;
            drop_meta_axi <= 64'd0;
            retire_ack_axi <= 0;
            protocol_reject_count_axi <= 32'd0;
            window_rd_req_axi <= 1'b0; window_rd_addr_axi <= 12'd0;
        end else begin
            window_rd_req_axi <= 1'b0;
            // Retained source transactions must finish even if reset discarded
            // the software-facing wait state. Held data is not re-labeled.
            if(cfg_rcv_axi) cfg_send_axi<=0;
            if(release_rcv_axi) release_send_axi<=0;
            if(clear_rcv_axi) clear_send_axi<=0;
            grant_sync1 <= release_grant_hold_adc;
            grant_sync2 <= grant_sync1;
            clear_grant_sync1 <= clear_grant_hold_adc;
            clear_grant_sync2 <= clear_grant_sync1;
            active_sync1 <= active_adc; active_sync2 <= active_sync1;
            fault_sync1 <= fault_level_adc; fault_sync2 <= fault_sync1;
            adc_up_sync1 <= adc_resetn; adc_up_sync2 <= adc_up_sync1;
            if (!adc_up_sync2) begin
                meta_valid_axi <= 1'b0; cfg_ready_axi <= 1'b0;
                fault_meta_valid_axi <= 1'b0;
            end
            if (meta_req_axi && !meta_seen_axi) begin
                meta_axi <= meta_payload_axi;
                meta_valid_axi <= 1'b1;
                meta_seen_axi <= 1'b1; meta_ack_axi <= 1'b1;
            end else if (!meta_req_axi) begin
                meta_seen_axi <= 1'b0; meta_ack_axi <= 1'b0;
            end
            if (fault_req_axi && !fault_seen_axi) begin
                fault_meta_axi <= fault_payload_axi;
                fault_meta_valid_axi <= 1'b1;
                fault_seen_axi <= 1'b1; fault_ack_axi <= 1'b1;
            end else if (!fault_req_axi) begin
                fault_seen_axi <= 1'b0; fault_ack_axi <= 1'b0;
            end
            if (drop_req_axi && !drop_seen_axi) begin
                drop_meta_axi <= drop_payload_axi;
                drop_seen_axi <= 1'b1; drop_ack_axi <= 1'b1;
            end else if (!drop_req_axi) begin
                drop_seen_axi <= 1'b0; drop_ack_axi <= 1'b0;
            end
            if (retire_req_axi) begin
                meta_valid_axi <= 0;
                // An already accepted debug read returns while the copy is
                // still frozen. ACK retirement only after its response drains.
                if (state != READ_WAIT && !window_rd_req_axi &&
                    !window_rd_valid_axi) retire_ack_axi <= 1;
            end else retire_ack_axi <= 0;
            case (state)
                IDLE: if (command_word[31] != command_seen) begin
                    command_seen <= command_word[31];
                    command_ok <= 1'b0;
                    if(hold_axi) ack_toggle<=command_word[31];
                    else begin
                    case (command_word[30:28])
                        3'd1: begin
                            case (command_word[15:0])
                                0: begin cfg0 <= payload_word; cfg_mask[0] <= 1'b1; command_ok <= 1'b1; end
                                1: begin cfg1 <= payload_word; cfg_mask[1] <= 1'b1; command_ok <= 1'b1; end
                                2: begin cfg2 <= payload_word; cfg_mask[2] <= 1'b1; command_ok <= 1'b1; end
                                3: begin cfg3 <= payload_word; cfg_mask[3] <= 1'b1; command_ok <= 1'b1; end
                                default: command_ok <= 1'b0;
                            endcase
                            ack_toggle <= ~ack_toggle;
                        end
                        3'd2: if (cfg_mask == 4'hf && !cfg_send_axi &&
                                   !cfg_rcv_axi && cfg0[9:1] != 9'd0 &&
                                   cfg0[18:10] >= cfg0[9:1]) begin
                            cfg_payload_axi <= {cfg0[0], cfg0[9:1],
                                cfg0[18:10], cfg1, cfg2, cfg3};
                            cfg_send_axi <= 1'b1; cfg_ready_axi <= 1'b0;
                            state <= CFG_WAIT;
                        end else ack_toggle <= ~ack_toggle;
                        3'd3: begin
                            if (meta_valid_axi && !retire_req_axi && command_word[15:0] < 15) begin
                                response_word <= meta_axi[command_word[3:0]*32 +: 32];
                                command_ok <= 1'b1;
                            end
                            ack_toggle <= ~ack_toggle;
                        end
                        3'd4: if (meta_valid_axi && !retire_req_axi && command_word[15:12] == 0) begin
                            window_rd_addr_axi <= command_word[11:0];
                            window_rd_req_axi <= 1'b1;
                            state <= READ_WAIT;
                        end else ack_toggle <= ~ack_toggle;
                        3'd5: if (meta_valid_axi && !release_send_axi &&
                                   !release_rcv_axi &&
                                   payload_word == meta_axi[31:0]) begin
                            release_payload_axi <= payload_word;
                            release_send_axi <= 1'b1;
                            release_granted_axi <= 1'b0;
                            state <= RELEASE_WAIT;
                        end else begin
                            if (protocol_reject_count_axi != 32'hffff_ffff)
                                protocol_reject_count_axi <=
                                    protocol_reject_count_axi + 1'b1;
                            ack_toggle <= ~ack_toggle;
                        end
                        3'd6: begin
                            case (command_word[15:0])
                                0: begin response_word <= candidate_count_axi; command_ok <= 1'b1; end
                                1: begin response_word <= accepted_count_axi; command_ok <= 1'b1; end
                                2: begin response_word <= busy_count_axi; command_ok <= 1'b1; end
                                3: begin response_word <= drop_pre_count_axi; command_ok <= 1'b1; end
                                4: begin response_word <= drop_deadline_count_axi; command_ok <= 1'b1; end
                                5: begin response_word <= drop_history_count_axi; command_ok <= 1'b1; end
                                6: begin response_word <= protocol_total_sat_axi; command_ok <= 1'b1; end
                                7: begin response_word <= drop_meta_axi[31:0]; command_ok <= 1'b1; end
                                8: begin response_word <= drop_meta_axi[63:32]; command_ok <= 1'b1; end
                                default: command_ok <= 1'b0;
                            endcase
                            ack_toggle <= ~ack_toggle;
                        end
                        3'd7: if (command_word[15:0] == 16'h8000) begin
                            if (fault_meta_valid_axi && fault_sync2 &&
                                !clear_send_axi && !clear_rcv_axi &&
                                payload_word == fault_meta_axi[31:0]) begin
                                clear_payload_axi <= payload_word;
                                clear_send_axi <= 1'b1;
                                state <= CLEAR_WAIT;
                            end else begin
                                if (protocol_reject_count_axi != 32'hffff_ffff)
                                    protocol_reject_count_axi <=
                                        protocol_reject_count_axi + 1'b1;
                                ack_toggle <= ~ack_toggle;
                            end
                        end else begin
                            if (fault_meta_valid_axi &&
                                command_word[15:0] < 16'd5) begin
                                response_word <=
                                    fault_meta_axi[command_word[2:0]*32 +: 32];
                                command_ok <= 1'b1;
                            end
                            ack_toggle <= ~ack_toggle;
                        end
                        default: ack_toggle <= ~ack_toggle;
                    endcase
                    end
                end
                CFG_WAIT: if (cfg_rcv_axi) begin
                    cfg_send_axi <= 1'b0; cfg_ready_axi <= 1'b1;
                    // A later commit must supply a fresh complete config;
                    // do not silently mix new and previous threshold words.
                    cfg_mask <= 4'd0;
                    command_ok <= 1'b1; ack_toggle <= ~ack_toggle;
                    state <= IDLE;
                end
                READ_WAIT: if (window_rd_valid_axi) begin
                    response_word <= window_rd_data_axi;
                    command_ok <= 1'b1; ack_toggle <= ~ack_toggle;
                    state <= IDLE;
                end
                RELEASE_WAIT: if (release_rcv_axi) begin
                    release_send_axi <= 1'b0; settle <= 2'd3;
                    state <= RELEASE_SETTLE;
                end
                RELEASE_SETTLE: if (settle != 2'd0) begin
                    settle <= settle - 1'b1;
                end else begin
                    release_granted_axi <= grant_sync2;
                    command_ok <= grant_sync2;
                    if (grant_sync2) meta_valid_axi <= 1'b0;
                    ack_toggle <= ~ack_toggle; state <= IDLE;
                end
                CLEAR_WAIT: if (clear_rcv_axi) begin
                    clear_send_axi <= 1'b0; settle <= 2'd3;
                    state <= CLEAR_SETTLE;
                end
                CLEAR_SETTLE: if (settle != 2'd0) begin
                    settle <= settle - 1'b1;
                end else begin
                    command_ok <= clear_grant_sync2;
                    if (clear_grant_sync2) fault_meta_valid_axi <= 1'b0;
                    ack_toggle <= ~ack_toggle; state <= IDLE;
                end
                default: state <= IDLE;
            endcase
            // Highest priority: old descriptors may drain/ACK but cannot regain
            // read capability in a new session. Already issued reads still drain.
            if(hold_axi) begin meta_valid_axi<=0;fault_meta_valid_axi<=0;cfg_ready_axi<=0;end
        end
    end
endmodule
