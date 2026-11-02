`timescale 1ns/1ps
// Preset and custom requests share one arbiter and one atomic NCO parameter owner.
module hil20_control(
    input wire clk,rst,key0_press,key1_press,
    input wire req_valid,output wire req_ready,input wire [1:0] req_kind,
    input wire [4:0] req_mode,input wire req_enable,
    input wire [1:0] req_frequency_index,input wire signed [10:0] req_angle_tenths,
    output reg rsp_valid,output reg [3:0] rsp_code,output reg [4:0] rsp_mode,output reg rsp_enable,
    output reg rsp_custom_active,output reg [1:0] rsp_frequency_index,
    output reg signed [10:0] rsp_angle_tenths,
    output wire custom_active,output wire [1:0] active_frequency_index,
    output wire signed [10:0] active_angle_tenths,
    output wire [4:0] mode_index,output wire [31:0] frequency_word,
    output wire signed [31:0] phase_offset_word,output wire [13:0] amplitude,
    output wire wave_sel,output wire output_enable,restart_pulse,
    output wire busy,output reg key_overflow
);
    reg target_enable;
    reg [2:0] wait_cycles;
    reg owner_remote,preempted;
    reg [1:0] owner_kind;
    reg [3:0] completion_code;
    reg [4:0] pending_key0;
    reg pending_key1;
    wire [5:0] k0_available={1'b0,pending_key0}+key0_press;
    wire k1_available=pending_key1 ^ key1_press;
    wire off_now=key1_press && target_enable;
    wire use_key1=(!busy && k1_available)||off_now;
    wire use_key0=!busy && !k1_available && !off_now && k0_available!=0;
    wire use_remote=!busy && !k1_available && !off_now && k0_available==0 && req_valid;
    wire set_mode=use_remote && req_kind==0 && req_mode<20 && req_mode!=mode_index;
    wire custom_range_ok=($signed(req_angle_tenths)>=-11'sd900 && $signed(req_angle_tenths)<=11'sd900);
    wire same_custom=custom_active && req_frequency_index==active_frequency_index && req_angle_tenths==active_angle_tenths;
    wire start_custom=use_remote && req_kind==3 && custom_range_ok && !same_custom;
    reg [1:0] pending_frequency_index;
    reg signed [10:0] pending_angle_tenths;
    wire map_valid;
    wire [31:0] mapped_frequency_word;
    wire signed [31:0] mapped_phase_word;
    hil_angle_mapper mapper(.clk(clk),.rst(rst),.start(start_custom),.frequency_index(req_frequency_index),
        .angle_tenths(req_angle_tenths),.valid(map_valid),.frequency_word(mapped_frequency_word),.phase_word(mapped_phase_word));
    assign busy=(wait_cycles!=0);
    assign req_ready=!busy;
    mode_select modes(.clk(clk),.rst(rst),.mode_press(use_key0),.target_enable(target_enable),
        .set_valid(set_mode),.set_mode(req_mode),.mode_index(mode_index),.frequency_word(frequency_word),
        .custom_set_valid(map_valid && busy && owner_remote && owner_kind==3),
        .custom_frequency_word(mapped_frequency_word),.custom_phase_word(mapped_phase_word),
        .custom_frequency_index(pending_frequency_index),.custom_angle_tenths(pending_angle_tenths),
        .custom_active(custom_active),.active_frequency_index(active_frequency_index),.active_angle_tenths(active_angle_tenths),
        .phase_offset_word(phase_offset_word),.amplitude(amplitude),.wave_sel(wave_sel),
        .enable(output_enable),.restart_pulse(restart_pulse));
    always @(posedge clk)begin
        if(rst)begin
            target_enable<=0;wait_cycles<=0;owner_remote<=0;owner_kind<=0;preempted<=0;completion_code<=0;
            pending_key0<=0;pending_key1<=0;key_overflow<=0;rsp_valid<=0;rsp_code<=0;rsp_mode<=0;rsp_enable<=0;
            pending_frequency_index<=0;pending_angle_tenths<=0;
            rsp_custom_active<=0;rsp_frequency_index<=0;rsp_angle_tenths<=0;
        end else begin
            rsp_valid<=0;
            // Physical key events are retained during a short remote commit.
            if(k0_available>31)begin pending_key0<=31;key_overflow<=1;end
            else pending_key0<=k0_available-use_key0;
            if(!busy)pending_key1<=0;
            else if(key1_press && !off_now)pending_key1<=~pending_key1;
            if(off_now)begin
                target_enable<=0;
                if(owner_remote && owner_kind==1)preempted<=1;
            end
            if(busy)begin
                wait_cycles<=wait_cycles-1'b1;
                if(wait_cycles==1 && owner_remote)begin
                    rsp_valid<=1;rsp_code<=(preempted || (off_now && owner_kind==1))?4'd8:completion_code;
                    rsp_mode<=mode_index;rsp_enable<=output_enable;
                    rsp_custom_active<=custom_active;rsp_frequency_index<=active_frequency_index;rsp_angle_tenths<=active_angle_tenths;
                end
            end else if(use_key1 || use_key0)begin
                if(use_key1)target_enable<=~target_enable;
                wait_cycles<=3;owner_remote<=0;preempted<=0;
                // A same-edge UART transaction loses to the key, explicitly.
                if(req_valid)begin rsp_valid<=1;rsp_code<=4;rsp_mode<=mode_index;rsp_enable<=output_enable;
                    rsp_custom_active<=custom_active;rsp_frequency_index<=active_frequency_index;rsp_angle_tenths<=active_angle_tenths;end
            end else if(use_remote)begin
                if(req_kind==2)begin rsp_valid<=1;rsp_code<=2;rsp_mode<=mode_index;rsp_enable<=output_enable;
                    rsp_custom_active<=custom_active;rsp_frequency_index<=active_frequency_index;rsp_angle_tenths<=active_angle_tenths;end
                else if((req_kind==0 && req_mode>=20) || (req_kind==3 && !custom_range_ok))begin
                    rsp_valid<=1;rsp_code<=3;rsp_mode<=mode_index;rsp_enable<=output_enable;
                    rsp_custom_active<=custom_active;rsp_frequency_index<=active_frequency_index;rsp_angle_tenths<=active_angle_tenths;
                end else begin
                    owner_remote<=1;owner_kind<=req_kind;preempted<=0;wait_cycles<=start_custom?6:3;
                    completion_code<=((req_kind==0 && req_mode==mode_index)||(req_kind==1 && req_enable==target_enable)||
                        (req_kind==3 && same_custom))?4'd1:4'd0;
                    if(req_kind==1)target_enable<=req_enable;
                    if(start_custom)begin pending_frequency_index<=req_frequency_index;pending_angle_tenths<=req_angle_tenths;end
                end
            end
        end
    end
endmodule
