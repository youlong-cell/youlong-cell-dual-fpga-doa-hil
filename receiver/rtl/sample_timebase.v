`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// sample_timebase - the single owner of the ADC absolute sample timeline
//
// Frozen rule (see docs/DECISIONS.md D027):
//   The whole system has exactly ONE ADC absolute sample timeline. sample_tick
//   is the only event that advances it. The 48-bit absolute counter lives here
//   and nowhere else: the raw-sample ring and the FFT frame builder both
//   CONSUME it and must not maintain independent absolute sample counters.
//
// Sample-ID semantics (frozen; do not re-derive, an off-by-one here is fatal):
//   sample_id aliases next_sample_id. Ring and FFT both consume this PRE-EDGE
//   value on the same sample_tick edge. After that edge current_sample_id
//   records the committed ID and next_sample_id advances by one.
//   current_valid distinguishes reset from a committed sample with ID zero.
//
//     sample #0      -> sample_id = 0        ring addr = 0
//     sample #1      -> sample_id = 1        ring addr = 1
//     ...
//     sample #16383  -> sample_id = 16383    ring addr = 16383
//     sample #16384  -> sample_id = 16384    ring addr = 0   (natural wrap)
//
//   Frame convention on the same axis:
//     frame_start_id = first captured sample of the frame
//     frame_end_id   = frame_start_id + 1023
//     event_id       = frame_start_id + 512   (Hann window centre)
//
// Why an explicit tick instead of a hard-wired 1'b1 inside each module:
//   The AD9238 branch is synchronous - one registered CH0/CH1 pair per adc_clk,
//   with no sample-level backpressure and no invalid cycle - so the tick is
//   currently tied to 1'b1 at the instantiation site. Tying it inside every
//   consumer would work today but would hide the assumption. A later gated ADC
//   source must drive the SAME tick to this block, Ring and FFT frame capture;
//   changing only the timebase source is not sufficient.
//
// Instantiation (top level / integration):
//   // AD9238 continuously produces one registered sample per adc_clk.
//   // There is currently no sample-level backpressure or invalid cycle.
//   wire sample_tick = 1'b1;
//   sample_timebase u_sample_timebase (
//       .adc_clk     (adc_clk),
//       .adc_resetn  (adc_resetn),
//       .sample_tick (sample_tick),
//       .sample_id   (sample_id)
//   );
//
// Revision History:
// Date        Revision  Change Description
// ---------------------------------------------------------------------------
// 2026/09/28  1.0       Extracted the absolute sample counter out of the FFT
//                       controller and the ring into one shared timebase
// 2026/09/28  1.1       Exposed pre-edge next ID and post-edge committed ID
//////////////////////////////////////////////////////////////////////////////////
module sample_timebase #(
    // Non-zero only for wrap testing; the shipped configuration starts at 0.
    parameter [47:0] INITIAL_SAMPLE_ID = 48'd0
) (
    input  wire        adc_clk,
    input  wire        adc_resetn,    // synchronous, active low, ADC domain
    input  wire        sample_tick,   // 1 on every cycle carrying a new sample
    output wire [47:0] sample_id,     // pre-edge ID consumed by Ring and FFT
    output reg  [47:0] next_sample_id,
    output reg  [47:0] current_sample_id,
    output reg         current_valid
);

    assign sample_id = next_sample_id;

    always @(posedge adc_clk) begin
        if (!adc_resetn) begin
            next_sample_id    <= INITIAL_SAMPLE_ID;
            current_sample_id <= 48'd0;
            current_valid     <= 1'b0;
        end else if (sample_tick) begin
            current_sample_id <= next_sample_id;
            current_valid     <= 1'b1;
            next_sample_id    <= next_sample_id + 48'd1;
        end
    end

endmodule
