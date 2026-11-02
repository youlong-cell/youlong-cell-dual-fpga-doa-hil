`timescale 1ns/1ps
module tb_hil20_any_angle;
    localparam CPB=16,BAUD=125000000/CPB,TIMEOUT=4096;
    localparam realtime BIT_NS=8.0*CPB;
    reg clk=0,rst=1,rx=1,k0=0,k1=0,link_up=1;
    wire tx,custom_active,enable,restart,busy,wave;
    wire [4:0] mode;
    wire [1:0] fi;
    wire signed [10:0] angle;
    wire [31:0] fw,drops;
    wire signed [31:0] pw;
    wire [13:0] amplitude,d0,d1;
    wire [3:0] led;
    integer checks=0,failures=0,reply_count=0,restarts=0,cycles=0,commit_cycle=-100,nco_reset_cycle=-100;
    integer commands=0,custom_commands=0,monitor_epoch=0;
    string replies[0:1023],line="";
    hil20_uart_control #(.CLOCK_HZ(125000000),.BAUD_RATE(BAUD),.LINE_TIMEOUT_CYCLES(TIMEOUT),.USE_LINK_STATUS(1)) dut(
        .clk(clk),.rst(rst),.key0_press(k0),.key1_press(k1),.uart_rx(rx),.uart_link_up(link_up),.uart_tx(tx),
        .mode_index(mode),.frequency_word(fw),.phase_offset_word(pw),.amplitude(amplitude),.wave_sel(wave),
        .output_enable(enable),.restart_pulse(restart),.control_busy(busy),.dropped_reply_count(drops),.key_overflow(),.reply_busy(),
        .custom_active(custom_active),.active_frequency_index(fi),.active_angle_tenths(angle));
    coherent_nco nco(.clk(clk),.rst(rst),.enable(enable),.restart(restart),.wave_sel(wave),.frequency_word(fw),
        .phase_offset_word(pw),.amplitude(amplitude),.ch1_data(d0),.ch2_data(d1),.phase_acc_debug());
    hil20_led_status #(.LED_BLINK_HALF_CYCLES(32)) leds(.clk(clk),.rst(rst),.mode_index(mode),.led(led),
        .custom_active(custom_active),.active_frequency_index(fi));
    always #4 clk=~clk;
    initial begin #100000000;$fatal(1,"ANY_ANGLE_GLOBAL_TIMEOUT");end
    task check(input bit ok,input string why);
        begin checks++;if(!ok)begin failures++;$display("FAIL %s t=%0t",why,$time);if(failures>=8)$fatal(1,"TOO_MANY_FAILURES");end end
    endtask
    always @(posedge clk)begin
        cycles++;
        if(!rst)begin
            if(restart)nco_reset_cycle=cycles;
            if(dut.control.start_custom)commit_cycle=cycles;
            #0.1;
            check(amplitude===14'd1024 && wave===0,"unchanged NCO amplitude/sine");
            check((custom_active && mode==31) || (!custom_active && mode<20),"truthful mode identity");
            if(restart)restarts++;
            if(dut.rsp_valid && dut.rsp_custom_active && dut.rsp_code==0)begin
                check(cycles-commit_cycle>=6 && nco_reset_cycle>commit_cycle,"custom ACK after NCO restart consume");
            end
        end
    end
    always @(posedge rst or negedge link_up)begin monitor_epoch++;line="";end
    initial forever begin : tx_monitor
        reg [7:0] b;integer i,epoch;
        @(negedge tx);epoch=monitor_epoch;
        if(!rst && link_up)begin
            #(BIT_NS*1.5);
            for(i=0;i<8;i++)begin b[i]=tx;#(BIT_NS);end
            if(epoch==monitor_epoch && !rst && link_up)begin
                check(tx===1,"8N1 complete stop");line={line,$sformatf("%c",b)};
                if(b==8'h0a)begin replies[reply_count]=line;reply_count++;$display("REPLY %s",line);line="";end
            end
        end
    end
    task send_byte(input [7:0] b,input bit good_stop=1);
        integer i;begin rx=0;#(BIT_NS);for(i=0;i<8;i++)begin rx=b[i];#(BIT_NS);end rx=good_stop;#(BIT_NS);rx=1;end
    endtask
    task send_text(input string s);integer i;begin for(i=0;i<s.len();i++)send_byte(s[i]);end endtask
    task drain;
        integer n;begin n=0;
            while((dut.count!=0 || dut.reply_busy || dut.inflight || dut.pending_event || dut.overflow_notice) && n<400000)begin @(negedge clk);n++;end
            check(n<400000,"bounded queues drain");repeat(20)@(negedge clk);
        end
    endtask
    task wait_reply(input integer slot,input string expected);
        integer n;begin n=0;
            while(reply_count<=slot && n<150000)begin @(negedge clk);n++;end
            check(reply_count>slot,"reply deadline");
            if(reply_count>slot)check(replies[slot]==expected,$sformatf("got=[%s] expected=[%s]",replies[slot],expected));
        end
    endtask
    task exchange(input string command,input string expected);
        integer slot;begin slot=reply_count;send_text(command);wait_reply(slot,expected);drain();check(reply_count==slot+1,"one complete reply");commands++;end
    endtask
    function string frequency_token(input integer index);
        case(index)0:frequency_token="1M";1:frequency_token="2M";2:frequency_token="5M";3:frequency_token="10M";endcase
    endfunction
    function string state_reply(input string prefix,input integer index,input integer a,input bit en);
        integer f,mag;begin
            case(index)0:f=1;1:f=2;2:f=5;3:f=10;endcase
            mag=a<0?-a:a;
            state_reply=$sformatf("%s MODE=CUSTOM FREQ=%02dM ANGLE=%s%02d.%0d OUTPUT=%0d\015\n",prefix,f,a<0?"-":"+",mag/10,mag%10,en);
        end
    endfunction
    task custom_set(input integer index,input integer a,input string ending="\015\n");
        string token,cmd;integer rc;begin
            token=$sformatf("%s%0d.%0d",a<0?"-":"+",(a<0?-a:a)/10,(a<0?-a:a)%10);
            cmd={"SET ",frequency_token(index)," ",token,ending};rc=restarts;
            exchange(cmd,state_reply("OK",index,a,enable));
            check(custom_active && angle==a && fi==index,"custom metadata commits atomically");
            check(restarts==rc+1,"one restart per changed custom request");custom_commands++;
        end
    endtask
    task press(input integer which);
        begin @(negedge clk);if(which==0)k0=1;else k1=1;@(negedge clk);k0=0;k1=0;repeat(20)@(negedge clk);end
    endtask
    task capture(input integer id,input integer count=16384);
        integer fd,i;string filename;begin
            repeat(64)@(negedge clk);filename=$sformatf("wave_%0d.csv",id);fd=$fopen(filename,"w");
            if(!fd)$fatal(1,"WAVE_FILE");$fdisplay(fd,"sample,ch0,ch1");
            for(i=0;i<count;i++)begin @(negedge clk);$fdisplay(fd,"%0d,%0d,%0d",i,d0,d1);end
            $fclose(fd);$display("WAVE_CAPTURE id=%0d fi=%0d angle_tenths=%0d fw=%08x pw=%08x samples=%0d",id,fi,angle,fw,pw,count);
        end
    endtask
    integer f,j,rc,slot,drop_before,saved_pw;
    reg [13:0] trace0[0:127],trace1[0:127];
    reg [31:0] old_phase,old_frequency;
    initial begin
        repeat(10)@(negedge clk);rst=0;repeat(20)@(negedge clk);
        check(mode==0 && !enable && !custom_active && d0==8192 && d1==8192,"safe startup");
        exchange("SET 5M +40\015\n",state_reply("OK",2,400,0));
        check(custom_active && mode==31 && fi==2 && angle==400,"reported +40 now supported");
        rc=restarts;exchange("SET 5M +40.0\n",state_reply("OK UNCHANGED",2,400,0));check(restarts==rc,"same numeric SET idempotent");
        exchange("STATUS?\n",state_reply("STATUS",2,400,0));
        exchange("OUTPUT ON\n",state_reply("OK",2,400,1));
        // Deterministic enable transitions, same unmodified real NCO.
        exchange("OUTPUT OFF\n",state_reply("OK",2,400,0));
        fork
            exchange("OUTPUT ON\n",state_reply("OK",2,400,1));
            begin @(posedge enable);for(j=0;j<128;j++)begin @(negedge clk);trace0[j]=d0;trace1[j]=d1;end end
        join
        exchange("OUTPUT OFF\n",state_reply("OK",2,400,0));
        fork
            exchange("OUTPUT ON\n",state_reply("OK",2,400,1));
            begin @(posedge enable);for(j=0;j<128;j++)begin @(negedge clk);check(d0===trace0[j] && d1===trace1[j],"custom deterministic OFF/ON samples");end end
        join
        for(f=0;f<4;f++)begin
            custom_set(f,401,"\015");capture(f*2);
            custom_set(f,-401,"\n");capture(f*2+1);
            custom_set(f,123);custom_set(f,-123);
            custom_set(f,899);custom_set(f,-899);
            custom_set(f,900);custom_set(f,-900);
            custom_set(f,1);custom_set(f,-1);
        end
        // Two real commands while TX is busy: immutable, distinct ACK snapshots.
        slot=reply_count;send_text("SET 1M +11.1\n");send_text("SET 10M -22.2\n");
        wait_reply(slot,state_reply("OK",0,111,1));wait_reply(slot+1,state_reply("OK",3,-222,1));drain();
        // Canonical decimal forms return to the old mode/table, not approximate words.
        exchange("SET 5M +30.0\n","OK MODE=09 FREQ=05M ANGLE=+30 OUTPUT=1\015\n");
        check(!custom_active && mode==9 && pw===32'h0aaaaaab,"canonical +30.0 preserves exact word");
        exchange("SET 1M -0.0\n","OK MODE=00 FREQ=01M ANGLE=+00 OUTPUT=1\015\n");
        custom_set(2,400);rc=restarts;old_phase=pw;old_frequency=fw;
        exchange("SET 5M +90.1\n","ERR INVALID\015\n");
        exchange("SET 5M -90.1\n","ERR INVALID\015\n");
        exchange("SET 5M +100\n","ERR INVALID\015\n");
        exchange("SET 5M 180\n","ERR INVALID\015\n");
        exchange("SET 5M +40.00\n","ERR INVALID\015\n");
        exchange("SET 5M +40.\n","ERR INVALID\015\n");
        exchange("SET 5M .4\n","ERR INVALID\015\n");
        exchange("SET 5M +-40\n","ERR INVALID\015\n");
        exchange("SET 5M +4 0\n","ERR INVALID\015\n");
        exchange("SET 3M +40\n","ERR INVALID\015\n");
        exchange("SET 5M +40x\n","ERR INVALID\015\n");
        exchange("SET 5M +40 \n","ERR INVALID\015\n");
        exchange("set 5M +40\n","ERR INVALID\015\n");
        exchange("SET 5M +40 EXTRA\n","ERR INVALID\015\n");
        check(restarts==rc && pw==old_phase && fw==old_frequency && enable,"invalid commands are complete no-op");
        exchange("SET 5M 40\n",state_reply("OK UNCHANGED",2,400,1));
        slot=reply_count;send_text("SET 5M +");repeat(TIMEOUT+32)@(negedge clk);wait_reply(slot,"ERR TIMEOUT\015\n");
        send_text("50\n");drain();check(angle==400,"timeout tail cannot become command");
        exchange("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n","ERR LINE_OVERFLOW\015\n");
        slot=reply_count;send_text("SET 5M +");send_byte("5",0);#(BIT_NS*3);send_text("0\n");wait_reply(slot,"ERR FRAME\015\n");drain();
        check(angle==400 && pw==old_phase,"bad UART stop no partial mutation");
        // Immutable extended STATUS snapshot while physical KEY0 restores presets.
        slot=reply_count;send_text("STATUS?\n");wait(dut.reply_busy);press(0);
        wait_reply(slot,state_reply("STATUS",2,400,1));drain();
        check(!custom_active && mode==0,"KEY0 from CUSTOM restores preset0");
        custom_set(1,407);press(1);check(!enable && custom_active && angle==407,"KEY1 OFF retains custom parameters");
        press(1);check(enable,"KEY1 ON still available");
        // Accepted custom command concurrent with a key: explicit key priority / BUSY.
        slot=reply_count;
        fork
            send_text("SET 10M +42.1\n");
            begin wait(dut.req_valid);@(negedge clk);k0=1;@(negedge clk);k0=0;end
        join
        wait_reply(slot,"ERR BUSY\015\n");drain();check(mode==0 && !custom_active,"key wins remote collision");
        // KEY0 retained during mapping/commit (do not bypass UART request construction).
        slot=reply_count;
        fork
            send_text("SET 10M +42.1\n");
            begin wait(dut.control.start_custom);@(negedge clk);@(negedge clk);k0=1;@(negedge clk);k0=0;end
        join
        wait_reply(slot,state_reply("OK",3,421,1));drain();check(mode==0 && !custom_active,"queued KEY0 after custom ACK");
        // Complete request canceled by reset before mapping finishes; no late restart/ACK.
        fork
            send_text("SET 5M -45.5\n");
            begin wait(dut.control.start_custom);@(negedge clk);rst=1;rx=1;repeat(5)@(negedge clk);rst=0;end
        join
        repeat(100)@(negedge clk);drain();
        check(mode==0 && !enable && !custom_active,"reset clears custom transaction and safely defaults");
        exchange("STATUS?\n","STATUS MODE=00 FREQ=01M ANGLE=+00 OUTPUT=0\015\n");
        custom_set(0,400);send_text("SET 5M -");link_up=0;rx=1;repeat(10)@(negedge clk);link_up=1;
        exchange("40\n","ERR INVALID\015\n");check(fi==0 && angle==400,"link loss clears incomplete command, keeps last committed state");
        // Real serial flood: reserved response slot, bounded overflow, no torn replies.
        drain();drop_before=drops;slot=reply_count;
        for(j=0;j<30;j++)send_text("STATUS?\n");
        drain();check(drops>drop_before,"full TX reply queue reports drops");
        for(j=slot;j<reply_count;j++)check(replies[j]==state_reply("STATUS",0,400,0) ||
            replies[j]=="ERR BUSY\015\n" || replies[j]=="ERR TX_OVERFLOW\015\n","no torn metadata during reply FIFO flood");
        exchange("STATUS?\n",state_reply("STATUS",0,400,0));
        check(custom_commands>=43 && commands>=70,"required custom/UART coverage");
        $display("ANY_ANGLE_SUMMARY checks=%0d failures=%0d commands=%0d custom=%0d replies=%0d",checks,failures,commands,custom_commands,reply_count);
        if(failures)$fatal(1,"ANY_ANGLE_FAIL");$display("ANY_ANGLE_UART_PASS NOT_BOARD_TESTED");$finish;
    end
endmodule
