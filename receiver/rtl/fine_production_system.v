`timescale 1ns/1ps
// Verilog-2001 module_ref entry (Vivado 2023.1 rejects a SystemVerilog top).
// Production integration, ADC=62.499374MHz; control/result AXI=100MHz.
// STOP is an explicit destructive transaction abort, not ordinary RELEASE.
// Local hardware reset never depends on the remote domain or STOP. Maintenance
// synchronously aborts/drains owners, preserves timebase and committed counters,
// and waits for real AXI/FIFO completion. INSTALL is control-ready, ARM is traffic-ready.
module fine_production_system (
    input wire adc_clk,adc_resetn,axi_clk,axi_resetn,
    input wire sample_tick,input wire [47:0] sample_id,current_sample_id,
    input wire current_valid,input wire [11:0] adc_ch0_data,adc_ch1_data,
    input wire frame_done,frame_abort,frame_error,
    input wire [47:0] frame_start_sample_id,
    input wire fft_bram_en,input wire [7:0] fft_bram_we,
    input wire [31:0] fft_bram_addr,input wire [63:0] fft_bram_data,
    input wire [31:0] ps_command_word,ps_payload_word,
    output wire [31:0] ps_status_word,ps_response_word,
    input wire [31:0] fine_command_word,fine_payload_word,
    output wire [31:0] fine_status_word,fine_response_word,
    output wire cordic_aresetn,
    output wire sqrt_in_valid,input wire sqrt_in_ready,output wire [47:0] sqrt_in_data,
    input wire sqrt_out_valid,output wire sqrt_out_ready,input wire [47:0] sqrt_out_data,
    output wire translate_in_valid,input wire translate_in_ready,output wire [79:0] translate_in_data,
    input wire translate_out_valid,output wire translate_out_ready,input wire [79:0] translate_out_data
);
    wire link_adc_reset,link_axi_reset,pipe_adc_reset,pipe_axi_reset;
    // proc_sys_reset has already synchronized deassertion to each clock.
    assign link_adc_reset=!adc_resetn;
    assign link_axi_reset=!axi_resetn;
    assign pipe_adc_reset=!adc_resetn;
    assign pipe_axi_reset=!axi_resetn;
    reg pipe_hold_adc;
    wire pipe_hold_axi;
    wire pipeline_hold=pipe_hold_adc; // compatibility/debug alias, NOT a reset.
    wire bridge_maintenance_done,bridge_released,control_ready_adc,chain_maintenance_ready,fine_maintenance_ready;
    wire adc_stop_done=pipe_hold_adc && chain_maintenance_ready && fine_maintenance_ready;
    wire axi_stop_done=bridge_maintenance_done;
    wire stopped=adc_stop_done && axi_stop_done && !bridge_released && control_ready_adc;
    reg traffic_ready,fine_committed_session;
    wire command_valid;wire [7:0] op,index;wire [31:0] data;wire [127:0] tag;
    reg command_done;reg [7:0] command_status;reg [31:0] command_response;
    wire [1087:0] result_packet;wire result_valid;
    reg session_valid;reg [63:0] session_epoch,last_epoch=0;
    reg [47:0] session_sample_floor;
    reg [3:0] control_state;
    fine_production_bridge #(.ENABLE_MAINTENANCE(1)) bridge (
        .adc_clk(adc_clk),.adc_resetn(!link_adc_reset),.axi_clk(axi_clk),.axi_resetn(!link_axi_reset),
        .command_word(fine_command_word),.payload_word(fine_payload_word),
        .status_word(fine_status_word),.response_word(fine_response_word),
        .command_valid(command_valid),.command_opcode(op),.command_index(index),
        .command_data(data),.command_tag(tag),.command_done(command_done),
        .command_status(command_status),.command_response(command_response),
        .result_valid(result_valid && session_valid && traffic_ready),.result_packet(result_packet),
        .maintenance_hold_adc(pipe_hold_adc),.maintenance_hold_axi(pipe_hold_axi),
        .command_accept_ready(control_state==0),
        .maintenance_done_adc(bridge_maintenance_done),.maintenance_released_adc(bridge_released),
        .control_ready_adc(control_ready_adc));
    reg boundary_seen;
    reg [31:0] abort_count;
    reg cfg_write,cfg_commit,mode_write,requested_mode,result_ack,clear_fault,ps_release;
    wire cfg_ready,commit_ready,commit_ack,cfg_error;
    wire [7:0] commit_status;wire [31:0] config_version;
    wire mode_ack,mode_granted,mode_active;
    wire ack_response,ack_granted,clear_ack,clear_granted,release_ack,release_granted;
    wire manager_active,manager_fault;wire [31:0] fault_seq;
    wire [223:0] fault_meta;
    wire fine_fault_valid;wire [7:0] fine_fault_code;wire [4:0] fine_state;
    wire [31:0] result_drop_count,result_protocol_count;
    wire [31:0] busy_drop_count;
    reg fine_clear_pending;
    reg [31:0] det_shadow[0:3],det_active[0:3];reg [3:0] det_written;
    reg det_committed;
    wire det_valid_encoding=det_shadow[0][31:19]==0 &&
        det_shadow[0][9:1]!=0 && det_shadow[0][9:1]<=det_shadow[0][18:10] &&
        det_shadow[1]!=0 && det_shadow[2]!=0 && det_shadow[3]!=0;
    wire offer_valid,offer_ready;wire [31:0] offer_seq;wire [479:0] offer_meta;
    wire [63:0] offer_epoch;
    wire rd_req,rd_ready,rd_valid;wire [11:0] rd_addr,rd_index;wire [31:0] rd_data;
    wire fine_busy,fine_done,fine_fault,fine_latched,fine_abort;
    wire fine_clear=fine_clear_pending && !manager_active && !fine_abort;
    wire [31:0] fine_seq,release_seq;
    wire fine_release_ack,fine_release_granted;
    fft_candidate_chain #(.ENABLE_PL_CONSUMER(1),.PRODUCTION_CONTROL(1)) chain (
        .adc_clk(adc_clk),.adc_resetn(!pipe_adc_reset),.axi_clk(axi_clk),.axi_resetn(!pipe_axi_reset),
        .sample_tick(sample_tick),.sample_id(sample_id),.current_sample_id(current_sample_id),
        .current_valid(current_valid),.adc_ch0_data(adc_ch0_data),.adc_ch1_data(adc_ch1_data),
        .frame_done(frame_done),.frame_abort(frame_abort),.frame_error(frame_error),
        .frame_start_sample_id(frame_start_sample_id),.fft_bram_en(fft_bram_en),
        .fft_bram_we(fft_bram_we),.fft_bram_addr(fft_bram_addr),.fft_bram_data(fft_bram_data),
        .ps_command_word(ps_command_word),.ps_payload_word(ps_payload_word),
        .ps_status_word(ps_status_word),.ps_response_word(ps_response_word),
        .consumer_mode_valid(mode_write),.consumer_mode(requested_mode),
        .consumer_mode_ack(mode_ack),.consumer_mode_granted(mode_granted),.consumer_mode_active(mode_active),
        .window_offer_valid(offer_valid),.window_offer_ready(offer_ready),
        .window_offer_seq(offer_seq),.window_offer_meta(offer_meta),.window_offer_epoch(offer_epoch),
        .fine_rd_req(rd_req),.fine_rd_addr(rd_addr),.fine_rd_ready(rd_ready),.fine_rd_valid(rd_valid),
        .fine_rd_data(rd_data),.fine_rd_index(rd_index),.fine_busy(fine_busy),.fine_done(fine_done),
        .fine_fault(fine_fault),.fine_result_latched(fine_latched),.fine_seq(fine_seq),
        .fine_abort(fine_abort),.fine_release_ack(fine_release_ack),
        .fine_release_granted(fine_release_granted),.fine_release_seq(release_seq),
        .session_valid(session_valid),.session_epoch(session_epoch),
        .maintenance_hold_adc(pipe_hold_adc),.maintenance_hold_axi(pipe_hold_axi),
        .maintenance_ready_adc(chain_maintenance_ready),
        .session_sample_floor(session_sample_floor),
        .external_cfg_committed(det_committed),
        .external_cfg_enable(det_active[0][0] && boundary_seen && traffic_ready),
        .external_bin_min(det_active[0][9:1]),.external_bin_max(det_active[0][18:10]),
        .external_ch0_min(det_active[1]),.external_ch1_min(det_active[2]),.external_publish_min(det_active[3]),
        .external_release_valid(ps_release),.external_clear_valid(clear_fault),
        .external_command_epoch(tag[63:0]),.external_command_seq(tag[95:64]),
        .external_release_ack(release_ack),.external_release_granted(release_granted),
        .external_clear_ack(clear_ack),.external_clear_granted(clear_granted),
        .production_active(manager_active),.production_fault(manager_fault),
        .production_busy_drop_count(busy_drop_count),
        .production_fault_seq(fault_seq),.production_fault_meta(fault_meta));
    fine_doa_engine #(.ENABLE_MAINTENANCE(1)) fine (
        .clk(adc_clk),.resetn(!pipe_adc_reset),
        .maintenance_hold(pipe_hold_adc),.maintenance_ready(fine_maintenance_ready),
        .cfg_shadow_valid(cfg_write),.cfg_shadow_ready(cfg_ready),
        .cfg_shadow_addr(index[4:0]),.cfg_shadow_data(data),.cfg_shadow_error(cfg_error),
        .cfg_commit_valid(cfg_commit),.cfg_commit_ready(commit_ready),
        .cfg_commit_ack(commit_ack),.cfg_commit_status(commit_status),.active_config_version(config_version),
        .session_valid(session_valid && traffic_ready && offer_epoch==session_epoch),.session_epoch(offer_epoch),
        .window_offer_valid(offer_valid),.window_offer_ready(offer_ready),
        .window_offer_seq(offer_seq),.window_offer_meta(offer_meta),
        .fine_rd_req(rd_req),.fine_rd_ready(rd_ready),.fine_rd_addr(rd_addr),
        .fine_rd_valid(rd_valid),.fine_rd_data(rd_data),.fine_rd_index(rd_index),
        .fine_busy(fine_busy),.fine_done(fine_done),.fine_fault(fine_fault),
        .fine_result_latched(fine_latched),.fine_seq(fine_seq),.fine_abort(fine_abort),
        .fine_release_ack(fine_release_ack),.fine_release_granted(fine_release_granted),.fine_release_seq(release_seq),
        .fault_clear(fine_clear),.fault_valid(fine_fault_valid),.fault_code(fine_fault_code),
        .result_valid(result_valid),.result_transport(result_packet),
        .result_ack_valid(result_ack),.result_ack_epoch(tag[63:0]),.result_ack_seq(tag[95:64]),
        .result_ack_config_version(tag[127:96]),.result_ack_response_valid(ack_response),.result_ack_granted(ack_granted),
        .result_drop_count(result_drop_count),.result_protocol_error_count(result_protocol_count),
        .lifecycle_state(fine_state),.cordic_aresetn(cordic_aresetn),
        .sqrt_in_valid(sqrt_in_valid),.sqrt_in_ready(sqrt_in_ready),.sqrt_in_data(sqrt_in_data),
        .sqrt_out_valid(sqrt_out_valid),.sqrt_out_ready(sqrt_out_ready),.sqrt_out_data(sqrt_out_data),
        .translate_in_valid(translate_in_valid),.translate_in_ready(translate_in_ready),.translate_in_data(translate_in_data),
        .translate_out_valid(translate_out_valid),.translate_out_ready(translate_out_ready),.translate_out_data(translate_out_data));
    integer j;
    always @(posedge adc_clk) begin
        if(link_adc_reset) begin
            session_valid<=0;session_epoch<=0;pipe_hold_adc<=1;
            traffic_ready<=0;fine_committed_session<=0;
            session_sample_floor<=0;
            boundary_seen<=0;control_state<=14;abort_count<=0;
            command_done<=0;command_status<=0;command_response<=0;
            cfg_write<=0;cfg_commit<=0;mode_write<=0;requested_mode<=0;
            result_ack<=0;clear_fault<=0;ps_release<=0;fine_clear_pending<=0;
            det_committed<=0;det_written<=0;
            for(j=0;j<4;j=j+1) begin det_shadow[j]<=0;det_active[j]<=0;end
        end else begin
            command_done<=0;cfg_write<=0;cfg_commit<=0;mode_write<=0;
            result_ack<=0;clear_fault<=0;ps_release<=0;
            if(fine_clear && fine_state==0) fine_clear_pending<=0;
            if(!session_valid) boundary_seen<=0;
            else if(frame_done || frame_abort) boundary_seen<=1;
            case(control_state)
                0: if(command_valid) begin
                    command_status<=0;command_response<=0;
                    case(op)
                        3: if(!session_valid && pipe_hold_adc && stopped && tag[63:0]!=0 && tag[63:0]>last_epoch) begin
                            session_epoch<=tag[63:0];last_epoch<=tag[63:0];
                            session_sample_floor<=sample_id;
                            control_state<=3;
                        end else begin command_status<=3;command_done<=1;end
                        4: begin
                            session_valid<=0;pipe_hold_adc<=1;traffic_ready<=0;
                            fine_committed_session<=0;control_state<=4;
                            abort_count<=(&abort_count)?abort_count:abort_count+1'b1;
                            det_committed<=0;det_written<=0;fine_clear_pending<=0;
                        end
                        11: begin
                            if(index==0) command_response<={16'hf101,8'd0,traffic_ready,pipe_hold_adc,
                                fine_fault_valid,manager_fault,manager_active,mode_active,session_valid,result_valid};
                            else if(index==1) command_response<=config_version;
                            else if(index==2) command_response<=abort_count;
                            else if(index==3) command_response<=session_epoch[31:0];
                            else if(index==4) command_response<=session_epoch[63:32];
                            else if(index==16) command_response<=result_drop_count;
                            else if(index==17) command_response<=result_protocol_count;
                            else if(index==18) command_response<={24'd0,fine_fault_code};
                            else if(index==19) command_response<=busy_drop_count;
                            else if(index>=8 && index<15 && manager_fault)
                                command_response<=fault_meta[(index-8)*32+:32];
                            else begin command_status<=1;command_response<=0;end
                            command_done<=1;
                        end
                        default: if(!session_valid) begin command_status<=3;command_done<=1;end
                        else case(op)
                            1: if(index<24 && cfg_ready) begin cfg_write<=1;control_state<=1;end
                               else begin command_status<=1;command_done<=1;end
                            2: if(commit_ready) begin cfg_commit<=1;control_state<=2;end
                               else begin command_status<=4;command_done<=1;end
                            5: if(data<2 && (!data[0] || !traffic_ready || fine_committed_session)) begin
                                   mode_write<=1;requested_mode<=data[0];control_state<=5;
                               end
                               else begin command_status<=1;command_done<=1;end
                            6: if(index<4) begin det_shadow[index[1:0]]<=data;
                                   det_written[index[1:0]]<=1;command_done<=1;end
                               else begin command_status<=1;command_done<=1;end
                            7: begin
                                if(&det_written && det_valid_encoding) begin
                                    for(j=0;j<4;j=j+1) det_active[j]<=det_shadow[j];
                                    det_committed<=1;det_written<=0;
                                    // COMMIT completes the two-stage ARM only
                                    // when Fine configuration is installed too.
                                    if(!mode_active || fine_committed_session) begin
                                        pipe_hold_adc<=0;control_state<=13;
                                    end else begin command_status<=4;command_done<=1;end
                                end else command_status<=1;
                                if(!(&det_written && det_valid_encoding)) command_done<=1;
                            end
                            9: begin result_ack<=1;control_state<=9;end
                            10: if(tag[63:0]==session_epoch && manager_fault && tag[95:64]==fault_seq) begin
                                    clear_fault<=1;control_state<=10;
                                end else begin command_status<=5;command_done<=1;end
                            12: if(tag[63:0]==offer_epoch && !mode_active) begin
                                    ps_release<=1;control_state<=12;
                                end else begin command_status<=5;command_done<=1;end
                            default: begin command_status<=1;command_done<=1;end
                        endcase
                    endcase
                end
                1: begin command_status<=cfg_error?8'd1:8'd0;command_done<=1;control_state<=0;end
                2: if(commit_ack) begin command_status<=commit_status;command_response<=config_version;
                        fine_committed_session<=commit_status==0;
                        if(commit_status==0 && det_committed && pipe_hold_adc) begin
                            pipe_hold_adc<=0;control_state<=13;
                        end else begin command_done<=1;control_state<=0;end
                    end
                3: if(stopped) begin session_valid<=1;command_done<=1;control_state<=0;end
                4: if(stopped) begin command_done<=1;control_state<=0;end
                13: if(bridge_released && !bridge_maintenance_done) begin
                        traffic_ready<=1;command_done<=1;control_state<=0;
                    end
                14: if(stopped) control_state<=0; // reset recovery, no software success.
                5: if(mode_ack) begin command_status<=mode_granted?8'd0:8'd4;command_done<=1;control_state<=0;end
                9: if(ack_response) begin command_status<=ack_granted?8'd0:8'd5;command_done<=1;control_state<=0;end
                10: if(clear_ack) begin command_status<=clear_granted?8'd0:8'd5;
                    fine_clear_pending<=clear_granted;command_done<=1;control_state<=0;end
                12: if(release_ack) begin command_status<=release_granted?8'd0:8'd5;command_done<=1;control_state<=0;end
                default: begin
                    session_valid<=0;pipe_hold_adc<=1;traffic_ready<=0;
                    fine_committed_session<=0;det_committed<=0;control_state<=14;
                end
            endcase
            // Remote reset is a synchronous protocol invalidation, never a
            // PRE/CLR source. Canceled commands are drained by the bridge.
            if(!control_ready_adc) begin
                session_valid<=0;pipe_hold_adc<=1;traffic_ready<=0;
                fine_committed_session<=0;det_committed<=0;det_written<=0;
                cfg_write<=0;cfg_commit<=0;mode_write<=0;result_ack<=0;
                clear_fault<=0;ps_release<=0;fine_clear_pending<=0;
                command_done<=0;control_state<=14;
            end
        end
    end
endmodule
