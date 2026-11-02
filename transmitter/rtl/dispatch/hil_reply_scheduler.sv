`timescale 1ns/1ps
// 原子request采纳、响应槽预留、pending事件与溢出管理；不拆散其优先级。
module hil_reply_scheduler #(parameter integer REPLY_DEPTH=4)(
    input wire clk,serial_rst,parser_event,
    input wire [3:0] parser_error,input wire [1:0] parser_kind,
    input wire [4:0] parser_mode,input wire parser_enable,
    input wire [1:0] parser_frequency_index,input wire signed [10:0] parser_angle_tenths,
    input wire req_ready,rsp_valid,input wire [3:0] rsp_code,
    input wire [4:0] rsp_mode,input wire rsp_enable,
    input wire rsp_custom_active,input wire [1:0] rsp_frequency_index,input wire signed [10:0] rsp_angle_tenths,
    input wire [4:0] mode_index,input wire output_enable,formatter_ready,
    input wire custom_active,input wire [1:0] active_frequency_index,input wire signed [10:0] active_angle_tenths,
    output reg req_valid,output reg [1:0] req_kind,output reg [4:0] req_mode,
    output reg req_enable,output wire reply_valid,output wire [9:0] front,
    output reg [1:0] req_frequency_index,output reg signed [10:0] req_angle_tenths,
    output wire [23:0] full_front,
    output wire [31:0] dropped_reply_count,
    output reg inflight,pending_event,overflow_notice,
    output wire [((REPLY_DEPTH>1)?$clog2(REPLY_DEPTH):1):0] count
);
    reg [3:0] pending_error;
    reg [1:0] pending_kind;
    reg [4:0] pending_mode;
    reg pending_enable;
    reg [1:0] pending_frequency_index;
    reg signed [10:0] pending_angle_tenths;
    reg [31:0] dropped_count;
    assign dropped_reply_count=dropped_count;
    assign reply_valid=(count!=0);
    wire pop=(count!=0) && formatter_ready;
    reg push,launch,consume_pending,lose_event,consume_overflow;
    reg [23:0] push_data;
    assign front=full_front[9:0];
    wire room=(count < (inflight?REPLY_DEPTH-1:REPLY_DEPTH));
    always @*begin
        push=0;push_data=0;launch=0;consume_pending=0;lose_event=0;consume_overflow=0;
        if(rsp_valid && inflight)begin
            push=1;push_data={rsp_custom_active,rsp_frequency_index,rsp_angle_tenths,rsp_code,rsp_mode,rsp_enable};
        end else if(pending_event)begin
            consume_pending=1;
            if(pending_error!=0)begin
                if(room)begin push=1;push_data={custom_active,active_frequency_index,active_angle_tenths,pending_error,mode_index,output_enable};end
                else lose_event=1;
            end else if(!inflight && !req_valid && count<REPLY_DEPTH-1)launch=1;
            else if(room)begin push=1;push_data={custom_active,active_frequency_index,active_angle_tenths,4'd4,mode_index,output_enable};end
            else lose_event=1;
        end else if(overflow_notice && room)begin
            push=1;push_data={custom_active,active_frequency_index,active_angle_tenths,4'd9,mode_index,output_enable};consume_overflow=1;
        end
    end
    hil_reply_fifo #(.DEPTH(REPLY_DEPTH),.WIDTH(24)) fifo(
        .clk(clk),.rst(serial_rst),.push(push),.pop(pop),
        .push_data(push_data),.front(full_front),.count(count));
    always @(posedge clk)begin
        if(serial_rst)begin
            req_valid<=0;req_kind<=0;req_mode<=0;req_enable<=0;inflight<=0;
            pending_event<=0;pending_error<=0;pending_kind<=0;pending_mode<=0;pending_enable<=0;
            overflow_notice<=0;dropped_count<=0;
            pending_frequency_index<=0;pending_angle_tenths<=0;req_frequency_index<=0;req_angle_tenths<=0;
        end else begin
            if(req_valid && req_ready)req_valid<=0;
            if(rsp_valid && inflight)inflight<=0;
            if(consume_pending)pending_event<=0;
            if(launch)begin
                req_valid<=1;inflight<=1;req_kind<=pending_kind;req_mode<=pending_mode;req_enable<=pending_enable;
                req_frequency_index<=pending_frequency_index;req_angle_tenths<=pending_angle_tenths;
            end
            if(consume_overflow)overflow_notice<=0;
            if(lose_event || (parser_event && pending_event && !consume_pending))begin
                overflow_notice<=1;
                if(dropped_count!=32'hffffffff)dropped_count<=dropped_count+1'b1;
            end
            if(parser_event && (!pending_event || consume_pending))begin
                pending_event<=1;pending_error<=parser_error;pending_kind<=parser_kind;
                pending_mode<=parser_mode;pending_enable<=parser_enable;
                pending_frequency_index<=parser_frequency_index;pending_angle_tenths<=parser_angle_tenths;
            end
        end
    end
endmodule
