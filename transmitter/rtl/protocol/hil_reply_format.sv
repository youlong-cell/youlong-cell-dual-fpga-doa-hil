`timescale 1ns/1ps
// 不可变描述符的纯组合ASCII格式化，不拥有TX或队列状态。
module hil_reply_format(
    input wire [23:0] descriptor,output wire [511:0] formatted_text,
    output wire [6:0] formatted_length
);
    function [7:0] digit(input [3:0] x);digit=8'h30+{4'd0,x};endfunction
    `include "generated/reply_decimal.vh"
    function [511:0] format_reply(input [23:0] d);
        reg [303:0] tail;
        reg [351:0] custom_tail;
        reg [7:0] sign_char,tens;
        reg [4:0] m;
        reg [3:0] f;
        reg [10:0] a;
        reg [11:0] angle_digits;
        begin
            m=d[5:1];
            `include "generated/reply_presets.vh"
            tail={" MODE=",digit(m/5'd10),digit(m%5'd10)," FREQ=",digit(f/4'd10),digit(f%4'd10),
                  "M ANGLE=",sign_char,tens,"0"," OUTPUT=",d[0]?8'h31:8'h30,8'h0d,8'h0a};
            // Exact absolute value of signed S11, including -1024. Unsigned
            // bounded division avoids inferring a signed 32-bit divider chain.
            a=d[20] ? (~d[20:10]+11'd1) : d[20:10];
            angle_digits=angle_decimal_digits(a);
            `include "generated/reply_custom_band.vh"
            custom_tail={" MODE=CUSTOM FREQ=",digit(f/4'd10),digit(f%4'd10),"M ANGLE=",
                d[20]?8'h2d:8'h2b,digit(angle_digits[11:8]),digit(angle_digits[7:4]),".",digit(angle_digits[3:0]),
                " OUTPUT=",d[0]?8'h31:8'h30,8'h0d,8'h0a};
            case(d[9:6])
                0:format_reply=d[23]?{"OK",custom_tail}:{"OK",tail};
                1:format_reply=d[23]?{"OK UNCHANGED",custom_tail}:{"OK UNCHANGED",tail};
                2:format_reply=d[23]?{"STATUS",custom_tail}:{"STATUS",tail};
                3:format_reply={"ERR INVALID",8'h0d,8'h0a};
                4:format_reply={"ERR BUSY",8'h0d,8'h0a};
                5:format_reply={"ERR LINE_OVERFLOW",8'h0d,8'h0a};
                6:format_reply={"ERR TIMEOUT",8'h0d,8'h0a};
                7:format_reply={"ERR FRAME",8'h0d,8'h0a};
                8:format_reply={"ERR PREEMPTED",8'h0d,8'h0a};
                9:format_reply={"ERR TX_OVERFLOW",8'h0d,8'h0a};
                default:format_reply={"ERR INTERNAL",8'h0d,8'h0a};
            endcase
        end
    endfunction
    function [6:0] reply_length(input [3:0] code);
        case(code)
            0:reply_length=40;1:reply_length=50;2:reply_length=44;
            3:reply_length=13;4:reply_length=10;5:reply_length=19;
            6:reply_length=13;7:reply_length=11;8:reply_length=15;
            9:reply_length=17;default:reply_length=14;
        endcase
    endfunction
    assign formatted_text=format_reply(descriptor);
    assign formatted_length=(descriptor[23] && descriptor[9:6]<=2) ?
        ((descriptor[9:6]==0)?7'd46:((descriptor[9:6]==1)?7'd56:7'd50)) : reply_length(descriptor[9:6]);
endmodule
