`timescale 1ns/1ps
// adc_clk, synchronous active-low reset. Math stage ONLY, never releases a Window.
// X0/X1 are unnormalized S41/F16 DFT sums, using exp(-j*w*n).
// Z=X1*conj(X0); one full-circle vectoring CORDIC, not two channel atan2's.
module fine_cross_phase #(
    parameter ATAN_ROM_FILE="fine_atan_48.mem"
) (
    input wire clk,resetn,
    input wire start_valid,output wire start_ready,
    input wire [31:0] candidate_seq,
    input wire input_numeric_valid,input wire [7:0] input_status,
    input wire signed [40:0] i0,q0,i1,q1,
    input wire abort,output reg abort_ack,output wire busy,
    output wire result_valid,input wire result_ready,
    output reg [31:0] result_seq,
    output reg numeric_valid,output reg [7:0] status,
    output reg signed [35:0] phase_raw,
    output reg signed [82:0] cross_re,cross_im,
    output reg signed [39:0] norm_re,norm_im,
    output reg signed [7:0] normalization_shift,
    output wire fault_valid,output reg [7:0] fault_code,input wire fault_clear
);
    // phase_raw S36/F35 in units of pi: [-2^35,2^35), radians=code*pi/2^35.
    // 0 OK, 6 ZERO_CROSS (numeric invalid), 7 INVALID_UPSTREAM_STATUS.
    // Other upstream numeric-invalid statuses are passed through unchanged.
    localparam [3:0] IDLE=0,MULTIPLY=1,CROSS=2,NORMALIZE=3,
        ROTATE=4,ITERATE=5,ROUND=6,RESULT=7,FAULT=8,NORMALIZE_WAIT=9;
    localparam signed [63:0] PI_UNIT=64'sh1000000000000000;
    reg [3:0] state;
    reg signed [40:0] a0,b0,a1,b1;
    reg signed [81:0] rr,qq,qi,iq;
    reg signed [63:0] x,y,z;
    reg [5:0] iteration;
    reg signed [63:0] atan_rom[0:47];
    initial $readmemh(ATAN_ROM_FILE,atan_rom);
    assign start_ready=(state==IDLE) && !abort;
    assign result_valid=(state==RESULT) && !abort;
    assign fault_valid=state==FAULT;
    assign busy=state!=IDLE && state!=RESULT && state!=FAULT;

    // Explicitly widen BEFORE abs/add/subtract. No destination-width reliance.
    wire signed [82:0] real_full=$signed({rr[81],rr})+$signed({qq[81],qq});
    wire signed [82:0] imag_full=$signed({qi[81],qi})-$signed({iq[81],iq});
    wire signed [83:0] re_wide=$signed({cross_re[82],cross_re});
    wire signed [83:0] im_wide=$signed({cross_im[82],cross_im});
    wire [83:0] abs_re=re_wide<0 ? $unsigned(-re_wide) : $unsigned(re_wide);
    wire [83:0] abs_im=im_wide<0 ? $unsigned(-im_wide) : $unsigned(im_wide);
    wire [83:0] largest=abs_re>abs_im ? abs_re : abs_im;
    integer top_bit,norm_shift,bit_number;
    always @* begin
        top_bit=0;
        for(bit_number=0;bit_number<84;bit_number=bit_number+1)
            if(largest[bit_number]) top_bit=bit_number;
        norm_shift=top_bit-37; // COMMON shift; at least one magnitude in [.5,1].
    end

    wire signed [83:0] nr,ni;
    wire n_ready,n_valid,n_fit0,n_fit1;
    wire signed [7:0] n_shift;
    r3_dual_normalizer #(.STAGED(0)) normalizer (
        .clk(clk),.resetn(resetn),.abort(abort || state==FAULT),
        .start_valid(state==NORMALIZE && !abort),.start_ready(n_ready),
        .magnitude0(abs_re),.magnitude1(abs_im),.negative0(re_wide[83]),.negative1(im_wide[83]),
        .shift_count(norm_shift[7:0]),.result_valid(n_valid),
        .result_ready(state==NORMALIZE_WAIT && !abort),
        .normalized0(nr),.normalized1(ni),.fit0(n_fit0),.fit1(n_fit1),.result_shift(n_shift));
    // 64-bit / F60 work vector: widen first, then shift. Range +/-8 contains
    // sqrt(2)*CORDIC gain <2.33, so no saturating arithmetic is needed.
    wire signed [63:0] initial_x=$signed({{24{norm_re[39]}},norm_re})<<<22;
    wire signed [63:0] initial_y=$signed({{24{norm_im[39]}},norm_im})<<<22;
    wire signed [63:0] x_step=x>>>iteration;
    wire signed [63:0] y_step=y>>>iteration;
    wire signed [64:0] next_x=y>0 ?
        $signed({x[63],x})+$signed({y_step[63],y_step}) :
        $signed({x[63],x})-$signed({y_step[63],y_step});
    wire signed [64:0] next_y=y>0 ?
        $signed({y[63],y})-$signed({x_step[63],x_step}) :
        $signed({y[63],y})+$signed({x_step[63],x_step});
    function automatic signed [63:0] phase_rne(input signed [63:0] value);
        reg [63:0] magnitude,quotient;
        reg [24:0] remainder;
        begin
            magnitude=value<0 ? $unsigned(-value) : $unsigned(value);
            quotient=magnitude>>25; remainder=magnitude[24:0];
            if(remainder>25'h1000000 || (remainder==25'h1000000 && quotient[0])) quotient=quotient+64'd1;
            phase_rne=value<0 ? -$signed(quotient) : $signed(quotient);
        end
    endfunction
    wire signed [63:0] rounded_phase=phase_rne(z);
    always @(posedge clk) begin
        if(!resetn) begin
            state<=IDLE; a0<=0; b0<=0; a1<=0; b1<=0; rr<=0; qq<=0; qi<=0; iq<=0;
            x<=0; y<=0; z<=0; iteration<=0; abort_ack<=0; result_seq<=0;
            numeric_valid<=0; status<=7; phase_raw<=0; cross_re<=0; cross_im<=0;
            norm_re<=0; norm_im<=0; normalization_shift<=0; fault_code<=0;
        end else begin
            abort_ack<=0;
            // No memory/stream transaction in flight here. Cancellation is local.
            if(abort && state!=IDLE && state!=FAULT) begin
                state<=IDLE; abort_ack<=1; numeric_valid<=0; phase_raw<=0;
            end else case(state)
                IDLE: if(start_valid && start_ready) begin
                    result_seq<=candidate_seq; a0<=i0; b0<=q0; a1<=i1; b1<=q1;
                    numeric_valid<=0; phase_raw<=0; cross_re<=0; cross_im<=0;
                    norm_re<=0; norm_im<=0; normalization_shift<=0; fault_code<=0;
                    status<=0;
                    if(!input_numeric_valid) begin
                        status<=input_status==0 ? 8'd7 : input_status; state<=RESULT;
                    end else state<=MULTIPLY;
                end
                MULTIPLY: begin rr<=a1*a0; qq<=b1*b0; qi<=b1*a0; iq<=a1*b0; state<=CROSS; end
                CROSS: begin cross_re<=real_full; cross_im<=imag_full;
                    if(real_full==0 && imag_full==0) begin status<=6; state<=RESULT; end
                    else state<=NORMALIZE;
                end
                NORMALIZE: if(n_ready) state<=NORMALIZE_WAIT;
                NORMALIZE_WAIT: if(n_valid) begin
                    if(nr!=$signed({{44{nr[39]}},nr[39:0]}) ||
                       ni!=$signed({{44{ni[39]}},ni[39:0]})) begin
                        fault_code<=8'h30; state<=FAULT;
                    end else begin norm_re<=nr[39:0]; norm_im<=ni[39:0];
                        normalization_shift<=n_shift; state<=ROTATE; end
                end
                ROTATE: begin
                    // Coarse rotation handles the left half-plane, including
                    // the negative real axis. +pi is wrapped at final encoding.
                    x<=initial_x<0 ? -initial_x : initial_x;
                    y<=initial_x<0 ? -initial_y : initial_y;
                    z<=initial_x<0 ? (initial_y>=0 ? PI_UNIT : -PI_UNIT) : 64'sd0;
                    iteration<=0; state<=ITERATE;
                end
                ITERATE: begin
                    if(y!=0) begin
                        if(next_x[64]!=next_x[63] || next_y[64]!=next_y[63]) begin
                            fault_code<=8'h31; state<=FAULT;
                        end else begin
                            x<=next_x[63:0]; y<=next_y[63:0];
                            z<=y>0 ? z+atan_rom[iteration] : z-atan_rom[iteration];
                            if(iteration==47) state<=ROUND; else iteration<=iteration+6'd1;
                        end
                    end else if(iteration==47) state<=ROUND; else iteration<=iteration+6'd1;
                end
                ROUND: begin
                    // Modulo 2*pi encoding, including RNE values at +pi -> -pi.
                    phase_raw<=rounded_phase[35:0]; numeric_valid<=1; status<=0; state<=RESULT;
                end
                RESULT: if(result_ready) state<=IDLE;
                FAULT: if(fault_clear) begin state<=IDLE; fault_code<=0; end
                default: begin numeric_valid<=0; phase_raw<=0; fault_code<=8'h32; state<=FAULT; end
            endcase
        end
    end
endmodule

`timescale 1ns/1ps
// EVALUATION ONLY. Two parallel magnitude lanes; no numeric narrowing.
module r3_dual_normalizer #(parameter integer STAGED=0)(
 input wire clk,resetn,abort,input wire start_valid,output wire start_ready,
 input wire [83:0] magnitude0,magnitude1,input wire negative0,negative1,
 input wire signed [7:0] shift_count,
 output wire result_valid,input wire result_ready,
 output wire signed [83:0] normalized0,normalized1,
 output wire fit0,fit1,output reg signed [7:0] result_shift);
 localparam [1:0] IDLE=0,SHIFT=1,FINISH=2,HOLD=3;
 reg [1:0] state;
 reg [83:0] work_mag0,work_mag1;
 reg sign0,sign1,rightward,guard0,guard1,sticky0,sticky1;
 reg [6:0] remaining_shift;
 reg [2:0] stage;
 reg [83:0] step_mag0,step_mag1;
 reg step_guard0,step_guard1,step_sticky0,step_sticky1;
 assign start_ready=state==IDLE && !abort;
 assign result_valid=state==HOLD && !abort;
 wire inc0=rightward && guard0 && (sticky0 || work_mag0[0]);
 wire inc1=rightward && guard1 && (sticky1 || work_mag1[0]);
 wire [83:0] rounded0=work_mag0+{{83{1'b0}},inc0};
 wire [83:0] rounded1=work_mag1+{{83{1'b0}},inc1};
 assign normalized0=sign0 ? -$signed(rounded0) : $signed(rounded0);
 assign normalized1=sign1 ? -$signed(rounded1) : $signed(rounded1);
 assign fit0=normalized0==$signed({{44{normalized0[39]}},normalized0[39:0]});
 assign fit1=normalized1==$signed({{44{normalized1[39]}},normalized1[39:0]});
 generate if(STAGED==0) begin:g_one_bit
  always @* begin
   step_mag0=rightward ? {1'b0,work_mag0[83:1]} : {work_mag0[82:0],1'b0};
   step_mag1=rightward ? {1'b0,work_mag1[83:1]} : {work_mag1[82:0],1'b0};
   step_guard0=rightward ? work_mag0[0] : guard0;
   step_guard1=rightward ? work_mag1[0] : guard1;
   step_sticky0=rightward ? sticky0|guard0 : sticky0;
   step_sticky1=rightward ? sticky1|guard1 : sticky1;
  end
 end else begin:g_staged
  always @* begin
   step_mag0=work_mag0; step_mag1=work_mag1;
   step_guard0=guard0;step_guard1=guard1;
   step_sticky0=sticky0;step_sticky1=sticky1;
   // Fixed shifts only: no quotient return-shift, remainder subtract or half.
   case(stage)
    5: if(remaining_shift[5]) begin
     step_mag0=rightward ? work_mag0>>32 : work_mag0<<32;
     step_mag1=rightward ? work_mag1>>32 : work_mag1<<32;
     if(rightward) begin
      step_guard0=work_mag0[31];step_guard1=work_mag1[31];
      step_sticky0=sticky0|guard0|(|work_mag0[30:0]);
      step_sticky1=sticky1|guard1|(|work_mag1[30:0]);
     end
    end
    4: if(remaining_shift[4]) begin
     step_mag0=rightward ? work_mag0>>16 : work_mag0<<16;
     step_mag1=rightward ? work_mag1>>16 : work_mag1<<16;
     if(rightward) begin
      step_guard0=work_mag0[15];step_guard1=work_mag1[15];
      step_sticky0=sticky0|guard0|(|work_mag0[14:0]);
      step_sticky1=sticky1|guard1|(|work_mag1[14:0]);
     end
    end
    3: if(remaining_shift[3]) begin
     step_mag0=rightward ? work_mag0>>8 : work_mag0<<8;
     step_mag1=rightward ? work_mag1>>8 : work_mag1<<8;
     if(rightward) begin
      step_guard0=work_mag0[7];step_guard1=work_mag1[7];
      step_sticky0=sticky0|guard0|(|work_mag0[6:0]);
      step_sticky1=sticky1|guard1|(|work_mag1[6:0]);
     end
    end
    2: if(remaining_shift[2]) begin
     step_mag0=rightward ? work_mag0>>4 : work_mag0<<4;
     step_mag1=rightward ? work_mag1>>4 : work_mag1<<4;
     if(rightward) begin
      step_guard0=work_mag0[3];step_guard1=work_mag1[3];
      step_sticky0=sticky0|guard0|(|work_mag0[2:0]);
      step_sticky1=sticky1|guard1|(|work_mag1[2:0]);
     end
    end
    1: if(remaining_shift[1]) begin
     step_mag0=rightward ? work_mag0>>2 : work_mag0<<2;
     step_mag1=rightward ? work_mag1>>2 : work_mag1<<2;
     if(rightward) begin
      step_guard0=work_mag0[1];step_guard1=work_mag1[1];
      step_sticky0=sticky0|guard0|work_mag0[0];
      step_sticky1=sticky1|guard1|work_mag1[0];
     end
    end
    0: if(remaining_shift[0]) begin
     step_mag0=rightward ? work_mag0>>1 : work_mag0<<1;
     step_mag1=rightward ? work_mag1>>1 : work_mag1<<1;
     if(rightward) begin
      step_guard0=work_mag0[0];step_guard1=work_mag1[0];
      step_sticky0=sticky0|guard0;step_sticky1=sticky1|guard1;
     end
    end
    default:begin end
   endcase
  end
 end endgenerate
 always @(posedge clk) begin
  if(!resetn) begin
   state<=IDLE;work_mag0<=0;work_mag1<=0;sign0<=0;sign1<=0;
   rightward<=0;guard0<=0;guard1<=0;sticky0<=0;sticky1<=0;
   remaining_shift<=0;stage<=0;result_shift<=0;
  end else if(abort) begin state<=IDLE;guard0<=0;guard1<=0;sticky0<=0;sticky1<=0;end
  else case(state)
   IDLE:if(start_valid && start_ready) begin
    work_mag0<=magnitude0;work_mag1<=magnitude1;sign0<=negative0;sign1<=negative1;
    result_shift<=shift_count;rightward<=shift_count>0;
    remaining_shift<=shift_count<0 ? -shift_count : shift_count;
    stage<=5;guard0<=0;guard1<=0;sticky0<=0;sticky1<=0;
    state<=shift_count==0 ? FINISH : SHIFT;
   end
   SHIFT:begin
    work_mag0<=step_mag0;work_mag1<=step_mag1;
    guard0<=step_guard0;guard1<=step_guard1;sticky0<=step_sticky0;sticky1<=step_sticky1;
    if(STAGED==0) begin
     remaining_shift<=remaining_shift-7'd1;
     if(remaining_shift==1)state<=FINISH;
    end else if(stage==0)state<=FINISH;else stage<=stage-3'd1;
   end
   FINISH:state<=HOLD;
   HOLD:if(result_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
endmodule
