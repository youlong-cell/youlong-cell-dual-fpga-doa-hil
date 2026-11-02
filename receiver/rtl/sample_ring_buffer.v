`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// sample_ring_buffer - raw dual-channel ADC history, addressed by absolute ID
//
// Scope (deliberately minimal, no candidate slots):
//   1. write one dual-channel registered ADC pair per sample_tick
//   2. 2^ADDR_BITS natural address wrap
//   3. read back history by ABSOLUTE sample id, not by raw address
//
// Ownership (frozen rule, see docs/DECISIONS.md D027):
//   This module does NOT own a timeline. It consumes the system's single
//   absolute sample timeline (`sample_id`, the pre-edge alias of
//   `next_sample_id` from sample_timebase) and
//   derives its own write address from it. It counts only its own occupancy
//   (`valid_entries`), which is a local quantity, not an absolute ID.
//
//   The ring keeps no generation field in the RAM: the absolute id already
//   determines (generation, address) as
//       address    = sample_id[ADDR_BITS-1:0]
//       generation = sample_id[47:ADDR_BITS]
//   and the caller only ever holds absolute ids, so a descriptor never needs
//   to store a per-word generation.
//
// Read-result taxonomy (mutually exclusive, exactly one asserted per rd_req):
//   Let age = sample_id - rd_sample_id  (mod 2^48, i.e. "how old is the request")
//
//     age == 0                    -> rd_not_ready : it is the sample presented
//                                     on THIS cycle; it lands in the ring next
//                                     cycle. Retry one cycle later.
//     age[47]                     -> rd_invalid   : requested id is AHEAD of the
//                                     timeline, so it was never written. This is
//                                     a caller/logic fault, kept distinct from
//                                     eviction so that it cannot be silently
//                                     mistaken for normal ageing.
//     age > valid_entries         -> rd_expired   : already overwritten by a
//                                     newer lap; the data is NOT returned.
//     address collision           -> rd_collision : the requested word is the
//                                     boundary word (age == DEPTH) and is being
//                                     written on this very cycle.
//     otherwise                   -> rd_valid     : rd_data is authoritative.
//
//   age[47] is used as a sign bit of the modular distance. That is safe here
//   because the ring depth is 2^ADDR_BITS <= 2^14, which is far below 2^47.
//
//   This low-level age uses the NEXT ID, unlike the Copy engine's
//   `current_sample_id - rd_sample_id`. After a committed sample, the latter is
//   one less. The boundary word (this age == DEPTH) is deliberately reported
//   as VALID when no write is happening this cycle. It is physically still present, and its
//   address is exactly the next write address, so the only way it can be read
//   as stale data is the collision case above. Do NOT "simplify" this to
//   `age >= DEPTH -> expired`: that would discard one sample of usable history
//   and would no longer match the RTL.
//
//   No READ_FIRST/WRITE_FIRST/NO_CHANGE assumption is made anywhere: candidate
//   correctness never depends on BRAM collision behaviour.
//
// Clocking: all ports are adc_clk. A later copy engine may use a separate BRAM
// read clock only after its CDC/ownership contract is defined and verified.
//
// Revision History:
// Date        Revision  Change Description
// ---------------------------------------------------------------------------
// 2026/09/28  0.1       Provisional ring: write, natural wrap, absolute-id read
// 2026/09/28  0.2       Shared timebase: consume sample_id, rename adc_valid to
//                       sample_tick, drop the local absolute counter, split
//                       future-id requests out of rd_expired into rd_invalid
//////////////////////////////////////////////////////////////////////////////////
module sample_ring_buffer #(
    parameter integer ADDR_BITS = 14
) (
    input  wire               adc_clk,
    input  wire               adc_resetn,
    input  wire               sample_tick,   // 1 = a new sample is present
    input  wire [11:0]        adc_ch0,       // registered unsigned ADC code
    input  wire [11:0]        adc_ch1,       // registered unsigned ADC code
    input  wire [47:0]        sample_id,     // absolute id of THIS cycle's sample

    output reg  [ADDR_BITS:0] valid_entries, // local occupancy, saturates at DEPTH

    input  wire               rd_req,
    input  wire [47:0]        rd_sample_id,  // absolute id to read back
    output reg                rd_valid,
    output reg  [47:0]        rd_return_id,
    output reg  [31:0]        rd_data,       // {4'b0, ch1, 4'b0, ch0}
    output reg                rd_expired,
    output reg                rd_collision,
    output reg                rd_not_ready,
    output reg                rd_invalid
);
    localparam integer DEPTH = (1 << ADDR_BITS);
    localparam [ADDR_BITS:0] DEPTH_VALUE = DEPTH;

    (* ram_style = "block" *) reg [31:0] ring_mem [0:DEPTH-1];

    wire [ADDR_BITS-1:0] write_addr = sample_id[ADDR_BITS-1:0];
    wire [ADDR_BITS-1:0] read_addr  = rd_sample_id[ADDR_BITS-1:0];

    wire [47:0] age               = sample_id - rd_sample_id;
    wire        request_is_future = age[47];
    wire        read_is_current   = (age == 48'd0);
    wire        read_in_history   = !request_is_future &&
                                    !read_is_current &&
                                    (age <= valid_entries);
    wire        address_collision = sample_tick && (read_addr == write_addr);

    always @(posedge adc_clk) begin
        if (!adc_resetn) begin
            valid_entries <= {(ADDR_BITS+1){1'b0}};
            rd_valid      <= 1'b0;
            rd_return_id  <= 48'd0;
            rd_data       <= 32'd0;
            rd_expired    <= 1'b0;
            rd_collision  <= 1'b0;
            rd_not_ready  <= 1'b0;
            rd_invalid    <= 1'b0;
        end else begin
            rd_valid     <= 1'b0;
            rd_expired   <= 1'b0;
            rd_collision <= 1'b0;
            rd_not_ready <= 1'b0;
            rd_invalid   <= 1'b0;

            if (sample_tick) begin
                ring_mem[write_addr] <= {4'b0, adc_ch1, 4'b0, adc_ch0};
                if (valid_entries < DEPTH_VALUE)
                    valid_entries <= valid_entries + 1'b1;
            end

            if (rd_req) begin
                rd_return_id <= rd_sample_id;
                if (read_is_current) begin
                    rd_not_ready <= 1'b1;
                end else if (request_is_future) begin
                    rd_invalid <= 1'b1;
                end else if (!read_in_history) begin
                    rd_expired <= 1'b1;
                end else if (address_collision) begin
                    rd_collision <= 1'b1;
                end else begin
                    rd_data  <= ring_mem[read_addr];
                    rd_valid <= 1'b1;
                end
            end
        end
    end
endmodule
