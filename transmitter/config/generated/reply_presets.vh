// 自动生成：scripts/generate_mode_catalog.py；只修改config/hil_mode_catalog.json。
// 定义SHA256：aaa209c91ce45993f3c7821e18a5b1b717453d3785ccda53a18e4d9862cf8682
case(m)
    5'd0,5'd1,5'd2,5'd3,5'd4:f=4'd1;
    5'd5,5'd6,5'd7,5'd13,5'd14:f=4'd2;
    5'd8,5'd9,5'd10,5'd11,5'd12:f=4'd5;
    5'd15,5'd16,5'd17,5'd18,5'd19:f=4'd10;
    default:f=4'd10;
endcase
case(m)
    5'd0,5'd5,5'd8,5'd15:begin sign_char="+";tens="0";end
    5'd1,5'd6,5'd9,5'd16:begin sign_char="+";tens="3";end
    5'd2,5'd7,5'd10,5'd17:begin sign_char="-";tens="3";end
    5'd3,5'd11,5'd13,5'd18:begin sign_char="+";tens="6";end
    5'd4,5'd12,5'd14,5'd19:begin sign_char="-";tens="6";end
    default:begin sign_char="+";tens="0";end
endcase
