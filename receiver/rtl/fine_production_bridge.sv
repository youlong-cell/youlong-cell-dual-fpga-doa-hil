`timescale 1ns/1ps
// AXI GPIO is a mailbox, never a live multiword bus. All arbitrary multibit
// crossings below are held-data handshakes or one complete async FIFO record.
// command[31] toggle, opcode[27:24], index[7:0]; payload written first.
// One outstanding command. No automatic result ACK when moving FIFO data.
module fine_production_bridge #(
    parameter integer ENABLE_MAINTENANCE=0
) (
    input wire adc_clk,adc_resetn,axi_clk,axi_resetn,
    input wire [31:0] command_word,payload_word,
    output wire [31:0] status_word,output reg [31:0] response_word,
    output wire command_valid,output wire [7:0] command_opcode,command_index,
    output wire [31:0] command_data,output wire [127:0] command_tag,
    input wire command_done,input wire [7:0] command_status,
    input wire [31:0] command_response,
    input wire result_valid,input wire [1087:0] result_packet,
    input wire maintenance_hold_adc,
    input wire command_accept_ready,
    output wire maintenance_done_adc,
    output wire maintenance_released_adc,
    output wire control_ready_adc,
    output wire maintenance_hold_axi
);
    reg [127:0] tags;
    reg seen,ack_toggle,command_ok,busy;
    // XPM handshakes have no runtime reset. Preserve held payload/send/ACK
    // across local reset; drain them behind a four-phase recovery barrier.
    // A retained 64-bit transport ID is never re-used in a powered session.
    // Power-on INIT also initializes XPM, so no pre-power-on packet survives.
    wire [239:0] cmd_hold;
    wire cmd_send;
    wire cmd_received,cmd_req;
    wire [239:0] cmd_adc;
    wire cmd_ack_adc,cmd_seen_adc,cmd_canceled_adc;
    wire [63:0] transport_id;
    wire control_inflight;
    reg recover_req_adc=1,recover_req_axi=1;
    reg recover_ack_adc=0,recover_ack_axi=0;
    wire remote_req_adc,remote_req_axi,remote_ack_adc,remote_ack_axi;
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1)) control_req_a (
        .src_clk(adc_clk),.src_in(recover_req_adc),.dest_clk(axi_clk),.dest_out(remote_req_axi));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1)) control_req_x (
        .src_clk(axi_clk),.src_in(recover_req_axi),.dest_clk(adc_clk),.dest_out(remote_req_adc));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1)) control_ack_a (
        .src_clk(adc_clk),.src_in(recover_ack_adc),.dest_clk(axi_clk),.dest_out(remote_ack_axi));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1)) control_ack_x (
        .src_clk(axi_clk),.src_in(recover_ack_axi),.dest_clk(adc_clk),.dest_out(remote_ack_adc));
    assign control_ready_adc=adc_resetn && !recover_req_adc && !remote_req_adc &&
                             !recover_ack_adc && !remote_ack_adc;
    wire control_ready_axi=axi_resetn && !recover_req_axi && !remote_req_axi &&
                           !recover_ack_axi && !remote_ack_axi;

    xpm_cdc_handshake #(.WIDTH(240),.DEST_EXT_HSK(1),.DEST_SYNC_FF(2),.SRC_SYNC_FF(2)) command_cdc (
        .src_clk(axi_clk),.src_in(cmd_hold),.src_send(cmd_send),.src_rcv(cmd_received),
        .dest_clk(adc_clk),.dest_out(cmd_adc),.dest_req(cmd_req),.dest_ack(cmd_ack_adc));
    wire [103:0] rsp_hold;
    wire rsp_send;
    wire rsp_received,rsp_req;
    wire [103:0] rsp_axi;
    wire rsp_ack,rsp_seen;

    wire response_match;
    wire command_launch=control_ready_axi && transport_id!=64'hffffffffffffffff &&
                       !busy && !cmd_send && !cmd_received && !rsp_req &&
                       command_word[31]!=seen && command_word[30:28]==0 &&
                       command_word[23:8]==0 && command_word[27:24]!=0 && command_word[27:24]!=8;
    xpm_cdc_handshake #(.WIDTH(104),.DEST_EXT_HSK(1),.DEST_SYNC_FF(2),.SRC_SYNC_FF(2)) response_cdc (
        .src_clk(adc_clk),.src_in(rsp_hold),.src_send(rsp_send),.src_rcv(rsp_received),
        .dest_clk(axi_clk),.dest_out(rsp_axi),.dest_req(rsp_req),.dest_ack(rsp_ack));
    fine_command_mailbox #(.ENABLE_MAINTENANCE(ENABLE_MAINTENANCE)) mailbox (
        .adc_clk(adc_clk),.axi_clk(axi_clk),.control_ready_adc(control_ready_adc),
        .control_ready_axi(control_ready_axi),.command_launch(command_launch),
        .command_word(command_word),.payload_word(payload_word),.tags(tags),
        .command_accept_ready(command_accept_ready),.command_done(command_done),
        .command_status(command_status),.command_response(command_response),
        .cmd_received(cmd_received),.cmd_req(cmd_req),.cmd_adc(cmd_adc),
        .rsp_received(rsp_received),.rsp_req(rsp_req),.rsp_axi(rsp_axi),
        .command_valid(command_valid),.command_opcode(command_opcode),.command_index(command_index),
        .command_data(command_data),.command_tag(command_tag),.response_match(response_match),
        .cmd_hold(cmd_hold),.cmd_send(cmd_send),.cmd_ack_adc(cmd_ack_adc),
        .cmd_seen_adc(cmd_seen_adc),.cmd_canceled_adc(cmd_canceled_adc),
        .transport_id(transport_id),.control_inflight(control_inflight),
        .rsp_hold(rsp_hold),.rsp_send(rsp_send),.rsp_ack(rsp_ack),.rsp_seen(rsp_seen)
    );
    always @(posedge adc_clk) begin
        if(!adc_resetn) recover_req_adc<=1;
        else if(remote_ack_adc) recover_req_adc<=0;
        if(!remote_req_adc) recover_ack_adc<=0;
        else if(!cmd_req && !cmd_ack_adc && !rsp_send && !rsp_received)
            recover_ack_adc<=1;
    end
    always @(posedge axi_clk) begin
        if(!axi_resetn) recover_req_axi<=1;
        else if(remote_ack_axi) recover_req_axi<=0;
        if(!remote_req_axi) recover_ack_axi<=0;
        else if(!cmd_send && !cmd_received && !rsp_req && !rsp_ack) recover_ack_axi<=1;
    end
    // Enqueue exactly once per immutable slot identity. Emptying the FIFO is
    // only transport; original ADC result_slot remains occupied until tagged ACK.
    wire [127:0] sent_key;
    wire sent;
    wire full,wr_reset_busy,rd_reset_busy,empty,data_valid;
    wire [1087:0] fifo_data;
    wire [1087:0] snapshot;
    wire snapshot_valid,fifo_read_pending;
    // Step 2 is a FIFO transport recovery fence, NOT STOP or a mailbox reset.
    // All CDC inputs below are registered one-bit protocol levels. In
    // particular no remote reset level reaches result_fifo.rst or wr_en.
    localparam [2:0] FIFO_FENCE=0,FIFO_ASSERT=1,FIFO_BUSY_WAIT=2,
                     FIFO_RETURN=3,FIFO_ONLINE=4;
    // UG974 specifies a synchronous level, not a one-cycle completion pulse.
    // Eight write clocks is a conservative hold floor, NOT an invented AMD
    // minimum: release also requires THIS round's actual write/read busy seen.
    localparam integer FIFO_RESET_HOLD_CYCLES=8;
    reg [2:0] fifo_reset_state=FIFO_FENCE;
    reg [3:0] fifo_reset_count=0;
    reg fifo_rst_adc=0,fifo_fence_adc=1,fifo_online_adc=0;
    reg fifo_local_reset_pending=1,fifo_wr_busy_seen=0;
    reg fifo_generation_adc=0;
    reg fifo_recover_req_axi=1,fifo_fenced_axi=0;
    reg fifo_rd_busy_seen_axi=0,fifo_rd_ready_axi=0;
    wire fifo_recover_req_adc,fifo_fenced_adc,fifo_rd_busy_seen_adc;
    wire fifo_rd_ready_adc,fifo_fence_axi,fifo_reset_level_axi;
    wire fifo_online_axi,fifo_generation_axi;
    wire hold_adc=(ENABLE_MAINTENANCE!=0) && maintenance_hold_adc;
    reg hold_seen_adc=1;
    reg hold_level_adc=1;
    wire hold_axi;
    reg hold_done_axi=0;
    reg release_ready_axi=0;
    wire hold_done_adc;
    wire release_ready_adc;
    always @(posedge adc_clk) begin
        hold_level_adc<=hold_adc;
        hold_seen_adc<=hold_adc;
    end
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1)) maintenance_level (
        .src_clk(adc_clk),.src_in(hold_level_adc),.dest_clk(axi_clk),.dest_out(hold_axi));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1)) maintenance_ack (
        .src_clk(axi_clk),.src_in(hold_done_axi),.dest_clk(adc_clk),.dest_out(hold_done_adc));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1)) maintenance_release_ack (
        .src_clk(axi_clk),.src_in(release_ready_axi),.dest_clk(adc_clk),.dest_out(release_ready_adc));
    assign maintenance_hold_axi=(ENABLE_MAINTENANCE!=0) && hold_axi;
    assign maintenance_done_adc=hold_done_adc && fifo_online_adc && !wr_reset_busy && !fifo_rst_adc;
    assign maintenance_released_adc=release_ready_adc && fifo_online_adc && !wr_reset_busy && !fifo_rst_adc;
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1)) fifo_req_cdc (
        .src_clk(axi_clk),.src_in(fifo_recover_req_axi),.dest_clk(adc_clk),.dest_out(fifo_recover_req_adc));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1)) fifo_fenced_cdc (
        .src_clk(axi_clk),.src_in(fifo_fenced_axi),.dest_clk(adc_clk),.dest_out(fifo_fenced_adc));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1)) fifo_rd_seen_cdc (
        .src_clk(axi_clk),.src_in(fifo_rd_busy_seen_axi),.dest_clk(adc_clk),.dest_out(fifo_rd_busy_seen_adc));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1)) fifo_rd_ready_cdc (
        .src_clk(axi_clk),.src_in(fifo_rd_ready_axi),.dest_clk(adc_clk),.dest_out(fifo_rd_ready_adc));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1)) fifo_fence_cdc (
        .src_clk(adc_clk),.src_in(fifo_fence_adc),.dest_clk(axi_clk),.dest_out(fifo_fence_axi));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1)) fifo_reset_level_cdc (
        .src_clk(adc_clk),.src_in(fifo_rst_adc),.dest_clk(axi_clk),.dest_out(fifo_reset_level_axi));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1)) fifo_online_cdc (
        .src_clk(adc_clk),.src_in(fifo_online_adc),.dest_clk(axi_clk),.dest_out(fifo_online_axi));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1)) fifo_generation_cdc (
        .src_clk(adc_clk),.src_in(fifo_generation_adc),.dest_clk(axi_clk),.dest_out(fifo_generation_axi));

    // Intentionally retain this private sequencer across local reset events:
    // resetting it while XPM busy is high would illegally retrigger the FIFO.
    // Power-on INIT starts fenced. Runtime reset is a sticky synchronous request.
    // A reset while RETURN is pending causes another round after return-to-zero.
    always @(posedge adc_clk) begin
        if(!adc_resetn) fifo_local_reset_pending<=1;
        case(fifo_reset_state)
            FIFO_FENCE: begin
                fifo_online_adc<=0;fifo_fence_adc<=1;
                if(fifo_fenced_adc && !wr_reset_busy &&
                   !fifo_rd_busy_seen_adc && !fifo_rd_ready_adc) begin
                    fifo_rst_adc<=1;fifo_reset_count<=0;fifo_wr_busy_seen<=0;
                    fifo_generation_adc<=!fifo_generation_adc;
                    fifo_reset_state<=FIFO_ASSERT;
                end
            end
            FIFO_ASSERT: begin
                if(wr_reset_busy) fifo_wr_busy_seen<=1;
                if(fifo_reset_count<FIFO_RESET_HOLD_CYCLES-1)
                    fifo_reset_count<=fifo_reset_count+1'b1;
                if(fifo_reset_count==FIFO_RESET_HOLD_CYCLES-1 &&
                   fifo_wr_busy_seen && fifo_rd_busy_seen_adc) begin
                    fifo_rst_adc<=0;fifo_reset_state<=FIFO_BUSY_WAIT;
                end
            end
            FIFO_BUSY_WAIT: begin
                if(!wr_reset_busy && fifo_rd_ready_adc &&
                   !fifo_recover_req_adc && adc_resetn) begin
                    fifo_local_reset_pending<=0;fifo_fence_adc<=0;
                    fifo_reset_state<=FIFO_RETURN;
                end
            end
            FIFO_RETURN: begin
                if(!fifo_fenced_adc && !fifo_rd_busy_seen_adc && !fifo_rd_ready_adc) begin
                    if(fifo_local_reset_pending || !adc_resetn || fifo_recover_req_adc) begin
                        fifo_fence_adc<=1;fifo_reset_state<=FIFO_FENCE;
                    end else begin
                        fifo_online_adc<=1;fifo_reset_state<=FIFO_ONLINE;
                    end
                end
            end
            FIFO_ONLINE: begin
                if(fifo_local_reset_pending || !adc_resetn || fifo_recover_req_adc) begin
                    fifo_online_adc<=0;fifo_fence_adc<=1;fifo_reset_state<=FIFO_FENCE;
                end
            end
            default: begin
                // Fail closed, finish an existing XPM round before re-entering.
                fifo_online_adc<=0;fifo_fence_adc<=1;
                fifo_reset_state<=fifo_rst_adc?FIFO_ASSERT:FIFO_BUSY_WAIT;
            end
        endcase
        // STOP flush is a held synchronous maintenance request, not a reset pin.
        if(hold_adc && !hold_seen_adc) fifo_local_reset_pending<=1;
    end
    // No reset of the in-flight FIFO fence/busy proof on an AXI reset event.
    // The request is held until the current fenced flush is actually complete;
    // repeated resets coalesce while closed, rather than becoming narrow pulses.
    always @(posedge axi_clk) begin
        if(!axi_resetn) fifo_recover_req_axi<=1;
        else if(fifo_fence_axi && fifo_rd_ready_axi) fifo_recover_req_axi<=0;
        if(!fifo_fence_axi) begin
            fifo_fenced_axi<=0;fifo_rd_busy_seen_axi<=0;fifo_rd_ready_axi<=0;
        end else begin
            if(!fifo_fenced_axi && axi_resetn && !fifo_read_pending &&
               !data_valid && !rd_reset_busy && !fifo_reset_level_axi)
                fifo_fenced_axi<=1;
            if(fifo_reset_level_axi && rd_reset_busy) fifo_rd_busy_seen_axi<=1;
            // Busy-seen is sticky for this round; ready is NOT sticky. A local
            // reset or a renewed XPM busy phase withdraws the completion level.
            if(!axi_resetn || fifo_reset_level_axi || rd_reset_busy ||
               !empty || fifo_read_pending || data_valid) fifo_rd_ready_axi<=0;
            else if(fifo_rd_busy_seen_axi)
                fifo_rd_ready_axi<=1;
        end
    end
    wire fifo_read_ready_axi=fifo_online_axi && !fifo_fence_axi &&
                            !fifo_recover_req_axi && !fifo_fenced_axi && axi_resetn;
    always @(posedge axi_clk) begin
        hold_done_axi<=hold_axi && axi_resetn && fifo_read_ready_axi &&
                       !rd_reset_busy && !fifo_read_pending && !data_valid && !snapshot_valid;
        release_ready_axi<=!hold_axi && control_ready_axi && fifo_read_ready_axi &&
                           !rd_reset_busy && !fifo_read_pending && !data_valid;
    end
    wire fifo_recovery_start_adc=(fifo_reset_state==FIFO_ONLINE ||
                                  fifo_reset_state==FIFO_RETURN) &&
                                 (fifo_local_reset_pending || !adc_resetn || fifo_recover_req_adc);
    // Transport-side session admission only. Does not reset/change the Fine
    // result slot, RESULT_ACK, Window owner or the 1088-bit record ABI.
    // Old held ADC slots must not be re-enqueued after transport-only recovery.
    wire [63:0] fifo_epoch_adc;
    // Only one std-mode read may be in flight. Keep the next complete
    // record IN the FIFO while the previous snapshot awaits ACK response.
    // Independent FIFO/response CDC latency must never cause silent loss.
    wire fifo_read,wr_en;
    // The sole reset driver is a write-clock-domain register.
    xpm_fifo_async #(.FIFO_MEMORY_TYPE("block"),.FIFO_WRITE_DEPTH(16),
        .WRITE_DATA_WIDTH(1088),.READ_DATA_WIDTH(1088),.READ_MODE("std"),
        .FIFO_READ_LATENCY(1),.CDC_SYNC_STAGES(2),.RELATED_CLOCKS(0),
        .USE_ADV_FEATURES("1000"),.WR_DATA_COUNT_WIDTH(5),.RD_DATA_COUNT_WIDTH(5),
        .PROG_EMPTY_THRESH(3),.PROG_FULL_THRESH(12),.ECC_MODE("no_ecc")) result_fifo (
        .rst(fifo_rst_adc),.wr_clk(adc_clk),.rd_clk(axi_clk),
        .din(result_packet),.wr_en(wr_en),.full(full),.wr_rst_busy(wr_reset_busy),
        .rd_en(fifo_read),.dout(fifo_data),
        .empty(empty),.data_valid(data_valid),.rd_rst_busy(rd_reset_busy),
        .sleep(1'b0),.injectsbiterr(1'b0),.injectdbiterr(1'b0));
    wire [63:0] installed_epoch;
    reg [7:0] last_status;
    reg request_toggle;
    reg [3:0] request_opcode;
    reg fifo_generation_seen_axi=0,fifo_fence_seen_axi=0;
    wire fifo_generation_changed_axi=fifo_generation_seen_axi!=fifo_generation_axi;
    wire fifo_fence_start_axi=fifo_fence_axi && !fifo_fence_seen_axi;
    wire snapshot_visible=snapshot_valid && fifo_read_ready_axi && !rd_reset_busy &&
                          !fifo_generation_changed_axi;
    // status: bit0 completion toggle; bit1 command granted; bit2 busy;
    // bit3 result snapshot available; [15:8] command status; [31:16] ABI=1.
    assign status_word={16'h0001,last_status,4'd0,snapshot_visible,
                        (busy || !control_ready_axi),command_ok,ack_toggle};
    wire command_response_success=rsp_req && !rsp_seen && response_match && busy && rsp_axi[39:32]==0;
    fine_result_transport result_transport (
        .adc_clk(adc_clk),.adc_resetn(adc_resetn),.axi_clk(axi_clk),.axi_resetn(axi_resetn),
        .result_valid(result_valid),.result_packet(result_packet),
        .command_done(command_done),.command_status(command_status),
        .command_opcode(command_opcode),.command_tag(command_tag),
        .fifo_recovery_start_adc(fifo_recovery_start_adc),
        .full(full),.wr_reset_busy(wr_reset_busy),.rd_reset_busy(rd_reset_busy),
        .empty(empty),.data_valid(data_valid),.fifo_data(fifo_data),
        .fifo_rst_adc(fifo_rst_adc),.fifo_online_adc(fifo_online_adc),
        .fifo_local_reset_pending(fifo_local_reset_pending),.fifo_recover_req_adc(fifo_recover_req_adc),
        .hold_adc(hold_adc),.hold_axi(hold_axi),.fifo_read_ready_axi(fifo_read_ready_axi),
        .fifo_generation_changed_axi(fifo_generation_changed_axi),.fifo_fence_start_axi(fifo_fence_start_axi),
        .control_ready_axi(control_ready_axi),.command_response_success(command_response_success),
        .request_opcode(request_opcode),.cmd_hold(cmd_hold),.fifo_read(fifo_read),.wr_en(wr_en),
        .sent_key(sent_key),.sent(sent),.fifo_epoch_adc(fifo_epoch_adc),
        .snapshot(snapshot),.snapshot_valid(snapshot_valid),.fifo_read_pending(fifo_read_pending),
        .installed_epoch(installed_epoch)
    );
    always @(posedge axi_clk) begin
        fifo_generation_seen_axi<=fifo_generation_axi;
        fifo_fence_seen_axi<=fifo_fence_axi;
        if(!axi_resetn) begin
            tags<=0;seen<=command_word[31];ack_toggle<=command_word[31];command_ok<=0;busy<=0;
            response_word<=0;
            last_status<=0;
            request_toggle<=0;request_opcode<=0;
        end else begin
            if(rsp_req && !rsp_seen && response_match && busy) begin
                response_word<=rsp_axi[31:0];
                last_status<=rsp_axi[39:32];command_ok<=rsp_axi[39:32]==0;
                ack_toggle<=request_toggle;busy<=0;
            end
            if(control_ready_axi && !busy && !cmd_send && !cmd_received && !rsp_req &&
               command_word[31]!=seen) begin
                seen<=command_word[31];request_toggle<=command_word[31];
                request_opcode<=command_word[27:24];command_ok<=0;last_status<=0;
                if(command_word[30:28]!=0 || command_word[23:8]!=0) begin
                    last_status<=8'h01;ack_toggle<=command_word[31];
                end else if(command_word[27:24]==0) begin
                    if(command_word[7:0]<4) begin
                        tags[command_word[1:0]*32+:32]<=payload_word;command_ok<=1;
                    end else last_status<=8'h01;
                    ack_toggle<=command_word[31];
                end else if(command_word[27:24]==8) begin
                    if(snapshot_visible && command_word[7:0]<34) begin
                        response_word<=snapshot[command_word[7:0]*32+:32];command_ok<=1;
                    end else begin last_status<=8'h02;response_word<=0;end
                    ack_toggle<=command_word[31];
                end else begin
                    if(transport_id==64'hffffffffffffffff) begin
                        last_status<=8'h06;ack_toggle<=command_word[31];
                    end else busy<=1;
                end
            end
            // Invalidation has priority over data_valid / ACK response races.
            // Drain pending std reads; clear on current-round reset busy only
            // after reads have already been fenced, never issue a second read.
            if(!control_ready_axi) begin
                // A canceled command is never ACKed as success. Align the GPIO
                // level only while fenced; retained XPM transactions still drain.
                busy<=0;seen<=command_word[31];ack_toggle<=command_word[31];
                command_ok<=0;last_status<=8'h06;
            end
        end
    end
endmodule
