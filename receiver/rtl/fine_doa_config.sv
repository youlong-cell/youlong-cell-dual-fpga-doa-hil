`timescale 1ns/1ps
// Fine的24字配置寄存器组：影子写入、完整性、原子提交、版本与质量编码检查。
// 与校准模块的ready联锁保持原式；维护取消在本拍最后清written。
// 这里只检查原有编码，不新增、更改或放宽校准有效性规则。
module fine_doa_config (
    input wire clk, resetn, maintenance_cancel,
    input wire cfg_shadow_valid,
    output wire cfg_shadow_ready,
    input wire [4:0] cfg_shadow_addr,
    input wire [31:0] cfg_shadow_data,
    output reg cfg_shadow_error,
    input wire cfg_commit_valid,
    output wire cfg_commit_ready,
    output reg cfg_commit_ack,
    output reg [7:0] cfg_commit_status,
    output reg [31:0] active_config_version,
    input wire cal_shadow_ready, cal_commit_ready,
    output wire cfg_complete, commit_install, bad_quality_encoding,
    output wire [23:0] written,
    output wire [767:0] active_words
);
    localparam integer CONFIG_WORDS=24;
    reg [31:0] shadow[0:23], active[0:23];
    reg [23:0] written_q;
    assign written = written_q;
    genvar word_index;
    generate for(word_index=0; word_index<24; word_index=word_index+1) begin: expose_active
        assign active_words[word_index*32 +: 32] = active[word_index];
    end endgenerate
    assign cfg_complete=&written;
    assign commit_install=cfg_commit_valid && cfg_commit_ready && cfg_complete &&
                          active_config_version!=32'hffffffff;
    assign cfg_shadow_ready=resetn && !cfg_commit_valid && cal_shadow_ready;
    assign cfg_commit_ready=resetn && cal_commit_ready;
    assign bad_quality_encoding=active[11]>32'd1 || active[13][31:5]!=0 ||
                                active[15][31:6]!=0 || active[17][31:1]!=0;
    integer j;
    always @(posedge clk) begin
        if(!resetn) begin
            written_q<=0; active_config_version<=0; cfg_shadow_error<=0;
            cfg_commit_ack<=0; cfg_commit_status<=0;
            for(j=0;j<CONFIG_WORDS;j=j+1) begin shadow[j]<=0; active[j]<=0; end
        end else begin
            cfg_shadow_error<=0; cfg_commit_ack<=0;
            if(cfg_shadow_valid && cfg_shadow_ready) begin
                if(cfg_shadow_addr<CONFIG_WORDS) begin
                    shadow[cfg_shadow_addr]<=cfg_shadow_data; written_q[cfg_shadow_addr]<=1;
                end else cfg_shadow_error<=1;
            end
            if(cfg_commit_valid && cfg_commit_ready) begin
                cfg_commit_ack<=1;
                if(!cfg_complete) cfg_commit_status<=1;
                else if(active_config_version==32'hffffffff) cfg_commit_status<=2;
                else begin
                    for(j=0;j<CONFIG_WORDS;j=j+1) active[j]<=shadow[j];
                    active_config_version<=active_config_version+32'd1;
                    written_q<=0; cfg_commit_status<=0;
                end
            end
            // 维护取消只撤销未完成影子事务，不抹除已提交配置。
            if(maintenance_cancel) written_q<=0;
        end
    end
endmodule
