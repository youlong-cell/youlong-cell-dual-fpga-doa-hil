`timescale 1ns/1ps
// Single clock 8N1 receiver. BAUD must be explicitly selected for each build.
module hil_uart_rx #(parameter integer CLOCK_HZ=125000000, BAUD_RATE=0)(
    input wire clk,rst,rx_pin,
    output reg [7:0] rx_byte, output reg rx_valid,frame_error
);
    localparam integer CPB=(BAUD_RATE>0)?CLOCK_HZ/BAUD_RATE:0;
    localparam integer CW=(CPB>1)?$clog2(CPB):1;
    localparam [2:0] IDLE=0,START=1,DATA=2,STOP=3,RECOVER=4;
    (* ASYNC_REG="TRUE" *) reg rx_meta,rx_sync;
    reg [2:0] state,bit_index;
    reg [CW-1:0] count;
    reg [7:0] shift;
    initial if(BAUD_RATE<=0 || CLOCK_HZ<=0 || CPB<8)
        $fatal(1,"UART_RX_INVALID_PARAMETERS");
    always @(posedge clk) begin
        if(rst)begin rx_meta<=1;rx_sync<=1;end
        else begin rx_meta<=rx_pin;rx_sync<=rx_meta;end
    end
    always @(posedge clk) begin
        if(rst)begin state<=IDLE;count<=0;bit_index<=0;shift<=0;rx_byte<=0;rx_valid<=0;frame_error<=0;end
        else begin
            rx_valid<=0;frame_error<=0;
            case(state)
                IDLE:if(!rx_sync)begin state<=START;count<=CPB/2-1;end
                START:if(count!=0)count<=count-1'b1;
                    else if(!rx_sync)begin state<=DATA;count<=CPB-1;bit_index<=0;end
                    else state<=IDLE;
                DATA:if(count!=0)count<=count-1'b1;
                    else begin
                        shift[bit_index]<=rx_sync;count<=CPB-1;
                        if(bit_index==7)state<=STOP;else bit_index<=bit_index+1'b1;
                    end
                STOP:if(count!=0)count<=count-1'b1;
                    else if(rx_sync)begin rx_byte<=shift;rx_valid<=1;state<=IDLE;end
                    else begin frame_error<=1;state<=RECOVER;count<=CPB-1;end
                // A stuck-low break cannot synthesize a stream of zero bytes.
                RECOVER:if(!rx_sync)count<=CPB-1;
                    else if(count!=0)count<=count-1'b1;else state<=IDLE;
                default:begin state<=RECOVER;count<=CPB-1;frame_error<=1;end
            endcase
        end
    end
endmodule
