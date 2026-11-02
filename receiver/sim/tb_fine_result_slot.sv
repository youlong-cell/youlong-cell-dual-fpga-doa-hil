`timescale 1ns/1ps
module tb_fine_result_slot;
    reg clk=0; always #5 clk=~clk;
    reg resetn=0,offer_valid=0,ack_valid=0;
    reg [1046:0] offer_payload=0;
    reg [63:0] offer_epoch=100,ack_epoch=0;
    reg [31:0] offer_seq=1,offer_version=1,ack_seq=0,ack_version=0;
    wire stored,dropped,valid,response,granted;
    wire [1046:0] payload;
    wire [63:0] response_epoch,last_epoch;
    wire [31:0] response_seq,response_version,drops,errors,last_seq,last_version;
    integer checks=0,j;
    reg [1046:0] held;
    fine_result_slot dut(.clk(clk),.resetn(resetn),.offer_valid(offer_valid),
        .offer_payload(offer_payload),.offer_epoch(offer_epoch),.offer_seq(offer_seq),
        .offer_config_version(offer_version),.offer_stored(stored),.offer_dropped(dropped),
        .result_valid(valid),.result_payload(payload),.ack_valid(ack_valid),
        .ack_epoch(ack_epoch),.ack_seq(ack_seq),.ack_config_version(ack_version),
        .ack_response_valid(response),.ack_granted(granted),.ack_response_epoch(response_epoch),
        .ack_response_seq(response_seq),.ack_response_config_version(response_version),
        .drop_count(drops),.protocol_error_count(errors),.last_drop_epoch(last_epoch),
        .last_drop_seq(last_seq),.last_drop_config_version(last_version));
    task check(input bit ok,input string message);
        begin checks=checks+1; if(!ok) $fatal(1,"RESULT: FAIL %s",message); end
    endtask
    task tick; begin @(posedge clk); @(negedge clk); end endtask
    initial begin
        tick(); check(!valid && payload==0 && drops==0 && errors==0,"reset");
        resetn=1; tick();
        ack_valid=1; ack_epoch=100; ack_seq=1; ack_version=1; tick();
        check(response && !granted && errors==1 && !valid,"empty ACK denied");
        // Empty + ACK matching arriving result is still not an ACK of that result.
        offer_valid=1; offer_payload={1047{1'b1}}; tick();
        check(stored && !dropped && valid && !granted && errors==2,"ACK compares pre-edge slot");
        held=payload; offer_valid=0; ack_valid=0;
        for(j=0;j<100;j=j+1) begin tick(); check(valid && payload===held,"unacked indefinite hold"); end
        for(j=0;j<3;j=j+1) begin
            ack_valid=1; ack_epoch=100; ack_seq=1; ack_version=1;
            if(j==0) ack_epoch=101;
            if(j==1) ack_seq=2;
            if(j==2) ack_version=2;
            tick(); check(response && !granted && payload===held && errors==j+3,
                          "each identity mismatch denied");
            check(response_epoch==ack_epoch && response_seq==ack_seq && response_version==ack_version,
                  "denial echoes requested identity");
        end
        ack_valid=0; offer_epoch=200; offer_seq=2; offer_version=3;
        offer_payload=1047'd123456; offer_valid=1; tick();
        check(dropped && !stored && valid && payload===held && drops==1 &&
              last_epoch==200 && last_seq==2 && last_version==3,"full retains old/counts new drop");
        // Simultaneous matching ACK + new offer transfers slot atomically.
        ack_valid=1; ack_epoch=100; ack_seq=1; ack_version=1; tick();
        check(granted && response && stored && !dropped && valid && payload==123456 && drops==1,
              "same-cycle ACK and offer retains NEW result");
        offer_valid=0; tick();
        check(!granted && valid && payload==123456 && errors==6,"old duplicate ACK cannot clear replacement");
        ack_epoch=200; ack_seq=2; ack_version=3; tick();
        check(granted && !valid && payload==123456,"matching ACK clears occupancy, no needless payload writes");
        tick(); check(!granted && !valid && errors==7,"duplicate ACK empty counted");
        ack_valid=0; offer_valid=1; offer_seq=3; tick();
        check(stored && valid,"reuse after ACK");
        // Saturating telemetry must not wrap to zero under prolonged slow PS.
        @(negedge clk); dut.drop_count=32'hfffffffe; dut.protocol_error_count=32'hfffffffe;
        ack_valid=1; ack_seq=99; tick();
        check(drops==32'hffffffff && errors==32'hffffffff && dropped && !granted,"counters reach max");
        tick(); check(drops==32'hffffffff && errors==32'hffffffff,"counters saturate");
        offer_valid=0; ack_valid=0; resetn=0; tick();
        check(!valid && payload==0 && drops==0 && errors==0,"coordinated reset clears slot");
        resetn=1; offer_valid=1; offer_epoch=201; offer_seq=1; offer_version=1; tick();
        ack_valid=1; offer_valid=0; ack_epoch=200; ack_seq=1; ack_version=1; tick();
        check(!granted && valid && errors==1,"prior session ACK cannot clear new session");
        $display("RESULT: PASS fine_result_slot checks=%0d",checks); $finish;
    end
    initial begin #100000; $fatal(1,"RESULT: FAIL watchdog"); end
endmodule
