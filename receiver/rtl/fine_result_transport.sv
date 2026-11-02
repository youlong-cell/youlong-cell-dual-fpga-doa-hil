`timescale 1ns/1ps
// 完整结果传输策略：ADC身份去重与epoch准入、AXI单次在途读和不可变快照。
// 不拥有XPM复位或恢复状态机，不生成RESULT_ACK，不改34字ABI。
module fine_result_transport (
    input wire adc_clk,adc_resetn,axi_clk,axi_resetn,
    input wire result_valid,
    input wire [1087:0] result_packet,
    input wire command_done,
    input wire [7:0] command_status,command_opcode,
    input wire [127:0] command_tag,
    input wire fifo_recovery_start_adc,
    input wire full,wr_reset_busy,rd_reset_busy,empty,data_valid,
    input wire [1087:0] fifo_data,
    input wire fifo_rst_adc,fifo_online_adc,fifo_local_reset_pending,fifo_recover_req_adc,
    input wire hold_adc,hold_axi,fifo_read_ready_axi,
    input wire fifo_generation_changed_axi,fifo_fence_start_axi,control_ready_axi,
    input wire command_response_success,
    input wire [3:0] request_opcode,
    input wire [239:0] cmd_hold,
    output wire fifo_read,wr_en,
    output reg [127:0] sent_key,
    output reg sent,
    output reg [63:0] fifo_epoch_adc=0,
    output reg [1087:0] snapshot,
    output reg snapshot_valid,fifo_read_pending,
    output reg [63:0] installed_epoch
);
    always @(posedge adc_clk) begin
        if(!adc_resetn || fifo_recovery_start_adc) fifo_epoch_adc<=0;
        else if(command_done && command_status==0) begin
            if(command_opcode==3) fifo_epoch_adc<=command_tag[63:0];
            if(command_opcode==4) fifo_epoch_adc<=0;
        end
    end
    assign fifo_read=!empty && !rd_reset_busy && !snapshot_valid && !hold_axi &&
                   !fifo_read_pending && fifo_read_ready_axi;
    assign wr_en=result_valid && (!sent || sent_key!=result_packet[127:0]) &&
               !full && !wr_reset_busy && !fifo_rst_adc && fifo_online_adc &&
               !fifo_local_reset_pending && !fifo_recover_req_adc && adc_resetn &&
               !hold_adc && fifo_epoch_adc!=0 && result_packet[63:0]==fifo_epoch_adc;
    always @(posedge adc_clk) begin
        if(!adc_resetn || fifo_recovery_start_adc) begin sent<=0;sent_key<=0; end
        else if(!result_valid) sent<=0;
        else if(wr_en) begin sent<=1;sent_key<=result_packet[127:0]; end
    end
    always @(posedge axi_clk) begin
        if(!axi_resetn) begin
            snapshot<=0;snapshot_valid<=0;installed_epoch<=0;fifo_read_pending<=0;
        end else begin
            if(fifo_read) fifo_read_pending<=1;
            if(data_valid) fifo_read_pending<=0;
            // Reject old-session messages rather than relabeling them.
            if(data_valid && fifo_read_pending && fifo_read_ready_axi && !rd_reset_busy &&
               !fifo_generation_changed_axi && fifo_data[63:0]==installed_epoch && installed_epoch!=0) begin
                if(!snapshot_valid) begin snapshot<=fifo_data;snapshot_valid<=1; end
            end
            if(command_response_success) begin
                    if(request_opcode==3) begin installed_epoch<=cmd_hold[63:0];snapshot_valid<=0;end
                    if(request_opcode==4) begin installed_epoch<=0;snapshot_valid<=0; end
                    if(request_opcode==9 && snapshot[127:0]==cmd_hold[127:0]) snapshot_valid<=0;
            end
            // 撤销有效性最后执行，保持原先高于读返回和ACK竞争的优先级。
            if(!fifo_read_ready_axi || rd_reset_busy || fifo_generation_changed_axi)
                snapshot_valid<=0;
            if(fifo_fence_start_axi) installed_epoch<=0;
            if(rd_reset_busy) fifo_read_pending<=0;
            if(hold_axi) snapshot_valid<=0;
            if(!control_ready_axi) begin installed_epoch<=0;snapshot_valid<=0;end
        end
    end
endmodule
