// 自动生成：scripts/generate_mode_catalog.py；只修改config/hil_mode_catalog.json。
// 定义SHA256：aaa209c91ce45993f3c7821e18a5b1b717453d3785ccda53a18e4d9862cf8682
case(mode_index)
    5'd0,5'd1,5'd2,5'd3,5'd4:led_frequency=2'd0;
    5'd5,5'd6,5'd7,5'd13,5'd14:led_frequency=2'd1;
    5'd8,5'd9,5'd10,5'd11,5'd12:led_frequency=2'd2;
    5'd15,5'd16,5'd17,5'd18,5'd19:led_frequency=2'd3;
    default:led_frequency=2'd0;
endcase
case(mode_index)
    5'd0,5'd5,5'd8,5'd15:led_angle=2'b00;
    5'd1,5'd6,5'd9,5'd16:led_angle=2'b01;
    5'd2,5'd7,5'd10,5'd17:led_angle=2'b10;
    5'd3,5'd11,5'd13,5'd18:led_angle=2'b11;
    5'd4,5'd12,5'd14,5'd19:led_angle=led_blink ? 2'b11 : 2'b00;
    default:led_angle=2'b00;
endcase
