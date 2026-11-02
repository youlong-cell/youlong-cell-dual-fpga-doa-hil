`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// sample_window_copy - atomically freeze one dual-channel Ring window
//
// Control and Port A are in adc_clk; optional Port B is in axi_clk.
// A one-cycle registered Ring response is checked
// while the next absolute-ID request is issued. After the first request the
// copy can accept one sample per adc_clk, provided every preflight and echoed
// response remains valid. The default window has 4096 samples; WINDOW_BITS
// may be reduced for simulation.
// Production uses Port A for Copy write / frozen PL read, and Port B for
// PS debug read. These are TWO physical ports, not three RAM readers.
//
// A start is accepted only in IDLE. READY owns the immutable copy until
// release_candidate. candidate_valid is NEVER asserted for a partial copy.
// The RAM may contain partial/stale words after an abort, but its read port is
// disabled unless the entire window has committed successfully.
//
// Each Ring read is guarded using the last COMMITTED sample ID:
//   age = current_sample_id - requested_id (48-bit modular distance)
//   current_valid && !age[47] && age < min(RING_DEPTH, valid_entries)
//   && !(sample_tick && read_addr == next_write_addr)
// A registered Ring response must also be valid and echo the requested ID.
// The half-range future test assumes no request is more than 2^47 samples
// away from the current timeline, as is guaranteed for a live 16K Ring.
//
// Counters saturate rather than wrap. expired_count counts ONLY age/occupancy
// expiry; abort_count counts every failed copy. See docs/DECISIONS.md D028.
//////////////////////////////////////////////////////////////////////////////////
module sample_window_copy #(
    parameter integer RING_ADDR_BITS = 14,
    parameter integer WINDOW_BITS    = 12,
    // Production PS reader uses a separate AXI-clock RAM port. Existing
    // adc_clk-only tests retain their original read port by default.
    parameter integer USE_AXI_READ   = 0
) (
    input  wire                         adc_clk,
    input  wire                         adc_resetn,
    input  wire                         sample_tick,
    input  wire [47:0]                  next_sample_id,
    input  wire [47:0]                  current_sample_id,
    input  wire                         current_valid,
    input  wire [RING_ADDR_BITS:0]      ring_valid_entries,

    input  wire                         copy_start,
    input  wire                         cancel_copy,
    input  wire [47:0]                  copy_first_sample_id,
    input  wire                         release_candidate,
    output wire                         copy_busy,
    output reg                          copy_done,
    output reg                          copy_abort,
    output reg                          candidate_valid,
    output reg  [47:0]                  candidate_first_sample_id,
    output reg  [2:0]                   abort_reason,
    output reg  [31:0]                  abort_count,
    output reg  [31:0]                  no_history_count,
    output reg  [31:0]                  future_count,
    output reg  [31:0]                  expired_count,
    output reg  [31:0]                  collision_count,
    output reg  [31:0]                  not_ready_count,
    output reg  [31:0]                  protocol_count,
    output reg  [31:0]                  copy_progress,

    output wire                         ring_rd_req,
    output wire [47:0]                  ring_rd_sample_id,
    input  wire                         ring_rd_valid,
    input  wire [47:0]                  ring_rd_return_id,
    input  wire [31:0]                  ring_rd_data,
    input  wire                         ring_rd_expired,
    input  wire                         ring_rd_collision,
    input  wire                         ring_rd_not_ready,
    input  wire                         ring_rd_invalid,

    input  wire                         window_rd_req,
    input  wire [WINDOW_BITS-1:0]       window_rd_addr,
    output reg                          window_rd_valid,
    output wire [31:0]                  window_rd_data,
    output reg  [WINDOW_BITS-1:0]       window_rd_index,
    input  wire                         axi_clk,
    input  wire                         axi_window_rd_req,
    input  wire [WINDOW_BITS-1:0]       axi_window_rd_addr,
    output reg                          axi_window_rd_valid,
    output reg  [31:0]                  axi_window_rd_data
);
    localparam integer RING_DEPTH = (1 << RING_ADDR_BITS);
    localparam integer WINDOW_DEPTH = (1 << WINDOW_BITS);
    localparam [47:0] RING_DEPTH_48 = RING_DEPTH;

    localparam [2:0] REASON_NONE       = 3'd0;
    localparam [2:0] REASON_NO_HISTORY = 3'd1;
    localparam [2:0] REASON_FUTURE     = 3'd2;
    localparam [2:0] REASON_EXPIRED    = 3'd3;
    localparam [2:0] REASON_COLLISION  = 3'd4;
    localparam [2:0] REASON_NOT_READY  = 3'd5;
    localparam [2:0] REASON_PROTOCOL   = 3'd6;

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_COPY  = 3'd1;
    localparam [2:0] ST_READY = 3'd3;
    localparam [2:0] ST_ABORT = 3'd4;

    (* ram_style = "block" *) reg [31:0] window_mem [0:WINDOW_DEPTH-1];
    reg [2:0] state;
    reg [WINDOW_BITS-1:0] issue_index;
    reg [WINDOW_BITS-1:0] pending_index;
    reg pending_valid;
    reg all_issued;
    reg [47:0] active_first_id;
    reg [47:0] pending_id;

    wire [47:0] request_id = active_first_id +
                             {{(48-WINDOW_BITS){1'b0}}, issue_index};
    wire [47:0] age = current_sample_id - request_id;
    wire write_collision = sample_tick &&
                           (request_id[RING_ADDR_BITS-1:0] ==
                            next_sample_id[RING_ADDR_BITS-1:0]);

    reg [2:0] pre_reason;
    always @* begin
        if (!current_valid)
            pre_reason = REASON_NO_HISTORY;
        else if (age[47])
            pre_reason = REASON_FUTURE;
        else if ((age >= RING_DEPTH_48) || (age >= ring_valid_entries))
            pre_reason = REASON_EXPIRED;
        else if (write_collision)
            pre_reason = REASON_COLLISION;
        else
            pre_reason = REASON_NONE;
    end

    wire [4:0] response_flags = {ring_rd_invalid, ring_rd_not_ready,
                                 ring_rd_collision, ring_rd_expired,
                                 ring_rd_valid};
    reg [2:0] response_reason;
    always @* begin
        if (ring_rd_return_id != pending_id)
            response_reason = REASON_PROTOCOL;
        else begin
            case (response_flags)
                5'b00001: response_reason = REASON_NONE;
                5'b00010: response_reason = REASON_EXPIRED;
                5'b00100: response_reason = REASON_COLLISION;
                5'b01000: response_reason = REASON_NOT_READY;
                5'b10000: response_reason = REASON_FUTURE;
                default:  response_reason = REASON_PROTOCOL;
            endcase
        end
    end

    wire response_failed = pending_valid && (response_reason != REASON_NONE);
    wire request_failed = !all_issued && (pre_reason != REASON_NONE);
    // A failed response cancels the next request on the same edge. Never
    // permit an extra speculative Ring access after the copy is invalid.
    wire fail_now = (state == ST_COPY) &&
                    (response_failed || request_failed);
    wire [2:0] failure_reason = response_failed ? response_reason : pre_reason;

    assign ring_rd_req = (state == ST_COPY) && !cancel_copy && !all_issued &&
                         !response_failed && (pre_reason == REASON_NONE);
    assign ring_rd_sample_id = request_id;
    // READY still owns the only slot; a scheduler must not see it as free.
    assign copy_busy = (state != ST_IDLE);

    // Explicit single address mux for physical Port A. NO_CHANGE on write;
    // synchronous frozen reads have one-cycle latency and one-word/clock
    // throughput. No RAM reset and no second adc-domain RAM access block.
    wire port_a_write = adc_resetn && (state == ST_COPY) &&
                        pending_valid && !cancel_copy && !fail_now;
    wire port_a_read = adc_resetn && (state == ST_READY) &&
                       candidate_valid && !cancel_copy &&
                       !release_candidate && window_rd_req;
    wire [WINDOW_BITS-1:0] port_a_addr = port_a_write ?
                                       pending_index : window_rd_addr;
    reg [31:0] port_a_data;
    assign window_rd_data = port_a_data;
    always @(posedge adc_clk) begin
        if (port_a_write)
            window_mem[port_a_addr] <= ring_rd_data;
        else if (port_a_read)
            port_a_data <= window_mem[port_a_addr];
    end

    always @(posedge adc_clk) begin
        if (!adc_resetn) begin
            state                     <= ST_IDLE;
            issue_index               <= {WINDOW_BITS{1'b0}};
            pending_index             <= {WINDOW_BITS{1'b0}};
            pending_valid             <= 1'b0;
            all_issued                <= 1'b0;
            active_first_id           <= 48'd0;
            pending_id                <= 48'd0;
            copy_done                 <= 1'b0;
            copy_abort                <= 1'b0;
            candidate_valid           <= 1'b0;
            candidate_first_sample_id <= 48'd0;
            abort_reason              <= REASON_NONE;
            abort_count               <= 32'd0;
            no_history_count          <= 32'd0;
            future_count              <= 32'd0;
            expired_count             <= 32'd0;
            collision_count           <= 32'd0;
            not_ready_count           <= 32'd0;
            protocol_count            <= 32'd0;
            copy_progress             <= 32'd0;
            window_rd_valid           <= 1'b0;
            window_rd_index           <= {WINDOW_BITS{1'b0}};
        end else begin
            copy_done       <= 1'b0;
            copy_abort      <= 1'b0;
            window_rd_valid <= port_a_read;
            if (port_a_read) window_rd_index <= window_rd_addr;

            if (cancel_copy) begin
                // Manager timeout/consistency fault: stop issuing Ring reads,
                // invalidate partial RAM, and drain the registered response.
                candidate_valid <= 1'b0;
                pending_valid <= 1'b0;
                state <= ST_ABORT;
            end else if (fail_now) begin
                candidate_valid <= 1'b0;
                copy_abort      <= 1'b1;
                abort_reason    <= failure_reason;
                state           <= ST_ABORT;
                pending_valid   <= 1'b0;
                if (abort_count != 32'hffff_ffff)
                    abort_count <= abort_count + 1'b1;
                case (failure_reason)
                    REASON_NO_HISTORY: if (no_history_count != 32'hffff_ffff)
                        no_history_count <= no_history_count + 1'b1;
                    REASON_FUTURE: if (future_count != 32'hffff_ffff)
                        future_count <= future_count + 1'b1;
                    REASON_EXPIRED: if (expired_count != 32'hffff_ffff)
                        expired_count <= expired_count + 1'b1;
                    REASON_COLLISION: if (collision_count != 32'hffff_ffff)
                        collision_count <= collision_count + 1'b1;
                    REASON_NOT_READY: if (not_ready_count != 32'hffff_ffff)
                        not_ready_count <= not_ready_count + 1'b1;
                    default: if (protocol_count != 32'hffff_ffff)
                        protocol_count <= protocol_count + 1'b1;
                endcase
            end else begin
                case (state)
                    ST_IDLE: if (copy_start) begin
                        active_first_id           <= copy_first_sample_id;
                        candidate_first_sample_id <= copy_first_sample_id;
                        candidate_valid           <= 1'b0;
                        abort_reason              <= REASON_NONE;
                        issue_index               <= {WINDOW_BITS{1'b0}};
                        copy_progress             <= 32'd0;
                        pending_valid             <= 1'b0;
                        all_issued                <= 1'b0;
                        state                     <= ST_COPY;
                    end

                    ST_COPY: begin
                        // The previous edge's registered Ring result is
                        // consumed while this edge launches the next read.
                        if (pending_valid) begin
                            copy_progress <= copy_progress + 1'b1;
                        end
                        if (pending_valid && (pending_index == WINDOW_DEPTH-1)) begin
                            candidate_valid <= 1'b1;
                            copy_done       <= 1'b1;
                            state           <= ST_READY;
                        end
                        pending_valid <= ring_rd_req;
                        if (ring_rd_req) begin
                            pending_id    <= request_id;
                            pending_index <= issue_index;
                            if (issue_index == WINDOW_DEPTH-1)
                                all_issued <= 1'b1;
                            else
                                issue_index <= issue_index + 1'b1;
                        end
                    end

                    ST_READY: if (release_candidate) begin
                        candidate_valid <= 1'b0;
                        state           <= ST_IDLE;
                    end

                    ST_ABORT: state <= ST_IDLE;
                    default:  state <= ST_IDLE;
                endcase
            end
        end
    end
    generate if (USE_AXI_READ != 0) begin : g_axi_read
        // The bridge presents this port only after an atomic metadata
        // handshake declares the copy immutable. No multi-bit live Ring data
        // crosses clocks; this is the second port of a true dual-clock RAM.
        always @(posedge axi_clk) begin
            axi_window_rd_valid <= axi_window_rd_req;
            if (axi_window_rd_req)
                axi_window_rd_data <= window_mem[axi_window_rd_addr];
        end
    end else begin : g_no_axi_read
        always @* begin
            axi_window_rd_valid = 1'b0;
            axi_window_rd_data = 32'd0;
        end
    end endgenerate
endmodule
