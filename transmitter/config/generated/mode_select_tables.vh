// 自动生成：scripts/generate_mode_catalog.py；只修改config/hil_mode_catalog.json。
// 定义SHA256：aaa209c91ce45993f3c7821e18a5b1b717453d3785ccda53a18e4d9862cf8682
function [31:0] freq_word_of;
    input [4:0] index;
    case(index)
        5'd0,5'd1,5'd2,5'd3,5'd4:freq_word_of=32'h020C49BA;
        5'd5,5'd6,5'd7,5'd13,5'd14:freq_word_of=32'h04189375;
        5'd8,5'd9,5'd10,5'd11,5'd12:freq_word_of=32'h0A3D70A4;
        5'd15,5'd16,5'd17,5'd18,5'd19:freq_word_of=32'h147AE148;
        default:freq_word_of=32'h020C49BA;
    endcase
endfunction
function [31:0] phase_word_of;
    input [4:0] index;
    case(index)
        5'd0,5'd5,5'd8,5'd15:phase_word_of=32'h00000000;
        5'd1:phase_word_of=32'h02222222;
        5'd2:phase_word_of=32'hFDDDDDDE;
        5'd3:phase_word_of=32'h03B1EE41;
        5'd4:phase_word_of=32'hFC4E11BF;
        5'd6:phase_word_of=32'h04444444;
        5'd7:phase_word_of=32'hFBBBBBBC;
        5'd9:phase_word_of=32'h0AAAAAAB;
        5'd10:phase_word_of=32'hF5555555;
        5'd11:phase_word_of=32'h1279A746;
        5'd12:phase_word_of=32'hED8658BA;
        5'd13:phase_word_of=32'h0763DC82;
        5'd14:phase_word_of=32'hF89C237E;
        5'd16:phase_word_of=32'h15555555;
        5'd17:phase_word_of=32'hEAAAAAAB;
        5'd18:phase_word_of=32'h24F34E8B;
        5'd19:phase_word_of=32'hDB0CB175;
        default:phase_word_of=32'h00000000;
    endcase
endfunction
function [1:0] frequency_index_of;
    input [4:0] index;
    case(index)
        5'd0,5'd1,5'd2,5'd3,5'd4:frequency_index_of=2'd0;
        5'd5,5'd6,5'd7,5'd13,5'd14:frequency_index_of=2'd1;
        5'd8,5'd9,5'd10,5'd11,5'd12:frequency_index_of=2'd2;
        5'd15,5'd16,5'd17,5'd18,5'd19:frequency_index_of=2'd3;
        default:frequency_index_of=2'd3;
    endcase
endfunction
function signed [10:0] angle_of;
    input [4:0] index;
    case(index)
        5'd0,5'd5,5'd8,5'd15:angle_of=11'sd0;
        5'd1,5'd6,5'd9,5'd16:angle_of=11'sd300;
        5'd2,5'd7,5'd10,5'd17:angle_of=-11'sd300;
        5'd3,5'd11,5'd13,5'd18:angle_of=11'sd600;
        5'd4,5'd12,5'd14,5'd19:angle_of=-11'sd600;
        default:angle_of=11'sd0;
    endcase
endfunction
function [4:0] next_mode_of;
    input [4:0] index;
    case(index)
        5'd0:next_mode_of=5'd1;
        5'd1:next_mode_of=5'd2;
        5'd2:next_mode_of=5'd3;
        5'd3:next_mode_of=5'd4;
        5'd4:next_mode_of=5'd5;
        5'd5:next_mode_of=5'd6;
        5'd6:next_mode_of=5'd7;
        5'd7:next_mode_of=5'd13;
        5'd13:next_mode_of=5'd14;
        5'd14:next_mode_of=5'd8;
        5'd8:next_mode_of=5'd9;
        5'd9:next_mode_of=5'd10;
        5'd10:next_mode_of=5'd11;
        5'd11:next_mode_of=5'd12;
        5'd12:next_mode_of=5'd15;
        5'd15:next_mode_of=5'd16;
        5'd16:next_mode_of=5'd17;
        5'd17:next_mode_of=5'd18;
        5'd18:next_mode_of=5'd19;
        5'd19:next_mode_of=5'd0;
        default:next_mode_of=5'd0;
    endcase
endfunction
