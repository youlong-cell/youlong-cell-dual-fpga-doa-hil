`timescale 1ns/1ps
module tb_fine_phase_calibration;
    reg clk=0; always #8 clk=~clk;
    reg resetn=0,wr=0,commit=0,start=0,pvalid=0,abort=0,ready=0,clear=0;
    reg [3:0] address=0;
    reg [31:0] wdata=0,seq=0,fs=62499374,pseq=0;
    reg pv=1; reg [7:0] ps=0;
    reg signed [35:0] raw=0;
    reg [48:0] freq=0;
    wire wr_ready,wr_error,commit_ready,commit_ack,sr,pr,ack,busy,rv,nv,cv,fault;
    wire [7:0] commit_status,status,calstatus,code;
    wire [31:0] generation,rseq,rgen,profile;
    wire signed [35:0] rraw,cal;
    wire [48:0] rfreq;
    fine_phase_calibration dut(.clk(clk),.resetn(resetn),.cfg_shadow_valid(wr),.cfg_shadow_ready(wr_ready),
        .cfg_shadow_addr(address),.cfg_shadow_data(wdata),.cfg_shadow_error(wr_error),
        .cfg_commit_valid(commit),.cfg_commit_ready(commit_ready),.cfg_commit_ack(commit_ack),
        .cfg_commit_status(commit_status),.active_generation(generation),
        .task_start_valid(start),.task_start_ready(sr),.candidate_seq(seq),.sample_rate_hz(fs),
        .phase_valid(pvalid),.phase_ready(pr),.phase_seq(pseq),.phase_numeric_valid(pv),.phase_status(ps),
        .phase_raw(raw),.f_hat_hz(freq),.abort(abort),.abort_ack(ack),.busy(busy),
        .result_valid(rv),.result_ready(ready),.result_seq(rseq),.result_generation(rgen),
        .result_profile_id(profile),.numeric_valid(nv),.result_status(status),.calibrated_valid(cv),
        .calibration_status(calstatus),.result_phase_raw(rraw),.phase_cal(cal),.result_f_hat_hz(rfreq),
        .fault_valid(fault),.fault_code(code),.fault_clear(clear));
    integer checks=0,cases=0,good_commits=0;
    reg [31:0] config_words[0:9];
    task automatic check(input bit good,input string message);
        begin checks=checks+1; if(!good) begin $display("RESULT: FAIL calibration case=%0d %s",cases,message); $fatal(1,"calibration"); end end
    endtask
    task automatic write_word(input integer addr,input [31:0] data);
        begin @(negedge clk); check(wr_ready,"shadow write ready"); wr=1; address=addr; wdata=data;
            @(negedge clk); wr=0; check(wr_error==(addr>=10),"invalid address observable"); end
    endtask
    task automatic stage_image;
        integer j;
        begin for(j=0;j<10;j=j+1) write_word(j,config_words[j]); end
    endtask
    task automatic do_commit(input integer expected_status);
        begin @(negedge clk); check(commit_ready,"commit ready independent of Fine busy"); commit=1;
            @(negedge clk); commit=0;
            check(commit_ack && commit_status==expected_status,"commit ack/status");
            if(expected_status==0) good_commits=good_commits+1;
            check(generation==good_commits,"only complete commits increment generation"); end
    endtask
    task automatic reset_core;
        begin @(negedge clk); resetn=0; wr=0; commit=0; start=0; pvalid=0; abort=0; ready=0; clear=0;
            repeat(3) @(negedge clk); resetn=1; good_commits=0; #1;
            check(sr && !rv && !fault && generation==0,"reset unconfigured"); end
    endtask
    task automatic launch(input [31:0] tag,input [31:0] rate);
        begin @(negedge clk); check(sr,"new task ready"); seq=tag; fs=rate; start=1;
            @(negedge clk); start=0; seq=0; fs=0;
            check(pr && busy && !sr,"snapshot at whole Fine start, waiting phase"); end
    endtask
    task automatic send_phase(input [31:0] tag,input signed [35:0] p,input [48:0] f,input bit valid,input [7:0] st);
        begin @(negedge clk); check(pr,"matching phase has destination"); pseq=tag; raw=p; freq=f; pv=valid; ps=st; pvalid=1;
            @(negedge clk); pvalid=0; pseq=0; raw=0; freq=0; pv=0; ps=99; end
    endtask
    task automatic consume;
        begin @(negedge clk); ready=1; @(negedge clk); ready=0; check(sr && !rv && !busy,"consume stage result without ownership release"); end
    endtask
    task automatic image_a;
        begin config_words[0]=1; config_words[1]=32'hffffffff; // sign=-1, bias=+pi/4
            config_words[2]=0; config_words[3]=2;
            config_words[4]=32'h01000000; config_words[5]=0;
            config_words[6]=32'h80000000; config_words[7]=32'h00009896; // 10 MHz / F24
            config_words[8]=111; config_words[9]=0; end
    endtask
    task automatic image_b;
        begin image_a(); config_words[1]=1; config_words[2]=0; config_words[3]=0; config_words[8]=222; end
    endtask
    integer fd,fo,scan,j,ev,ers,ecv,ecs,eprofile,rate,valid_in,status_in,latency,cycle=0,start_cycle;
    reg signed [63:0] eraw,ecal;
    reg [63:0] efreq;
    reg [234:0] held;
    always @(posedge clk) cycle=cycle+1;
    initial begin
        fd=$fopen("calibration_vectors.txt","r"); fo=$fopen("calibration_results.txt","w");
        check(fd!=0 && fo!=0,"vectors present"); reset_core();
        while(!$feof(fd)) begin
            scan=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %d %d %d %d %d %d %d %d %d %d\n",
                config_words[0],config_words[1],config_words[2],config_words[3],config_words[4],
                config_words[5],config_words[6],config_words[7],config_words[8],config_words[9],
                rate,eraw,efreq,valid_in,status_in,ers,ecv,ecs,ecal,eprofile);
            if(scan!=20) check(scan==-1,"complete vector record"); else begin
                stage_image(); do_commit(0); launch(cases+1000,rate);
                for(j=0;j<10;j=j+1) check(dut.snapshot[j]==config_words[j],"whole config snapshot");
                repeat(cases%3) @(negedge clk);
                send_phase(cases+1000,eraw[35:0],efreq[48:0],valid_in!=0,status_in); start_cycle=cycle;
                wait(rv || fault); @(negedge clk);
                check(rv && !fault && !busy,"cal invalid != hardware fault");
                check(nv==valid_in && status==ers && cv==ecv && calstatus==ecs && cal==ecal && profile==eprofile,"bit exact formula quality profile");
                check(rseq==cases+1000 && rgen==good_commits && rraw==eraw && rfreq==efreq,"immutable task data and config generation");
                if(cv) latency=cycle-start_cycle;
                $fdisplay(fo,"%0d %0d %0d %0d %0d %0d %0d",cases,nv,status,cv,calstatus,cal,profile);
                held={rseq,rgen,profile,nv,status,cv,calstatus,rraw,cal,rfreq}; start=1; pvalid=1;
                repeat(3) begin @(negedge clk); check(rv && !sr && !pr && {rseq,rgen,profile,nv,status,cv,calstatus,rraw,cal,rfreq}==held,"held result ignores extra producer inputs"); end
                start=0; pvalid=0; consume(); cases=cases+1;
            end
        end
        $fclose(fd); $fclose(fo);
        // Reset/default valid=0 does not manufacture zero-bias valid calibration.
        reset_core(); launch(9000,62499374); send_phase(9000,36'sh400000000,49'd67108864000000,1,0);
        wait(rv); @(negedge clk); check(nv && !cv && calstatus==0 && profile==0,"raw valid + calibration UNCONFIGURED"); consume();
        image_a(); for(j=0;j<9;j=j+1) write_word(j,config_words[j]);
        do_commit(1); check(generation==0,"incomplete image cannot activate");
        write_word(9,0); do_commit(0); write_word(15,32'h12345678);
        launch(9001,62499374);
        // PS-style writes/COMMIT during long WAIT_PHASE only affect next task.
        image_b(); stage_image(); do_commit(0);
        check(rgen==1 && dut.snapshot[8]==111,"processing snapshot survives config COMMIT");
        send_phase(9001,36'sh400000000,49'd67108864000000,1,0);
        wait(rv); @(negedge clk);
        check(cv && cal==-36'sh200000000 && profile==111 && rgen==1,"subtract then sign then wrap using OLD profile");
        held={rseq,rgen,profile,nv,status,cv,calstatus,rraw,cal,rfreq};
        image_b(); config_words[8]=333; stage_image(); do_commit(0);
        check({rseq,rgen,profile,nv,status,cv,calstatus,rraw,cal,rfreq}==held,"COMMIT during held result cannot rewrite result"); consume();
        launch(9002,62499374); send_phase(9002,36'sh400000000,49'd67108864000000,1,0);
        wait(rv); @(negedge clk); check(cv && cal==36'sh400000000 && profile==333 && rgen==3,"next task uses NEW generation"); consume();
        // Defined same-edge ordering: task snapshot uses pre-COMMIT active image.
        image_a(); stage_image();
        @(negedge clk); commit=1; start=1; seq=9003; fs=62499374;
        @(negedge clk); commit=0; start=0; good_commits=good_commits+1;
        check(commit_ack && commit_status==0 && generation==4 && rgen==3,"simultaneous start/COMMIT chooses OLD generation");
        send_phase(9003,36'sh400000000,49'd67108864000000,1,0);
        wait(rv); @(negedge clk); check(profile==333 && cal==36'sh400000000,"same-edge old config result"); consume();
        launch(9004,62499374); send_phase(9004,36'sh400000000,49'd67108864000000,1,0);
        wait(rv); @(negedge clk); check(profile==111 && rgen==4 && cal==-36'sh200000000,"following task sees new committed config"); consume();
        // Simultaneous final shadow write/COMMIT: commit wins, producer holds write.
        image_b(); for(j=0;j<9;j=j+1) write_word(j,config_words[j]);
        @(negedge clk); wr=1; address=9; wdata=0; commit=1;
        #1; check(!wr_ready,"COMMIT suppresses same-edge shadow acceptance");
        @(negedge clk); check(commit_ack && commit_status==1 && generation==4,"last unaccepted word cannot complete commit"); commit=0;
        @(negedge clk); wr=0; do_commit(0); check(generation==5,"held write accepted before retry COMMIT");
        // Bad phase tag/valid-status protocol is a local hardware fault, not CAL_INVALID.
        launch(9010,62499374); send_phase(9009,0,49'd67108864000000,1,0);
        @(negedge clk); check(fault && code==8'h40 && !rv && !cv,"wrong phase seq latches fault");
        repeat(3) @(negedge clk); clear=1; @(negedge clk); clear=0; check(sr && !fault,"explicit local fault clear");
        launch(9011,62499374); send_phase(9011,0,49'd67108864000000,1,4);
        @(negedge clk); check(fault && code==8'h40,"valid with nonzero status is protocol fault");
        clear=1; @(negedge clk); clear=0;
        // Local abort waiting for phase and each accepted-phase processing step.
        for(j=0;j<7;j=j+1) begin
            launch(9020+j,62499374);
            if(j>0) begin send_phase(9020+j,0,49'd67108864000000,1,0); repeat(j-1) @(negedge clk); end
            abort=1; @(negedge clk); check(ack && !rv && !busy && !cv,"local abort has no stale calibration result");
            abort=0; @(negedge clk); check(sr,"abort recovery");
        end
        launch(9030,62499374); reset_core(); check(!pr && !rv,"reset cancels waiting phase and config image");
        @(negedge clk); dut.state=4'd15; @(negedge clk); check(fault && code==8'h41,"illegal local state hardware fault");
        clear=1; @(negedge clk); clear=0; check(sr && !fault,"illegal-state clear");
        $display("RESULT: PASS calibration cases=%0d checks=%0d valid_phase_to_result_cycles=%0d shadow_commit_snapshot_protocol",cases,checks,latency); $finish;
    end
    initial begin #100000000; $display("RESULT: FAIL calibration watchdog"); $fatal(1,"timeout"); end
endmodule
