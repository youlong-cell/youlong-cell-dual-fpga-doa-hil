`timescale 1ns/1ps
// 保留可选LINK两级同步器及本域取消语义；不新增跨域async reset。
module hil_uart_link #(parameter integer USE_LINK_STATUS=0)(
    input wire clk,rst,uart_link_up,output wire link_ok,serial_rst
);
    (* ASYNC_REG="TRUE" *) reg link_meta,link_sync;
    assign link_ok=USE_LINK_STATUS?link_sync:1'b1;
    assign serial_rst=rst || !link_ok;
    always @(posedge clk)begin
        if(rst)begin link_meta<=0;link_sync<=0;end
        else begin link_meta<=uart_link_up;link_sync<=link_meta;end
    end
endmodule
