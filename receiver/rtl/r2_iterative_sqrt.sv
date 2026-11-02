`timescale 1ns/1ps
// Evaluation only: exact U48/F47 -> U48/F47 sqrt, single outstanding AXIS.
// N = input_code * 2^47. Two radicand bits per cycle, 48 iterations.
// No signed input exists on this interface. Invalid/negative radicands must
// be rejected BEFORE unsigned conversion, as in the production adapter.
module r2_iterative_sqrt(
 input wire aclk,aresetn,
 input wire s_axis_cartesian_tvalid,output wire s_axis_cartesian_tready,
 input wire [47:0] s_axis_cartesian_tdata,
 output wire m_axis_dout_tvalid,input wire m_axis_dout_tready,
 output reg [47:0] m_axis_dout_tdata
);
 localparam [1:0] IDLE=0,ITERATE=1,ROUND=2,HOLD=3;
 reg [1:0] state;
 reg [5:0] count;
 reg [95:0] radicand;
 reg [49:0] remainder;
 reg [47:0] root;
 wire [51:0] shifted={remainder,radicand[95:94]};
 wire [51:0] trial={2'b0,root,2'b01};
 wire [52:0] difference={1'b0,shifted}-{1'b0,trial};
 wire fits=!difference[52];
 wire [47:0] next_root={root[46:0],fits};
 // N-q^2 is integer. sqrt(N)>q+1/2 iff remainder>q.
 // Exact ties require N=q^2+q+1/4 and cannot occur for integer N.
 wire round_up=remainder>{2'b0,root};
 assign s_axis_cartesian_tready=aresetn && state==IDLE;
 assign m_axis_dout_tvalid=aresetn && state==HOLD;
 always @(posedge aclk)begin
  if(!aresetn)begin
   state<=IDLE;count<=0;radicand<=0;remainder<=0;root<=0;m_axis_dout_tdata<=0;
  end else case(state)
   IDLE:if(s_axis_cartesian_tvalid && s_axis_cartesian_tready)begin
    radicand<={1'b0,s_axis_cartesian_tdata,47'b0};
    remainder<=0;root<=0;count<=0;state<=ITERATE;
   end
   ITERATE:begin
    radicand<={radicand[93:0],2'b0};
    remainder<=fits ? difference[49:0] : shifted[49:0];
    root<=next_root;
    if(count==6'd47)state<=ROUND;else count<=count+6'd1;
   end
   ROUND:begin m_axis_dout_tdata<=root+{{47{1'b0}},round_up};state<=HOLD;end
   HOLD:if(m_axis_dout_tready)state<=IDLE;
   default:begin state<=IDLE;m_axis_dout_tdata<=0;end
  endcase
 end
endmodule
