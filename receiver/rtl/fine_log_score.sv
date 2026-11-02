`timescale 1ns/1ps
// ln(raw unsigned score code), not log dB. U84 -> S35/F28.
// Mantissa U29/F28, 8192 linear segments, RNE; carries to exponent.
module fine_log_score #(parameter ROM_FILE="fine_ln_8193.mem") (
    input wire clk, resetn,
    input wire start_valid, output wire start_ready,
    input wire [83:0] score,
    output wire result_valid, input wire result_ready,
    output reg numeric_valid,
    output reg signed [34:0] logarithm,
    output reg [6:0] exponent
);
    localparam IDLE=0,NORMALIZE=1,ROM_READ=2,MULTIPLY=3,ADD=4,RESULT=5;
    localparam [28:0] LN2_Q=29'd186065279;
    reg [2:0] state;
    reg [83:0] raw;
    reg [28:0] mantissa;
    (* rom_style="block" *) reg [28:0] lut [0:8192];
    initial $readmemh(ROM_FILE,lut);
    reg [28:0] left,right;
    reg [14:0] fraction;
    reg [43:0] product;
    reg [35:0] exponent_term;
    integer e,shift,b;
    reg [84:0] m,mask,rem_bits,half;
    always @* begin
        e=0;
        for(b=0;b<84;b=b+1) if(raw[b]) e=b;
        m=0; mask=0; rem_bits=0; half=0; shift=0;
        if(e>28) begin
            shift=e-28; m={1'b0,raw}>>shift;
            mask=(85'd1<<shift)-1'b1; rem_bits={1'b0,raw}&mask; half=85'd1<<(shift-1);
            if(rem_bits>half || (rem_bits==half && m[0])) m=m+1'b1;
        end else m={1'b0,raw}<<(28-e);
        if(m==85'h20000000) begin m=m>>1; e=e+1; end
    end
    wire [12:0] address=mantissa[27:15];
    wire [13:0] next_address={1'b0,address}+14'd1;
    wire [29:0] interpolated=(product>>15)+
        ((product[14:0]>15'h4000 || (product[14:0]==15'h4000 && product[15])) ? 30'd1 : 30'd0);
    wire [36:0] final_log={1'b0,exponent_term}+{8'b0,left}+{7'b0,interpolated};
    assign start_ready=state==IDLE;
    assign result_valid=state==RESULT;
    always @(posedge clk) begin
        if(!resetn) begin state<=IDLE; numeric_valid<=0; logarithm<=0; exponent<=0; raw<=0; end
        else case(state)
            IDLE: if(start_valid) begin
                raw<=score; numeric_valid<=score!=0; logarithm<=0; exponent<=0;
                state<=score==0 ? RESULT : NORMALIZE;
            end
            NORMALIZE: begin mantissa<=m[28:0]; exponent<=e[6:0]; state<=ROM_READ; end
            ROM_READ: begin left<=lut[address]; right<=lut[next_address];
                fraction<=mantissa[14:0]; state<=MULTIPLY; end
            MULTIPLY: begin product<=(right-left)*fraction;
                exponent_term<=exponent*LN2_Q; state<=ADD; end
            ADD: begin logarithm<=final_log[34:0]; state<=RESULT; end
            RESULT: if(result_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
