// 自动生成：scripts/generate_mode_catalog.py；只修改config/hil_mode_catalog.json。
// 定义SHA256：aaa209c91ce45993f3c7821e18a5b1b717453d3785ccda53a18e4d9862cf8682
function [4:0] alias_mode_of(input [1:0] band,input negative,input [1:0] kind);
    case({band,negative,kind})
        5'd0:alias_mode_of=5'd0;
        5'd4:alias_mode_of=5'd0;
        5'd1:alias_mode_of=5'd1;
        5'd5:alias_mode_of=5'd2;
        5'd2:alias_mode_of=5'd3;
        5'd6:alias_mode_of=5'd4;
        5'd8:alias_mode_of=5'd5;
        5'd12:alias_mode_of=5'd5;
        5'd9:alias_mode_of=5'd6;
        5'd13:alias_mode_of=5'd7;
        5'd16:alias_mode_of=5'd8;
        5'd20:alias_mode_of=5'd8;
        5'd17:alias_mode_of=5'd9;
        5'd21:alias_mode_of=5'd10;
        5'd18:alias_mode_of=5'd11;
        5'd22:alias_mode_of=5'd12;
        5'd10:alias_mode_of=5'd13;
        5'd14:alias_mode_of=5'd14;
        5'd24:alias_mode_of=5'd15;
        5'd28:alias_mode_of=5'd15;
        5'd25:alias_mode_of=5'd16;
        5'd29:alias_mode_of=5'd17;
        5'd26:alias_mode_of=5'd18;
        5'd30:alias_mode_of=5'd19;
        default:alias_mode_of=5'd0;
    endcase
endfunction
wire [3:0] alias_zero={(line[31:0]=="00.0"),(line[23:0]=="0.0"),(line[15:0]=="00"),(line[7:0]=="0")};
wire [3:0] alias_thirty={(line[31:0]=="30.0"),1'b0,(line[15:0]=="30"),1'b0};
wire [3:0] alias_sixty={(line[31:0]=="60.0"),1'b0,(line[15:0]=="60"),1'b0};
