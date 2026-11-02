`timescale 1ns/1ps
module baud_lane #(parameter integer BAUD=9600)(output reg done=0);
    localparam integer CPB=125000000/BAUD;
    localparam realtime NOMINAL_BIT_NS=1.0e9/BAUD;
    localparam realtime ACTUAL_TX_BIT_NS=CPB*8.0;
    reg clk=0,rst=1,rx=1;
    wire tx;
    string line="";
    integer checks=0;
    hil20_uart_control #(.CLOCK_HZ(125000000),.BAUD_RATE(BAUD),.LINE_TIMEOUT_CYCLES(CPB*30)) dut(
        .clk(clk),.rst(rst),.key0_press(1'b0),.key1_press(1'b0),.uart_rx(rx),.uart_link_up(1'b1),
        .uart_tx(tx),.mode_index(),.frequency_word(),.phase_offset_word(),.amplitude(),.wave_sel(),
        .output_enable(),.restart_pulse(),.control_busy(),.dropped_reply_count(),.key_overflow(),.reply_busy());
    always #4 clk=~clk;
    task send_byte(input [7:0] b);
        integer k;begin rx=0;#(NOMINAL_BIT_NS);for(k=0;k<8;k++)begin rx=b[k];#(NOMINAL_BIT_NS);end rx=1;#(NOMINAL_BIT_NS);end
    endtask
    initial begin
        repeat(8)@(negedge clk);rst=0;#1.3;
        send_byte("S");send_byte("T");send_byte("A");send_byte("T");send_byte("U");send_byte("S");send_byte("?");send_byte(8'h0d);send_byte(8'h0a);
    end
    initial forever begin : monitor
        reg [7:0] b;
        integer k;
        @(negedge tx);#(ACTUAL_TX_BIT_NS*1.5);
        for(k=0;k<8;k++)begin b[k]=tx;#(ACTUAL_TX_BIT_NS);end
        if(tx!==1'b1)$fatal(1,"BAUD_BAD_STOP %0d",BAUD);
        line={line,$sformatf("%c",b)};checks++;
        if(b==8'h0a)begin
            if(line!="STATUS MODE=00 FREQ=01M ANGLE=+00 OUTPUT=0\015\n")$fatal(1,"BAUD_REPLY_MISMATCH %0d [%s]",BAUD,line);
            $display("UART_BAUD_PASS baud=%0d cpb=%0d bytes=%0d tx_actual_baud=%f",BAUD,CPB,checks,125000000.0/CPB);
            done=1;
        end
    end
endmodule
module tb_hil20_baud;
    wire a,b,c;
    baud_lane #(.BAUD(9600)) l0(a);
    baud_lane #(.BAUD(38400)) l1(b);
    baud_lane #(.BAUD(115200)) l2(c);
    initial begin #200000000;$fatal(1,"BAUD_TIMEOUT");end
    initial begin wait(a&&b&&c);$display("UART_BAUD_ALL_PASS lanes=3");$finish;end
endmodule
