`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Dual-channel spectrum accelerator controller                                  //
//                                                                              //
// A start event captures 1024 simultaneous ADC samples, subtracts each          //
// channel's block mean, applies a signed Q1.15 Hann window and sends CH0 then    //
// CH1 through one shared Xilinx FFT v9.1 core. The first 512 natural-order bins  //
// from each channel are written through a two-bank owner to result BRAM:        //
//   address   0..511 : CH0 {imag[31:0], real[31:0]}                             //
//   address 512..1023: CH1 {imag[31:0], real[31:0]}                             //
//                                                                              //
// Clock domains: adc_clk owns capture/FFT/BRAM; axi_clk owns GPIO status.       //
// Legacy commands use toggles; autonomous search uses a held run-enable level.  //
//                                                                              //
// Sample timeline (frozen rule, docs/DECISIONS.md D027):                        //
//   In the autonomous / continuous configuration this module does NOT own a      //
//   timeline. It CONSUMES the system's single absolute sample counter through    //
//   external_sample_id (USE_EXTERNAL_SAMPLE_ID=1). Only the shipping one-shot    //
//   PS-rearmed mode keeps a local free-running counter (=0). Exactly one counter //
//   register exists in either configuration; the two sources are never both      //
//   live, and with =1 the local register and its adder are trimmed away.         //
//   The active timeline is the pre-edge next_sample_id shared with Ring. The   //
//   external sample_tick gates every capture-side state update, so             //
//   frame_start_sample_id is the id of the first accepted sample              //
//   and frame_end_sample_id = frame_start_sample_id + 1023.                      //
//                                                                              //
// status[0]     busy, synchronized to axi_clk                                   //
// status[1]     done toggle, changes after both channels complete               //
// status[2]     sticky FFT protocol/error indication                            //
// status[3]     channel currently being processed                               //
// status[31:16] completed frame counter (Gray CDC, binary in AXI domain)        //
//////////////////////////////////////////////////////////////////////////////////
// Revision History:                                                            //
// Date        Revision  Change Description                                     //
// ---------------------------------------------------------------------------  //
// 2026/09/20  1.0       Dual-channel capture, Hann window and shared FFT       //
// 2026/09/20  1.1       Documented AXI/ADC CDC and BRAM result format          //
// 2026/09/23  1.2       Gray counter CDC and bounded FFT progress watchdog     //
// 2026/09/28  1.3       Shared sample timeline: frame start/end ids,            //
//                       frame_done_pulse, captured_sample_count; optional       //
//                       external timeline (USE_EXTERNAL_SAMPLE_ID) so the        //
//                       absolute counter can be owned by sample_timebase;        //
//                       AUTO_RESTART autonomous framing prototype               //
//////////////////////////////////////////////////////////////////////////////////
module spectrum_fft_ctrl #(
    // Abort a frame if config, input, or output makes no progress for this
    // many adc_clk cycles. 1,048,576 cycles is about 16.8 ms at 62.499374 MHz.
    parameter integer FFT_PROGRESS_TIMEOUT_CYCLES = 1048576,
    // 0 preserves the original PS-rearmed interface.  1 is autonomous framing
    // with atomic double-bank result ownership in the current BD.
    parameter integer AUTO_RESTART = 0,
    // 0 keeps the shipping free-running local counter (one-shot PS-rearmed
    // mode, bit-identical to revision 1.2). 1 makes this module consume the
    // system sample timeline supplied on external_sample_id and removes the
    // local counter entirely, so a second absolute counter cannot exist.
    parameter integer USE_EXTERNAL_SAMPLE_ID = 0
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 adc_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME adc_clk, ASSOCIATED_BUSIF fft_s_config:fft_s_data:fft_m_data, ASSOCIATED_RESET adc_resetn, FREQ_HZ 62499374" *)
    input  wire        adc_clk,       // ADC/FFT processing clock
    input  wire        adc_resetn,    // adc_clk reset, active low
    input  wire [11:0] adc_ch0_data,  // registered unsigned ADC channel 0
    input  wire [11:0] adc_ch1_data,  // registered unsigned ADC channel 1
    // Shares the timebase/Ring acceptance event in external-timeline mode.
    // Ignored in the existing one-shot BD configuration (parameter = 0).
    input  wire        sample_tick,

    // System-wide absolute sample timeline, produced by sample_timebase.
    // Only sampled when USE_EXTERNAL_SAMPLE_ID=1. Its value on a capture cycle
    // is the id of the pair presented on adc_ch0_data/adc_ch1_data.
    input  wire [47:0] external_sample_id,

    input  wire        axi_clk,       // AXI GPIO/status clock
    input  wire        axi_resetn,    // axi_clk reset, active low
    input  wire        start_toggle,  // AUTO_RESTART=0: toggle command;
                                      // AUTO_RESTART=1: run-enable level
    output wire [31:0] status,        // packed status register described above

    // adc_clk domain. The value of sample_counter IS the id of the pair
    // presented in the same cycle (one coherent CH0/CH1 pair per edge).
    // Driven by external_sample_id or by the local counter, never both.
    output wire [47:0] sample_counter,
    output reg  [47:0] frame_start_sample_id,
    output reg  [47:0] frame_end_sample_id,
    output reg  [47:0] completed_start_sample_id,
    output reg  [47:0] completed_end_sample_id,
    output reg         frame_done_pulse,
    output reg         frame_begin_pulse, // ADC-domain result-bank reservation
    output reg         frame_abort_pulse, // watchdog terminated an incomplete frame
    output reg         completed_frame_error,
    output reg  [47:0] captured_sample_count,

    output wire [7:0]  fft_s_config_tdata,  // forward-transform configuration
    output reg         fft_s_config_tvalid,
    input  wire        fft_s_config_tready,

    output reg  [31:0] fft_s_data_tdata,
    output reg         fft_s_data_tvalid,
    input  wire        fft_s_data_tready,
    output reg         fft_s_data_tlast,

    input  wire [63:0] fft_m_data_tdata,
    input  wire [15:0] fft_m_data_tuser,
    input  wire        fft_m_data_tvalid,
    output wire        fft_m_data_tready,
    input  wire        fft_m_data_tlast,

    input  wire        fft_event_tlast_unexpected,
    input  wire        fft_event_tlast_missing,
    input  wire        fft_event_status_halt,
    input  wire        fft_event_data_in_halt,
    input  wire        fft_event_data_out_halt,

    output wire        bram_clkb,     // result BRAM port-B clock
    output wire        bram_rstb,     // result BRAM port-B reset, active high
    output wire        bram_enb,      // 子模块注册的BRAM写使能
    output wire [7:0]  bram_web,      // 每字节写使能
    output wire [31:0] bram_addrb,    // BRAM字节地址
    output wire [63:0] bram_dinb      // {虚部[31:0], 实部[31:0]}
);

    localparam integer FFT_N = 1024;

    // Processing state machine: capture once, then reuse one FFT for CH0/CH1.
    localparam [2:0] ST_IDLE    = 3'd0;
    localparam [2:0] ST_CAPTURE = 3'd1;
    localparam [2:0] ST_CONFIG  = 3'd2;
    localparam [2:0] ST_FEED    = 3'd3;
    localparam [2:0] ST_WAIT    = 3'd4;

    reg [2:0] state;

    // 主控只管理帧生命周期；采集缓存、预处理及结果写回各自独立。
    // 保留同名观察线，已有采样时序回归不依赖新的子模块层次。
    wire [9:0] capture_index;
    wire [22:0] sum_ch0, sum_ch1;
    wire [11:0] mean_ch0, mean_ch1;

    reg        active_channel;
    reg [10:0] feed_index;
    reg        busy_adc;
    reg        done_toggle_adc;
    reg        error_adc;
    reg [15:0] frame_counter_adc;
    reg [31:0] fft_watchdog_count;
    // Local free-running timeline, present ONLY for the shipping one-shot mode.
    // With USE_EXTERNAL_SAMPLE_ID=1 this register and its adder are trimmed.
    reg [47:0] sample_counter_q;

    // GPIO output is stable in the AXI clock domain. In legacy one-shot mode
    // it is a toggle command; in autonomous mode it is a run-enable level.
    (* ASYNC_REG = "TRUE" *) reg start_sync1;
    (* ASYNC_REG = "TRUE" *) reg start_sync2;
    reg start_seen;

    // Status is synchronised back to the AXI/GPIO clock domain. The frame
    // counter uses the vendor Gray-counter CDC macro, which registers the
    // Gray encoding in adc_clk, synchronises it, then decodes in axi_clk.
    (* ASYNC_REG = "TRUE" *) reg busy_sync1, busy_sync2;
    (* ASYNC_REG = "TRUE" *) reg done_sync1, done_sync2;
    (* ASYNC_REG = "TRUE" *) reg error_sync1, error_sync2;
    (* ASYNC_REG = "TRUE" *) reg channel_sync1, channel_sync2;
    wire [15:0] frame_counter_axi;

    xpm_cdc_gray #(
        .DEST_SYNC_FF          (2),
        .INIT_SYNC_FF          (0),
        .REG_OUTPUT            (0),
        .SIM_ASSERT_CHK        (0),
        .SIM_LOSSLESS_GRAY_CHK (0),
        .WIDTH                 (16)
    ) frame_counter_cdc (
        .src_clk      (adc_clk),
        .src_in_bin   (frame_counter_adc),
        .dest_clk     (axi_clk),
        .dest_out_bin (frame_counter_axi)
    );
    wire fft_watchdog_active = (state == ST_CONFIG) ||
                               (state == ST_FEED) ||
                               (state == ST_WAIT);
    wire fft_progress = ((state == ST_CONFIG) && fft_s_config_tvalid &&
                         fft_s_config_tready) ||
                        ((state == ST_FEED) && fft_s_data_tvalid &&
                         fft_s_data_tready) ||
                        ((state == ST_WAIT) && fft_m_data_tvalid);
    wire fft_watchdog_expired = fft_watchdog_active && !fft_progress &&
        (fft_watchdog_count >= FFT_PROGRESS_TIMEOUT_CYCLES - 1);

    // Exactly one of the two timeline sources is live; never both.
    wire [47:0] active_sample_id = (USE_EXTERNAL_SAMPLE_ID != 0)
                                 ? external_sample_id
                                 : sample_counter_q;
    wire capture_tick = (USE_EXTERNAL_SAMPLE_ID != 0) ? sample_tick : 1'b1;

    wire [9:0] current_index = feed_index[9:0];
    wire [11:0] current_sample, current_mean;
    wire signed [15:0] windowed_sample;
    // 三种开帧来源沿用原主控优先级；均在非采集状态发生，不抢占采样写入。
    wire capture_begin =
        ((state == ST_IDLE) && (((AUTO_RESTART != 0) && start_sync2) ||
           ((AUTO_RESTART == 0) && (start_sync2 != start_seen)))) ||
        ((AUTO_RESTART != 0) && start_sync2 &&
           (((state == ST_WAIT) && fft_m_data_tvalid && fft_m_data_tlast &&
             active_channel) || fft_watchdog_expired));

    spectrum_fft_capture capture_buffer (
        .clk(adc_clk), .resetn(adc_resetn), .begin_capture(capture_begin),
        .accept_sample((state == ST_CAPTURE) && capture_tick),
        .adc_ch0(adc_ch0_data), .adc_ch1(adc_ch1_data),
        .read_channel(active_channel), .read_index(current_index),
        .capture_index(capture_index), .sum_ch0(sum_ch0), .sum_ch1(sum_ch1),
        .mean_ch0(mean_ch0), .mean_ch1(mean_ch1),
        .read_sample(current_sample), .read_mean(current_mean)
    );
    spectrum_fft_prepare input_prepare (
        .sample_index(current_index), .sample_data(current_sample),
        .sample_mean(current_mean), .windowed_sample(windowed_sample)
    );
    spectrum_fft_result_writer result_writer (
        .clk(adc_clk), .resetn(adc_resetn),
        .accept_result((state == ST_WAIT) && fft_m_data_tvalid),
        .active_channel(active_channel), .result_index(fft_m_data_tuser),
        .result_data(fft_m_data_tdata), .bram_enb(bram_enb),
        .bram_web(bram_web), .bram_addrb(bram_addrb), .bram_dinb(bram_dinb)
    );

    assign sample_counter      = active_sample_id;
    assign fft_s_config_tdata  = 8'h01; // bit 0: forward transform
    assign fft_m_data_tready   = 1'b1;
    assign bram_clkb           = adc_clk;
    assign bram_rstb           = ~adc_resetn;
    assign status = {frame_counter_axi, 12'd0, channel_sync2,
                     error_sync2, done_sync2, busy_sync2};

    always @(posedge axi_clk) begin
        if (!axi_resetn) begin
            busy_sync1          <= 1'b0;
            busy_sync2          <= 1'b0;
            done_sync1          <= 1'b0;
            done_sync2          <= 1'b0;
            error_sync1         <= 1'b0;
            error_sync2         <= 1'b0;
            channel_sync1       <= 1'b0;
            channel_sync2       <= 1'b0;
        end else begin
            busy_sync1          <= busy_adc;
            busy_sync2          <= busy_sync1;
            done_sync1          <= done_toggle_adc;
            done_sync2          <= done_sync1;
            error_sync1         <= error_adc;
            error_sync2         <= error_sync1;
            channel_sync1       <= active_channel;
            channel_sync2       <= channel_sync1;
        end
    end

    always @(posedge adc_clk) begin
        if (!adc_resetn) begin
            state                       <= ST_IDLE;
            active_channel              <= 1'b0;
            feed_index                  <= 11'd0;
            busy_adc                    <= 1'b0;
            done_toggle_adc             <= 1'b0;
            error_adc                   <= 1'b0;
            frame_counter_adc           <= 16'd0;
            sample_counter_q            <= 48'd0;
            frame_start_sample_id       <= 48'd0;
            frame_end_sample_id         <= 48'd0;
            completed_start_sample_id   <= 48'd0;
            completed_end_sample_id     <= 48'd0;
            frame_done_pulse            <= 1'b0;
            frame_begin_pulse           <= 1'b0;
            frame_abort_pulse           <= 1'b0;
            completed_frame_error       <= 1'b0;
            captured_sample_count       <= 48'd0;
            fft_watchdog_count          <= 32'd0;
            start_sync1                 <= 1'b0;
            start_sync2                 <= 1'b0;
            start_seen                  <= 1'b0;
            fft_s_config_tvalid         <= 1'b0;
            fft_s_data_tdata            <= 32'd0;
            fft_s_data_tvalid           <= 1'b0;
            fft_s_data_tlast            <= 1'b0;
        end else begin
            // The local counter advances only in the shipping one-shot mode.
            // With USE_EXTERNAL_SAMPLE_ID=1 the timeline comes from outside.
            if (USE_EXTERNAL_SAMPLE_ID == 0)
                sample_counter_q <= sample_counter_q + 48'd1;
            frame_done_pulse <= 1'b0;
            frame_begin_pulse <= 1'b0;
            frame_abort_pulse <= 1'b0;
            start_sync1 <= start_toggle;
            start_sync2 <= start_sync1;

            if (fft_event_tlast_unexpected || fft_event_tlast_missing ||
                fft_event_status_halt || fft_event_data_in_halt ||
                fft_event_data_out_halt)
                error_adc <= 1'b1;

            // Store natural-order positive-frequency bins.  XK_INDEX is in
            // tuser[9:0]; upper padding bits are ignored.
            if ((state == ST_WAIT) && fft_m_data_tvalid) begin
                if (fft_m_data_tlast) begin
                    if (!active_channel) begin
                        active_channel      <= 1'b1;
                        feed_index          <= 11'd0;
                        fft_s_config_tvalid <= 1'b1;
                        state               <= ST_CONFIG;
                    end else begin
                        done_toggle_adc   <= ~done_toggle_adc;
                        frame_counter_adc <= frame_counter_adc + 1'b1;
                        completed_start_sample_id <= frame_start_sample_id;
                        completed_end_sample_id   <= frame_end_sample_id;
                        completed_frame_error     <= error_adc ||
                            fft_event_tlast_unexpected || fft_event_tlast_missing ||
                            fft_event_status_halt || fft_event_data_in_halt ||
                            fft_event_data_out_halt;
                        frame_done_pulse          <= 1'b1;
                        if ((AUTO_RESTART != 0) && start_sync2) begin
                            // This is autonomous but NOT gap-free: the one
                            // FFT core processes two channels serially.
                            // The next frame starts at the next ADC edge.
                            active_channel <= 1'b0;
                            error_adc      <= 1'b0;
                            frame_begin_pulse <= 1'b1;
                            state         <= ST_CAPTURE;
                        end else begin
                            busy_adc <= 1'b0;
                            state    <= ST_IDLE;
                        end
                    end
                end
            end

            case (state)
                ST_IDLE: begin
                    fft_s_config_tvalid <= 1'b0;
                    fft_s_data_tvalid   <= 1'b0;
                    fft_s_data_tlast    <= 1'b0;

                    if (((AUTO_RESTART != 0) && start_sync2) ||
                        ((AUTO_RESTART == 0) && start_sync2 != start_seen)) begin
                        start_seen        <= start_sync2;
                        busy_adc          <= 1'b1;
                        frame_begin_pulse <= 1'b1;
                        error_adc         <= 1'b0;
                        active_channel    <= 1'b0;
                        state             <= ST_CAPTURE;
                    end
                end

                ST_CAPTURE: begin
                    if (capture_tick) begin
                        if (capture_index == 10'd0)
                            frame_start_sample_id <= active_sample_id;
                        if (capture_index == 10'd1023)
                            frame_end_sample_id <= active_sample_id;
                        captured_sample_count <= captured_sample_count + 1'b1;
                        if (capture_index == 10'd1023) begin
                            feed_index          <= 11'd0;
                            fft_s_config_tvalid <= 1'b1;
                            state               <= ST_CONFIG;
                        end
                    end
                end

                ST_CONFIG: begin
                    fft_s_data_tvalid <= 1'b0;
                    fft_s_data_tlast  <= 1'b0;
                    if (fft_s_config_tvalid && fft_s_config_tready) begin
                        fft_s_config_tvalid <= 1'b0;
                        feed_index          <= 11'd0;
                        state               <= ST_FEED;
                    end
                end

                ST_FEED: begin
                    // An AXIS output register: replace its contents only when
                    // empty or after the previous sample was accepted.
                    if (!fft_s_data_tvalid || fft_s_data_tready) begin
                        if (feed_index < FFT_N) begin
                            fft_s_data_tdata  <= {16'd0, windowed_sample};
                            fft_s_data_tlast  <= (feed_index == FFT_N-1);
                            fft_s_data_tvalid <= 1'b1;
                            feed_index        <= feed_index + 1'b1;
                        end else begin
                            fft_s_data_tvalid <= 1'b0;
                            fft_s_data_tlast  <= 1'b0;
                            state             <= ST_WAIT;
                        end
                    end
                end

                ST_WAIT: begin
                    fft_s_data_tvalid <= 1'b0;
                    fft_s_data_tlast  <= 1'b0;
                end

                default: state <= ST_IDLE;
            endcase

            // A new command while the engine is active is consumed and
            // reported instead of being replayed when the current frame ends.
            if ((AUTO_RESTART == 0) && busy_adc &&
                (start_sync2 != start_seen)) begin
                start_seen <= start_sync2;
                error_adc  <= 1'b1;
            end

            // A protocol fault must terminate the command instead of leaving
            // BUSY asserted forever. Toggle DONE so software observes a
            // terminal error; failed frames do not advance frame_counter.
            if (!fft_watchdog_active || fft_progress) begin
                fft_watchdog_count <= 32'd0;
            end else if (fft_watchdog_expired) begin
                fft_watchdog_count  <= 32'd0;
                fft_s_config_tvalid <= 1'b0;
                fft_s_data_tvalid   <= 1'b0;
                fft_s_data_tlast    <= 1'b0;
                busy_adc            <= 1'b0;
                error_adc           <= 1'b1;
                done_toggle_adc     <= ~done_toggle_adc;
                frame_abort_pulse   <= 1'b1;
                if ((AUTO_RESTART != 0) && start_sync2) begin
                    active_channel   <= 1'b0;
                    busy_adc         <= 1'b1;
                    error_adc        <= 1'b0;
                    frame_begin_pulse <= 1'b1;
                    state            <= ST_CAPTURE;
                end else begin
                    state            <= ST_IDLE;
                end
            end else begin
                fft_watchdog_count <= fft_watchdog_count + 1'b1;
            end
        end
    end

endmodule
