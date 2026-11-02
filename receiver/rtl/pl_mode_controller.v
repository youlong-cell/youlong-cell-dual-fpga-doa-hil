`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// KEY1 synchronizer, debounce filter and six-state UI mode controller           //
//                                                                              //
// The module uses the same clock/reset as axi_gpio_mode. mode_state therefore   //
// reaches the GPIO input without another clock-domain crossing. One stable      //
// released-to-pressed transition advances the state and wraps at MODE_COUNT.    //
//////////////////////////////////////////////////////////////////////////////////
// Revision History:                                                            //
// Date        Revision  Change Description                                     //
// ---------------------------------------------------------------------------  //
// 2026/09/20  1.0       PL-owned key debounce and mode counter                 //
// 2026/09/20  1.1       Documented AXI GPIO clock-domain ownership             //
//////////////////////////////////////////////////////////////////////////////////
module pl_mode_controller #(
    parameter integer CLK_FREQ_HZ   = 99999001, // actual PL clock frequency
    parameter integer DEBOUNCE_MS   = 20,       // required stable interval
    parameter integer MODE_COUNT    = 6,        // ADC/WAVE/FULL/ZOOM views
    parameter integer COUNTER_WIDTH = 21        // must cover DEBOUNCE_CYCLES
) (
    input  wire       clk,        // axi_gpio_mode clock
    input  wire       resetn,     // synchronous reset, active low
    input  wire       key_n,      // asynchronous KEY1 input, active low
    output reg  [2:0] mode_state  // persistent mode value read by the PS
);

    localparam integer DEBOUNCE_CYCLES =
        (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
    // Two-stage synchronizer followed by a stable-time debounce counter.
    (* ASYNC_REG = "TRUE" *) reg key_sync1;
    (* ASYNC_REG = "TRUE" *) reg key_sync2;
    reg key_stable;
    reg [COUNTER_WIDTH-1:0] debounce_count;

    always @(posedge clk) begin
        if (!resetn) begin
            key_sync1     <= 1'b1;
            key_sync2     <= 1'b1;
            key_stable    <= 1'b1;
            debounce_count <= {COUNTER_WIDTH{1'b0}};
            mode_state    <= 3'd0;
        end else begin
            key_sync1 <= key_n;
            key_sync2 <= key_sync1;

            if (key_sync2 == key_stable) begin
                debounce_count <= {COUNTER_WIDTH{1'b0}};
            end else if (debounce_count == DEBOUNCE_CYCLES - 1) begin
                debounce_count <= {COUNTER_WIDTH{1'b0}};
                key_stable <= key_sync2;

                // Count only a stable released-to-pressed transition.
                if (key_stable && !key_sync2) begin
                    if (mode_state == MODE_COUNT - 1)
                        mode_state <= 3'd0;
                    else
                        mode_state <= mode_state + 3'd1;
                end
            end else begin
                debounce_count <= debounce_count + 1'b1;
            end
        end
    end

endmodule
