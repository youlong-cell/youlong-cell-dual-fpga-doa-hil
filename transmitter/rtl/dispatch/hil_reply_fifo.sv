`timescale 1ns/1ps
// 本域10-bit描述符FIFO：组合front/同拍push+pop，与原数组逐周期相同。
// admission/reservation由scheduler独占，不在本层增加满/空门控或pipeline。
module hil_reply_fifo #(parameter integer DEPTH=4,WIDTH=10)(
    input wire clk,rst,push,pop,input wire [WIDTH-1:0] push_data,
    output wire [WIDTH-1:0] front,
    output reg [((DEPTH>1)?$clog2(DEPTH):1):0] count
);
    localparam integer PW=(DEPTH>1)?$clog2(DEPTH):1;
    reg [WIDTH-1:0] queue[0:DEPTH-1];
    reg [PW-1:0] write_ptr,read_ptr;
    assign front=queue[read_ptr];
    initial if(DEPTH<2 || (1<<PW)!=DEPTH)$fatal(1,"INVALID_REPLY_DEPTH");
    always @(posedge clk)begin
        if(rst)begin write_ptr<=0;read_ptr<=0;count<=0;end
        else begin
            if(push)begin queue[write_ptr]<=push_data;write_ptr<=write_ptr+1'b1;end
            if(pop)read_ptr<=read_ptr+1'b1;
            case({push,pop})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:begin end
            endcase
        end
    end
endmodule
