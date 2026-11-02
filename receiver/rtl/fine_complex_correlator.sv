`timescale 1ns/1ps
// Reusable TWO-PASS complex correlation core; all ports in adc_clk domain.
// MODE_FRAME(0): [1536,2559], N=1024; MODE_WINDOW(1): [0,4095], N=4096.
// No interpolation/calibration/phase/DOA, no candidate release, no BD hookup.
// Means U24/F12 EXACT; Hann U21/F20; centered S25/F12; window S29/F16;
// shared NCO S22/F20; terms S29/F16; I/Q sums S41/F16, unnormalized.
// Every narrowing is signed round-nearest-even, NOT arithmetic-shift floor.
module fine_complex_correlator #(
    parameter HANN_FRAME_FILE = "fine_hann_1024.mem",
    parameter HANN_WINDOW_FILE = "fine_hann_4096.mem",
    parameter NCO_FILE = "fine_nco_16384.mem",
    parameter integer READ_TIMEOUT_CYCLES = 4096
) (
    input wire clk, input wire resetn,
    input wire start_valid, output wire start_ready,
    input wire mode, input wire [31:0] candidate_seq,
    input wire [47:0] window_start_sample_id,
    input wire [47:0] phase_increment,
    input wire abort, output reg abort_ack,
    output wire busy,
    output wire fine_rd_req, input wire fine_rd_ready,
    output wire [11:0] fine_rd_addr,
    input wire fine_rd_valid, input wire [31:0] fine_rd_data,
    input wire [11:0] fine_rd_index,
    output wire result_valid, input wire result_ready,
    output reg numeric_valid, output reg [7:0] result_status,
    output reg [31:0] result_seq, output reg result_mode,
    output reg [47:0] result_start_sample_id,
    output reg [47:0] result_phase_increment,
    output reg [23:0] mean0, mean1,
    output reg signed [40:0] i0, q0, i1, q1,
    output wire fault_valid, output reg [7:0] fault_code,
    output wire [31:0] fault_seq,
    input wire fault_clear
);
    localparam [3:0] IDLE=0, MEAN_REQ=1, MEAN_WAIT=2, MEAN_SET=3,
        DATA_REQ=4, DATA_WAIT=5, CENTER=6, HANN_MUL=7, HANN_RNE=8,
        MIX_MUL=9, MIX_RNE=10, ACCUM=11, RESULT=12, FAULT=13, ABORT_WAIT=14;
    // Numeric statuses: 0=OK, 1=frequency outside (0,Fs/2).
    // Hardware faults: 0x10=index/protocol, 0x11=padding,
    // 0x12=read watchdog, 0x13=impossible arithmetic range, 0x14=NCO timing.
    reg [3:0] state;
    reg [11:0] n, last_n, base_index;
    reg [23:0] sum0, sum1;
    reg [11:0] sample0, sample1;
    reg [47:0] phase;
    reg [31:0] wait_cycles;
    reg outstanding;
    (* rom_style = "block" *) reg [20:0] hann_frame [0:1023];
    (* rom_style = "block" *) reg [20:0] hann_window [0:4095];
    reg [20:0] hann;
    initial begin
        $readmemh(HANN_FRAME_FILE, hann_frame);
        $readmemh(HANN_WINDOW_FILE, hann_window);
    end
    reg signed [24:0] centered0, centered1;
    reg signed [46:0] hann_product0, hann_product1;
    reg signed [28:0] window0, window1;
    wire nco_valid;
    wire signed [21:0] nco_cos, nco_neg_sin;
    reg signed [21:0] cosine, neg_sine;
    reg nco_seen;
    reg signed [50:0] mix_i0, mix_q0, mix_i1, mix_q1;
    reg signed [28:0] term_i0, term_q0, term_i1, term_q1;
    wire [11:0] request_index = base_index + n;
    assign start_ready = state == IDLE && !abort && !fine_rd_valid;
    assign busy = (state != IDLE && state != RESULT && state != FAULT) || outstanding;
    assign fine_rd_req = !abort && (state == MEAN_REQ || state == DATA_REQ);
    assign fine_rd_addr = request_index;
    assign result_valid = state == RESULT && !abort;
    assign fault_valid = state == FAULT;
    assign fault_seq = result_seq;
    wire nco_req = state == DATA_WAIT && fine_rd_valid && !abort &&
                   fine_rd_index == request_index && !(fine_rd_data & 32'hf000f000);
    fine_shared_nco #(.ROM_FILE(NCO_FILE)) nco (
        .clk(clk), .resetn(resetn), .req(nco_req), .phase(phase),
        .valid(nco_valid), .cosine(nco_cos), .neg_sine(nco_neg_sin)
    );
    function automatic signed [63:0] rne(input signed [63:0] x, input integer shift);
        reg [63:0] mag, quotient, remainder, half, mask;
        begin
            mag = x < 0 ? $unsigned(-x) : $unsigned(x);
            mask = (64'd1 << shift) - 64'd1;
            half = 64'd1 << (shift-1);
            quotient = mag >> shift; remainder = mag & mask;
            if (remainder > half || (remainder == half && quotient[0]))
                quotient = quotient + 64'd1;
            rne = x < 0 ? -$signed(quotient) : $signed(quotient);
        end
    endfunction
    wire signed [63:0] rounded_w0 = rne(hann_product0,16);
    wire signed [63:0] rounded_w1 = rne(hann_product1,16);
    wire signed [63:0] rounded_i0 = rne(mix_i0,20), rounded_q0 = rne(mix_q0,20);
    wire signed [63:0] rounded_i1 = rne(mix_i1,20), rounded_q1 = rne(mix_q1,20);
    (* use_dsp = "yes" *) wire signed [41:0] next_i0 = $signed({i0[40],i0}) +
                               $signed({{13{term_i0[28]}},term_i0});
    (* use_dsp = "yes" *) wire signed [41:0] next_q0 = $signed({q0[40],q0}) +
                               $signed({{13{term_q0[28]}},term_q0});
    (* use_dsp = "yes" *) wire signed [41:0] next_i1 = $signed({i1[40],i1}) +
                               $signed({{13{term_i1[28]}},term_i1});
    (* use_dsp = "yes" *) wire signed [41:0] next_q1 = $signed({q1[40],q1}) +
                               $signed({{13{term_q1[28]}},term_q1});
    wire acc_overflow = (next_i0[41] != next_i0[40]) ||
                        (next_q0[41] != next_q0[40]) ||
                        (next_i1[41] != next_i1[40]) ||
                        (next_q1[41] != next_q1[40]);
    // One synchronous Hann lookup per paired DATA response.
    always @(posedge clk) if (nco_req) begin
        if (result_mode) hann <= hann_window[n];
        else hann <= hann_frame[n[9:0]];
    end
    always @(posedge clk) begin
        if (!resetn) begin
            state <= IDLE; outstanding <= 0; abort_ack <= 0; wait_cycles <= 0;
            n <= 0; last_n <= 0; base_index <= 0; sum0 <= 0; sum1 <= 0;
            mean0 <= 0; mean1 <= 0; phase <= 0; nco_seen <= 0;
            i0 <= 0; q0 <= 0; i1 <= 0; q1 <= 0;
            numeric_valid <= 0; result_status <= 0; fault_code <= 0;
            result_seq <= 0; result_mode <= 0;
            result_start_sample_id <= 0; result_phase_increment <= 0;
        end else begin
            abort_ack <= 0;
            if (nco_valid) begin
                cosine <= nco_cos; neg_sine <= nco_neg_sin; nco_seen <= 1;
            end
            if (fine_rd_valid) outstanding <= 0;
            // Abort does not recycle a port with a response still outstanding.
            if (abort && state != IDLE && state != FAULT && state != ABORT_WAIT) begin
                numeric_valid <= 0;
                if (outstanding && !fine_rd_valid) begin state <= ABORT_WAIT; wait_cycles <= 0; end
                else begin state <= IDLE; abort_ack <= 1; end
            end else case (state)
                IDLE: if (start_valid && start_ready) begin
                    result_seq <= candidate_seq; result_mode <= mode;
                    result_start_sample_id <= window_start_sample_id + (mode ? 48'd0 : 48'd1536);
                    result_phase_increment <= phase_increment;
                    base_index <= mode ? 12'd0 : 12'd1536;
                    last_n <= mode ? 12'd4095 : 12'd1023;
                    n <= 0; sum0 <= 0; sum1 <= 0; mean0 <= 0; mean1 <= 0;
                    i0 <= 0; q0 <= 0; i1 <= 0; q1 <= 0; phase <= 0;
                    wait_cycles <= 0; nco_seen <= 0; fault_code <= 0;
                    if (phase_increment == 0 || phase_increment[47]) begin
                        numeric_valid <= 0; result_status <= 1; state <= RESULT;
                    end else begin numeric_valid <= 1; result_status <= 0; state <= MEAN_REQ; end
                end
                MEAN_REQ, DATA_REQ: begin
                    if (fine_rd_ready) begin
                        outstanding <= 1; wait_cycles <= 0;
                        state <= state == MEAN_REQ ? MEAN_WAIT : DATA_WAIT;
                    end else if (wait_cycles == READ_TIMEOUT_CYCLES-1) begin
                        state <= FAULT; fault_code <= 8'h12; numeric_valid <= 0;
                    end else wait_cycles <= wait_cycles + 32'd1;
                end
                MEAN_WAIT, DATA_WAIT: begin
                    if (fine_rd_valid) begin
                        wait_cycles <= 0;
                        if (fine_rd_index != request_index) begin
                            state <= FAULT; fault_code <= 8'h10; numeric_valid <= 0;
                        end else if ((fine_rd_data & 32'hf000f000) != 0) begin
                            state <= FAULT; fault_code <= 8'h11; numeric_valid <= 0;
                        end else if (state == MEAN_WAIT) begin
                            sum0 <= sum0 + {12'b0,fine_rd_data[11:0]};
                            sum1 <= sum1 + {12'b0,fine_rd_data[27:16]};
                            if (n == last_n) state <= MEAN_SET;
                            else begin n <= n + 12'd1; state <= MEAN_REQ; end
                        end else begin
                            sample0 <= fine_rd_data[11:0]; sample1 <= fine_rd_data[27:16];
                            nco_seen <= 0; state <= CENTER;
                        end
                    end else if (wait_cycles == READ_TIMEOUT_CYCLES-1) begin
                        state <= FAULT; fault_code <= 8'h12; numeric_valid <= 0;
                    end else wait_cycles <= wait_cycles + 32'd1;
                end
                MEAN_SET: begin
                    mean0 <= result_mode ? sum0 : (sum0 << 2);
                    mean1 <= result_mode ? sum1 : (sum1 << 2);
                    n <= 0; state <= DATA_REQ;
                end
                CENTER: begin
                    centered0 <= $signed({1'b0,sample0,12'b0}) - $signed({1'b0,mean0});
                    centered1 <= $signed({1'b0,sample1,12'b0}) - $signed({1'b0,mean1});
                    state <= HANN_MUL;
                end
                HANN_MUL: begin
                    hann_product0 <= centered0 * $signed({1'b0,hann});
                    hann_product1 <= centered1 * $signed({1'b0,hann}); state <= HANN_RNE;
                end
                HANN_RNE: begin
                    if (rounded_w0 != $signed(rounded_w0[28:0]) ||
                        rounded_w1 != $signed(rounded_w1[28:0])) begin
                        state <= FAULT; fault_code <= 8'h13; numeric_valid <= 0;
                    end else begin
                        window0 <= rounded_w0[28:0]; window1 <= rounded_w1[28:0]; state <= MIX_MUL;
                    end
                end
                MIX_MUL: begin
                    if (!nco_seen) begin state <= FAULT; fault_code <= 8'h14; numeric_valid <= 0; end
                    else begin
                        mix_i0 <= window0 * cosine; mix_q0 <= window0 * neg_sine;
                        mix_i1 <= window1 * cosine; mix_q1 <= window1 * neg_sine; state <= MIX_RNE;
                    end
                end
                MIX_RNE: begin
                    if (rounded_i0 != $signed(rounded_i0[28:0]) || rounded_q0 != $signed(rounded_q0[28:0]) ||
                        rounded_i1 != $signed(rounded_i1[28:0]) || rounded_q1 != $signed(rounded_q1[28:0])) begin
                        state <= FAULT; fault_code <= 8'h13; numeric_valid <= 0;
                    end else begin
                        term_i0 <= rounded_i0[28:0]; term_q0 <= rounded_q0[28:0];
                        term_i1 <= rounded_i1[28:0]; term_q1 <= rounded_q1[28:0]; state <= ACCUM;
                    end
                end
                ACCUM: if (acc_overflow) begin state <= FAULT; fault_code <= 8'h13; numeric_valid <= 0; end
                else begin
                    i0 <= next_i0[40:0]; q0 <= next_q0[40:0];
                    i1 <= next_i1[40:0]; q1 <= next_q1[40:0];
                    phase <= phase + result_phase_increment;
                    if (n == last_n) state <= RESULT;
                    else begin n <= n + 12'd1; state <= DATA_REQ; end
                end
                RESULT: if (result_ready) state <= IDLE;
                FAULT: if (fault_clear && (!outstanding || fine_rd_valid)) begin state <= IDLE; fault_code <= 0; end
                ABORT_WAIT: if (fine_rd_valid) begin state <= IDLE; abort_ack <= 1; end
                else if (wait_cycles == READ_TIMEOUT_CYCLES-1) begin
                    state <= FAULT; fault_code <= 8'h12;
                end else wait_cycles <= wait_cycles + 32'd1;
                default: begin state <= FAULT; fault_code <= 8'h10; numeric_valid <= 0; end
            endcase
            // Unsolicited/duplicate responses cannot silently advance a sample.
            if (fine_rd_valid && !outstanding && state != IDLE && state != FAULT &&
                state != ABORT_WAIT && !abort) begin
                state <= FAULT; fault_code <= 8'h10; numeric_valid <= 0;
            end
        end
    end
endmodule
