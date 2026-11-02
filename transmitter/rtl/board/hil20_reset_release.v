`timescale 1ns/1ps
// 保持旧逻辑：本域时钟沿采纳复位请求，三拍移位释放。
// 不是新增异步置位；停钟期间的行为不改变。
module hil20_reset_release(
    input wire clk,rst_n,pll_locked,output wire dac_rst
);
    reg [2:0] reset_pipe;
    always @(posedge clk) begin
        if (!rst_n || !pll_locked)
            reset_pipe <= 3'b111;
        else
            reset_pipe <= {reset_pipe[1:0],1'b0};
    end
    assign dac_rst=reset_pipe[2];
endmodule
