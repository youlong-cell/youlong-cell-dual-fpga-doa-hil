`timescale 1ns/1ps
// U84 raw score -> S36/F28 log2. Exponent is exact, NOT e*rounded ln(2).
// RNE mantissa F28; 8192 linear LUT segments; RNE interpolation.
// Same synchronous clk/reset domain, held result handshake. No vendor IP.
module fine_log2_score #(parameter ROM_FILE="fine_log2_8193.mem") (
    input wire clk,resetn,
    input wire start_valid,output wire start_ready,input wire [83:0] score,
    output wire result_valid,input wire result_ready,
    output reg numeric_valid,output reg signed [35:0] logarithm,
    output reg [6:0] exponent
);
    localparam IDLE=0,NORMALIZE=1,ROM_READ=2,MULTIPLY=3,ADD=4,RESULT=5;
    reg [2:0] state; reg [83:0] raw; reg [28:0] mantissa;
    (* rom_style="block" *) reg [28:0] lut[0:8192];
    initial $readmemh(ROM_FILE,lut);
    reg [28:0] left,right; reg [14:0] fraction; reg [43:0] product;
    // L0 only: same NORMALIZE cycle, full U84 input and unchanged RNE/carry.
    wire [83:0] low_or;
    assign low_or[0]=raw[0];
    genvar k;
    generate for(k=1;k<84;k=k+1) begin : g_prefix
        assign low_or[k]=low_or[k-1] | raw[k];
    end endgenerate
    integer e,shift,b;
    reg [84:0] m;
    reg [28:0] quotient;
    reg [29:0] rounded;
    reg guard_bit,sticky_bit;
    always @* begin
        e=0; for(b=0;b<84;b=b+1) if(raw[b]) e=b;
        m=0; shift=0; quotient=0; rounded=0; guard_bit=0; sticky_bit=0;
        if(e>28) begin
            shift=e-28;
            quotient=raw>>shift;
            guard_bit=raw[shift-1];
            if(shift>1) sticky_bit=low_or[shift-2];
            rounded={1'b0,quotient}+{{29{1'b0}},
                (guard_bit && (sticky_bit || quotient[0]))};
            m={55'd0,rounded};
        end else m={1'b0,raw}<<(28-e);
        if(m==85'h20000000) begin m=m>>1; e=e+1; end
    end
    wire [12:0] address=mantissa[27:15];
    wire [13:0] next_address={1'b0,address}+14'd1;
    wire [29:0] interpolated=(product>>15)+
        ((product[14:0]>15'h4000 || (product[14:0]==15'h4000 && product[15])) ? 30'd1 : 30'd0);
    wire [35:0] exponent_term={1'b0,exponent,28'b0};
    wire [36:0] final_log={1'b0,exponent_term}+{8'b0,left}+{7'b0,interpolated};
    assign start_ready=state==IDLE; assign result_valid=state==RESULT;
    always @(posedge clk) begin
        if(!resetn) begin state<=IDLE; raw<=0; numeric_valid<=0; logarithm<=0; exponent<=0;
            mantissa<=0; left<=0; right<=0; fraction<=0; product<=0; end
        else case(state)
            IDLE: if(start_valid) begin
                raw<=score; numeric_valid<=score!=0; logarithm<=0; exponent<=0;
                state<=score==0 ? RESULT : NORMALIZE;
            end
            NORMALIZE: begin mantissa<=m[28:0]; exponent<=e[6:0]; state<=ROM_READ; end
            ROM_READ: begin left<=lut[address]; right<=lut[next_address]; fraction<=mantissa[14:0]; state<=MULTIPLY; end
            MULTIPLY: begin product<=(right-left)*fraction; state<=ADD; end
            ADD: begin logarithm<=$signed(final_log[35:0]); state<=RESULT; end
            RESULT: if(result_ready) state<=IDLE;
            default: begin numeric_valid<=0; logarithm<=0; state<=RESULT; end
        endcase
    end
endmodule
