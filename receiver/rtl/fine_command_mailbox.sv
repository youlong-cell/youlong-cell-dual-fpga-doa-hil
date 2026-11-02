`timescale 1ns/1ps
// 命令/响应邮箱的保持寄存器与传输身份；跨域仍通过主控中原XPM实例。
// 没有运行时复位端：必须保留在途payload/send/ACK，由主控四相屏障取消并排空。
// 不拥有恢复ready，不处理GPIO本地命令，不接收结果FIFO，不新增流水。
module fine_command_mailbox #(parameter integer ENABLE_MAINTENANCE=0) (
    input wire adc_clk,axi_clk,
    input wire control_ready_adc,control_ready_axi,command_launch,
    input wire [31:0] command_word,payload_word,
    input wire [127:0] tags,
    input wire command_accept_ready,command_done,
    input wire [7:0] command_status,
    input wire [31:0] command_response,
    input wire cmd_received,cmd_req,
    input wire [239:0] cmd_adc,
    input wire rsp_received,rsp_req,
    input wire [103:0] rsp_axi,
    output wire command_valid,
    output wire [7:0] command_opcode,command_index,
    output wire [31:0] command_data,
    output wire [127:0] command_tag,
    output wire response_match,
    output reg [239:0] cmd_hold=0,
    output reg cmd_send=0,cmd_ack_adc=0,cmd_seen_adc=0,cmd_canceled_adc=0,
    output reg [63:0] transport_id=0,
    output reg control_inflight=0,
    output reg [103:0] rsp_hold=0,
    output reg rsp_send=0,rsp_ack=0,rsp_seen=0
);
    assign {command_opcode,command_index,command_data,command_tag}=cmd_adc[175:0];
    assign command_valid=cmd_req && !cmd_seen_adc && control_ready_adc &&
                         !rsp_send && !rsp_received &&
                         (!ENABLE_MAINTENANCE || command_accept_ready);
    assign response_match=control_ready_axi && control_inflight &&
                        rsp_axi[103:40]==cmd_hold[239:176];
    always @(posedge adc_clk) begin
        if(!control_ready_adc && cmd_req) begin
            cmd_seen_adc<=1;cmd_canceled_adc<=1;cmd_ack_adc<=1;
        end else begin
            if(command_valid) cmd_seen_adc<=1;
            if(command_done && cmd_req && cmd_seen_adc && !cmd_canceled_adc && !cmd_ack_adc) begin
                cmd_ack_adc<=1;
                rsp_hold<={cmd_adc[239:176],command_status,command_response};rsp_send<=1;
            end
        end
        if(!cmd_req) begin cmd_ack_adc<=0;cmd_seen_adc<=0;cmd_canceled_adc<=0; end
        if(rsp_received) rsp_send<=0;
    end
    always @(posedge axi_clk) begin
        if(cmd_received) cmd_send<=0;
        if(!control_ready_axi) control_inflight<=0;
        if(command_launch) begin
            transport_id<=transport_id+1'b1;
            cmd_hold<={transport_id+64'd1,{4'd0,command_word[27:24]},command_word[7:0],payload_word,tags};
            cmd_send<=1;control_inflight<=1;
        end
        if(rsp_req && !rsp_seen) begin
            rsp_seen<=1;rsp_ack<=1;control_inflight<=0;
        end
        if(rsp_req && rsp_seen) rsp_ack<=1;
        if(!rsp_req) begin rsp_seen<=0;rsp_ack<=0;end
    end
endmodule
