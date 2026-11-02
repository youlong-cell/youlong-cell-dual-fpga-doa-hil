`timescale 1ns/1ps
module hil_uart_tx #(parameter integer CLOCK_HZ=125000000, BAUD_RATE=0)(
    input wire clk,rst,input wire [7:0] tx_byte,input wire tx_valid,
    output wire tx_ready,output reg tx_pin
);
    localparam integer CPB=(BAUD_RATE>0)?CLOCK_HZ/BAUD_RATE:0;
    localparam integer CW=(CPB>1)?$clog2(CPB):1;
    reg [CW-1:0] count;
    reg [9:0] shift;
    reg [3:0] left;
    assign tx_ready=(left==0);
    initial if(BAUD_RATE<=0 || CLOCK_HZ<=0 || CPB<8)$fatal(1,"UART_TX_INVALID_PARAMETERS");
    always @(posedge clk)begin
        if(rst)begin count<=0;shift<=10'h3ff;left<=0;tx_pin<=1;end
        else if(left==0)begin
            tx_pin<=1;
            if(tx_valid)begin shift<={1'b1,tx_byte,1'b0};tx_pin<=0;left<=10;count<=CPB-1;end
        end else if(count!=0)count<=count-1'b1;
        else begin
            count<=CPB-1;shift<={1'b1,shift[9:1]};left<=left-1'b1;tx_pin<=shift[1];
        end
    end
endmodule
