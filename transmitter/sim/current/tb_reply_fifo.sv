`timescale 1ns/1ps
module fifo_lane #(parameter integer DEPTH=4)(output reg done=0);
    localparam integer PW=$clog2(DEPTH);
    reg clk=0,rst=1,push=0,pop=0;
    reg [9:0] data=0;
    wire [9:0] front;
    wire [PW:0] count;
    reg [9:0] model[0:DEPTH-1];
    integer rd=0,wr=0,n=0,checks=0,both=0,wraps=0,empty_hits=0,full_hits=0,i,j;
    reg [31:0] prng=32'h13579bdf;
    hil_reply_fifo #(.DEPTH(DEPTH)) dut(.clk(clk),.rst(rst),.push(push),.pop(pop),.push_data(data),.front(front),.count(count));
    always #4 clk=~clk;
    task tick;
        begin
            @(posedge clk);
            if(rst)begin rd=0;wr=0;n=0;end
            else begin
                if(pop)rd=(rd+1)%DEPTH;
                if(push)begin model[wr]=data;wr=(wr+1)%DEPTH;if(wr==0)wraps++;end
                n=n+integer'(push)-integer'(pop);
                if(push&&pop)both++;
            end
            #0.1;checks++;
            if(count!==n)$fatal(1,"FIFO_COUNT depth=%0d",DEPTH);
            if(n>0 && front!==model[rd])$fatal(1,"FIFO_DATA depth=%0d",DEPTH);
            if(n==0)empty_hits++;
            if(n==DEPTH)full_hits++;
            @(negedge clk);
        end
    endtask
    initial begin
        repeat(4)tick();rst=0;
        for(j=0;j<20;j++)begin
            pop=0;
            for(i=0;i<DEPTH;i++)begin push=1;data=i+j;tick();end
            push=1;pop=1;data=10'h3ff;tick();
            for(i=0;i<DEPTH;i++)begin push=0;pop=1;tick();end
        end
        pop=0;
        for(i=0;i<5000;i++)begin
            prng={prng[30:0],prng[31]^prng[21]^prng[1]^prng[0]};
            rst=(i%431==430);
            push=prng[0] && n<DEPTH;
            pop=prng[13] && n>0;
            data=prng[11:2];tick();
        end
        $display("FIFO_COVERAGE depth=%0d both=%0d wraps=%0d empty=%0d full=%0d",DEPTH,both,wraps,empty_hits,full_hits);
        if(both<100 || wraps<100 || empty_hits<10 || full_hits<10)$fatal(1,"FIFO_COVERAGE");
        $display("FIFO_LANE_PASS depth=%0d checks=%0d simultaneous=%0d wraps=%0d empty=%0d full=%0d",DEPTH,checks,both,wraps,empty_hits,full_hits);done=1;
    end
endmodule
module tb_reply_fifo;
    wire a,b,c;
    fifo_lane #(.DEPTH(2)) l0(a);
    fifo_lane #(.DEPTH(4)) l1(b);
    fifo_lane #(.DEPTH(8)) l2(c);
    initial begin #1000000;$fatal(1,"FIFO_TIMEOUT");end
    initial begin wait(a&&b&&c);$display("REFACTOR_FIFO_ALL_PASS failures=0");$finish;end
endmodule
