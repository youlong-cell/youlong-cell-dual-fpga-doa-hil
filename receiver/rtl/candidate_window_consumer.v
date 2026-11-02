`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Frozen Window consumer ownership, entirely synchronous to adc_clk.
// PS_DEBUG=0 (reset default), PL_FINE=1. This is NOT a Fine algorithm.
// A successful offer handshake captures the immutable candidate_seq. Fine
// must echo that tag, stop requests/deassert busy, and latch its result BEFORE
// pulsing done. The result bank/publication itself belongs to a later stage.
// PS debug reads use Port B; retirement revokes/drains them before Port A
// ownership is returned to the Manager. No timeout auto-release is allowed.
//////////////////////////////////////////////////////////////////////////////////
module candidate_window_consumer #(
    parameter integer ENABLE_MAINTENANCE=0
) (
    input wire adc_clk, adc_resetn,
    input wire maintenance_clear,
    input wire manager_active, copy_busy, candidate_arriving,
    input wire window_ready,
    input wire [31:0] active_seq,
    input wire consumer_mode_valid, consumer_mode,
    output reg consumer_mode_ack, consumer_mode_granted,
    output reg consumer_mode_active,
    output wire window_offer_valid,
    input wire window_offer_ready,
    output reg [31:0] held_seq,
    input wire fine_rd_req, fine_rd_valid,
    input wire fine_busy, fine_done, fine_fault, fine_result_latched,
    input wire [31:0] fine_seq,
    output wire fine_rd_ready, fine_abort,
    input wire ps_release_valid,
    input wire [31:0] ps_release_seq,
    output wire manager_release_valid,
    output wire [31:0] manager_release_seq,
    input wire manager_release_ack, manager_release_granted,
    output wire ps_release_ack, ps_release_granted,
    output reg fine_release_ack, fine_release_granted,
    output reg [31:0] fine_release_seq,
    output wire retire_req,
    input wire retire_ack,
    output wire consumer_fault_valid,
    output wire [31:0] consumer_fault_seq,
    output wire consumer_idle,
    output reg [31:0] protocol_error_count
);
    localparam [2:0] IDLE=0, READING=1, RETIRE=2, RELEASE=3,
                     ACK_WAIT=4, FAULT_DRAIN=5, FAULT_SEND=6, FAULT_WAIT=7;
    reg [2:0] state;
    reg ps_reject_ack;
    // PS_DEBUG release still reaches the original Manager and its tagged ACK.
    assign manager_release_valid = consumer_mode_active ?
                                   (state == RELEASE) : ps_release_valid;
    assign manager_release_seq = consumer_mode_active ? held_seq : ps_release_seq;
    assign ps_release_ack = consumer_mode_active ? ps_reject_ack : manager_release_ack;
    assign ps_release_granted = !consumer_mode_active && manager_release_granted;
    assign window_offer_valid = consumer_mode_active && (state == IDLE) && window_ready;
    assign fine_rd_ready = consumer_mode_active && (state == READING) &&
                           window_ready && !fine_fault && !fine_done;
    assign fine_abort = (state == FAULT_DRAIN) || (state == FAULT_SEND) ||
                        (state == FAULT_WAIT);
    assign retire_req = (state == RETIRE) || (state == RELEASE) ||
                         (state == ACK_WAIT) || fine_abort;
    assign consumer_fault_valid = (state == FAULT_SEND);
    assign consumer_fault_seq = held_seq;
    assign consumer_idle = (state == IDLE);
    function [31:0] sat_inc;
        input [31:0] x;
        begin sat_inc = (x == 32'hffffffff) ? x : x + 1'b1; end
    endfunction

    always @(posedge adc_clk) begin
        if (!adc_resetn) begin
            state <= IDLE; held_seq <= 0; consumer_mode_active <= 0;
            consumer_mode_ack <= 0; consumer_mode_granted <= 0;
            ps_reject_ack <= 0; fine_release_ack <= 0;
            fine_release_granted <= 0; fine_release_seq <= 0;
            protocol_error_count <= 0;
        end else if(ENABLE_MAINTENANCE && maintenance_clear) begin
            state<=IDLE;held_seq<=0;consumer_mode_active<=0;
            consumer_mode_ack<=0;consumer_mode_granted<=0;
            ps_reject_ack<=0;fine_release_ack<=0;fine_release_granted<=0;
        end else begin
            consumer_mode_ack <= consumer_mode_valid;
            consumer_mode_granted <= 0;
            ps_reject_ack <= ps_release_valid && consumer_mode_active;
            fine_release_ack <= 0;
            fine_release_granted <= 0;
            // Even an IDLE-edge candidate wins over a simultaneous mode write.
            // No unclaimed frozen window or unsettled release can change mode.
            if (consumer_mode_valid) begin
                if (!manager_active && !copy_busy && !candidate_arriving &&
                    (state == IDLE) && !fine_busy && !fine_rd_valid &&
                    !fine_rd_req && !ps_release_valid) begin
                    consumer_mode_active <= consumer_mode;
                    consumer_mode_granted <= 1;
                end else protocol_error_count <= sat_inc(protocol_error_count);
            end
            if ((ps_release_valid && consumer_mode_active) ||
                ((fine_done || fine_fault) &&
                 ((state != READING) || fine_seq != held_seq)))
                protocol_error_count <= sat_inc(protocol_error_count);
            case (state)
                IDLE: if (window_offer_valid && window_offer_ready) begin
                    held_seq <= active_seq;
                    state <= READING;
                end
                READING: begin
                    if (fine_fault && fine_seq == held_seq) state <= FAULT_DRAIN;
                    else if (fine_done && fine_seq == held_seq) begin
                        if (fine_result_latched && !fine_busy &&
                            !fine_rd_req && !fine_rd_valid) state <= RETIRE;
                        else protocol_error_count <= sat_inc(protocol_error_count);
                    end
                end
                RETIRE: if (retire_ack && !fine_busy && !fine_rd_req &&
                            !fine_rd_valid) state <= RELEASE;
                RELEASE: state <= ACK_WAIT;
                ACK_WAIT: if (manager_release_ack) begin
                    fine_release_ack <= 1;
                    fine_release_granted <= manager_release_granted;
                    fine_release_seq <= held_seq;
                    if (manager_release_granted) state <= IDLE;
                    else begin
                        protocol_error_count <= sat_inc(protocol_error_count);
                        state <= FAULT_DRAIN;
                    end
                end
                FAULT_DRAIN: if (retire_ack && !fine_busy && !fine_rd_valid)
                    state <= FAULT_SEND;
                FAULT_SEND: state <= FAULT_WAIT;
                // Only Manager's independent matched CLEAR_FAULT can free this.
                FAULT_WAIT: if (!manager_active && !copy_busy) state <= IDLE;
                default: state <= FAULT_DRAIN;
            endcase
        end
    end
endmodule
