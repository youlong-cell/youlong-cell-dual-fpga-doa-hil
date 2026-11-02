`timescale 1ns/1ps
// Shared, positive-frequency e^(-j*phase) NCO, adc_clk domain only.
// 48-bit turns; 14-bit ROM address + all 34 residual bits interpolated.
// Table word = {S22/F20 cosine, S22/F20 NEGATIVE sine}. No vendor IP.
module fine_shared_nco #(
    parameter ROM_FILE = "fine_nco_16384.mem"
) (
    input wire clk, input wire resetn,
    input wire req, input wire [47:0] phase,
    output reg valid,
    output reg signed [21:0] cosine,
    output reg signed [21:0] neg_sine
);
    (* rom_style = "block" *) reg [43:0] table_mem [0:16383];
    initial $readmemh(ROM_FILE, table_mem);
    reg [43:0] a, b;
    reg [33:0] fraction;
    reg signed [21:0] base_c, base_s;
    reg signed [57:0] product_c, product_s;
    reg v1, v2;
    wire [13:0] addr = phase[47:34];
    wire [13:0] addr_next = addr + 14'd1;
    wire signed [22:0] diff_c = $signed({b[43], b[43:22]}) -
                               $signed({a[43], a[43:22]});
    wire signed [22:0] diff_s = $signed({b[21], b[21:0]}) -
                               $signed({a[21], a[21:0]});
    wire signed [34:0] frac_signed = $signed({1'b0, fraction});
    function automatic signed [63:0] rne34(input signed [63:0] x);
        reg [63:0] mag, q;
        begin
            mag = x < 0 ? $unsigned(-x) : $unsigned(x);
            q = mag >> 34;
            if (mag[33:0] > 34'h200000000 ||
                (mag[33:0] == 34'h200000000 && q[0])) q = q + 64'd1;
            rne34 = x < 0 ? -$signed(q) : $signed(q);
        end
    endfunction
    wire signed [63:0] interp_c = $signed(base_c) + rne34(product_c);
    wire signed [63:0] interp_s = $signed(base_s) + rne34(product_s);
    // Two synchronous ROM addresses, no reset of the ROM/data path.
    always @(posedge clk) if (req) begin
        a <= table_mem[addr]; b <= table_mem[addr_next];
        fraction <= phase[33:0];
    end
    always @(posedge clk) begin
        if (!resetn) begin v1 <= 0; v2 <= 0; valid <= 0; end
        else begin
            v1 <= req; v2 <= v1; valid <= v2;
            if (v1) begin
                base_c <= $signed(a[43:22]); base_s <= $signed(a[21:0]);
                product_c <= diff_c * frac_signed;
                product_s <= diff_s * frac_signed;
            end
            if (v2) begin
                cosine <= interp_c[21:0]; neg_sine <= interp_s[21:0];
            end
        end
    end
endmodule
