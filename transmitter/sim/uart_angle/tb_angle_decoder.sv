`timescale 1ns/1ps
// Exhaustive accepted decimal grid in addition to real-bit UART integration TB.
module tb_angle_decoder;
    reg [255:0] line=0;
    reg [5:0] length=0;
    wire found,en;
    wire [6:0] decoded;
    wire [1:0] fi;
    wire signed [10:0] angle;
    integer f,a,i,expected_mode,checks=0,invalids=0;
    string text,token;
    hil_command_decode dut(.line(line),.line_length(length),.found(found),.decoded(decoded),.decoded_enable(en),
        .frequency_index(fi),.angle_tenths(angle));
    function string freq(input integer f);case(f)0:freq="1M";1:freq="2M";2:freq="5M";3:freq="10M";endcase endfunction
    task drive(input string s);integer k;begin line=0;length=s.len();for(k=0;k<s.len();k++)line={line[247:0],s[k]};#1;end endtask
    task reject(input string s);begin drive(s);if(found)$fatal(1,"UNSAFE_ACCEPT [%s]",s);invalids++;end endtask
    initial begin
        for(f=0;f<4;f++)for(a=-900;a<=900;a++)begin
            token=$sformatf("%s%0d.%0d",a<0?"-":"+",(a<0?-a:a)/10,(a<0?-a:a)%10);
            text={"SET ",freq(f)," ",token};drive(text);
            if(!found || fi!=f || angle!=a || en)$fatal(1,"DECODER_FAIL [%s]",text);
            if(a==0 || a==300 || a==-300 || a==600 || a==-600)begin
                case(f)
                    0:expected_mode=(a==0)?0:((a==300)?1:((a==-300)?2:((a==600)?3:4)));
                    1:expected_mode=(a==0)?5:((a==300)?6:((a==-300)?7:((a==600)?13:14)));
                    2:expected_mode=(a==0)?8:((a==300)?9:((a==-300)?10:((a==600)?11:12)));
                    3:expected_mode=(a==0)?15:((a==300)?16:((a==-300)?17:((a==600)?18:19)));
                endcase
                if(decoded!==expected_mode)$fatal(1,"CANONICAL_MODE_FAIL [%s]",text);
            end else if(decoded!={2'd3,5'd31})$fatal(1,"CUSTOM_KIND_FAIL");
            checks++;
        end
        for(f=0;f<4;f++)begin
            reject({"SET ",freq(f)," +90.1"});reject({"SET ",freq(f)," -90.1"});
            reject({"SET ",freq(f)," +100"});reject({"SET ",freq(f)," 999"});
            reject({"SET ",freq(f)," +40.00"});reject({"SET ",freq(f)," +40."});
            reject({"SET ",freq(f)," .4"});reject({"SET ",freq(f)," +-40"});
            reject({"SET ",freq(f)," +4 0"});reject({"SET ",freq(f)," +40x"});
            reject({"SET ",freq(f)," +40 "});reject({"SET ",freq(f)," +40 EXTRA"});
            reject({"SET ",freq(f)," +"});reject({"SET ",freq(f)," -"});
        end
        reject("SET 3M +40");reject("SET 1MHz +40");reject("SET 5M NaN");reject("SET 5M inf");
        reject("SET 5M 1e1");reject("SET 5M ++0");reject("SET 5M --0");reject("SET 5M +0..1");
        reject("SET 5M +0.11");reject("SET 5M +000");reject("SET 5M");reject("SET 5M ");reject("set 5M 40");
        if(checks!=7204)$fatal(1,"DECODER_COVERAGE");
        $display("ANGLE_DECODER_PASS accepted=%0d rejected=%0d failures=0",checks,invalids);$finish;
    end
endmodule
