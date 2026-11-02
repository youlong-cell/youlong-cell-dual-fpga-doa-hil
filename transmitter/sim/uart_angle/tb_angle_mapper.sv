`timescale 1ns/1ps
module tb_angle_mapper;
    reg clk=0,rst=1,start=0;
    reg [1:0] fi=0;
    reg signed [10:0] angle=0;
    wire valid;
    wire [31:0] fw;
    wire signed [31:0] pw;
    integer fd,rc,f,a,expected,checks=0;
    hil_angle_mapper dut(.clk(clk),.rst(rst),.start(start),.frequency_index(fi),
        .angle_tenths(angle),.valid(valid),.frequency_word(fw),.phase_word(pw));
    always #4 clk=~clk;
    initial begin #10000000;$fatal(1,"ANGLE_MAPPER_TIMEOUT");end
    initial begin
        repeat(4)@(negedge clk);rst=0;
        fd=$fopen("angle_golden_vectors.txt","r");if(!fd)$fatal(1,"MISSING_GOLDEN");
        while(!$feof(fd))begin
            rc=$fscanf(fd,"%h %h %h\n",f,a,expected);
            if(rc!=3)$fatal(1,"BAD_GOLDEN_RECORD");
            @(negedge clk);fi=f;angle=a;start=1;
            @(negedge clk);start=0;
            @(negedge clk);
            if(!valid || pw!==expected)$fatal(1,"ANGLE_WORD_FAIL f=%0d a=%0d got=%08x want=%08x valid=%b",f,$signed(angle),pw,expected,valid);
            case(f)
                0:if(fw!==32'h020c49ba)$fatal(1,"FW_1M");
                1:if(fw!==32'h04189375)$fatal(1,"FW_2M");
                2:if(fw!==32'h0a3d70a4)$fatal(1,"FW_5M");
                3:if(fw!==32'h147ae148)$fatal(1,"FW_10M");
            endcase
            checks=checks+1;
        end
        $fclose(fd);
        if(checks!=7204)$fatal(1,"INSUFFICIENT_MAPPER_COVERAGE");
        // Full throughput: unrelated signs and frequencies on adjacent sampled edges.
        @(negedge clk);fi=2;angle=400;start=1;
        @(negedge clk);fi=0;angle=-400;
        @(negedge clk);if(!valid || fw!==32'h0a3d70a4 || pw<=0)$fatal(1,"PIPELINE_FIRST");start=0;
        @(negedge clk);if(!valid || fw!==32'h020c49ba || pw>=0)$fatal(1,"PIPELINE_SECOND");
        @(negedge clk);rst=1;start=1;
        @(negedge clk);start=0;rst=0;
        repeat(3)@(negedge clk);if(valid)$fatal(1,"RESET_REPLAY");
        $display("ANGLE_MAPPER_PASS vectors=%0d failures=0",checks);$finish;
    end
endmodule
