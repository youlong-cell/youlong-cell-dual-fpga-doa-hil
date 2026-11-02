`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
//  tb_sample_timebase.sv
//
//  被测：fft_pl/rtl/sample_timebase.v —— 全系统唯一的 ADC 绝对采样时间轴所有者。
//
//  这个 TB 存在的唯一理由：sample id 的语义最容易差 1，而差 1 在后面的
//  跨谱相位里表现为系统性误差、且极难发现。所以这里把语义用可机器判定的
//  方式钉死，而不是靠注释。
//
//  冻结语义（docs/DECISIONS.md D027）：
//    sample_id 的当前值 = **本拍** ADC 数据的绝对 id；本拍用完以后计数器才 +1。
//      sample #0     -> sample_id = 0        ring addr = 0
//      sample #1     -> sample_id = 1        ring addr = 1
//      ...
//      sample #16383 -> sample_id = 16383    ring addr = 16383
//      sample #16384 -> sample_id = 16384    ring addr = 0   （自然回绕）
//
//  断言（S 系列）：
//    S1 复位后第一拍 sample_id == INITIAL，即"第 0 个样本 id = 0"
//    S2 tick 恒 1 时，sample_id 严格每拍 +1（无跳变、无重复）
//    S3 用 sample_id 的当前值取 addr，与"样本序号 mod 16K"完全一致
//        （即 sample 0/16384 都落在 addr 0，这也证明 ring 的地址来源正确）
//    S4 tick 拉低期间 sample_id 冻结；重新拉起后**不跳号**续接
//        （tick 定义事件，事件之间的时间不计入 id 空间）
//    S5 复位把 id 清零并丢弃旧世代
//    S6 INITIAL 非零时 48 位计数器自然回绕，且回绕前后 id 语义不变
//
//  编码约定：本文件 UTF-8（无 BOM）；$display 字符串一律 ASCII，
//  避免 Windows 控制台代码页把中文日志变成不可恢复乱码。
//
//  运行：sim/scripts/run_xsim.bat tb_sample_timebase
//////////////////////////////////////////////////////////////////////////////////

module tb_sample_timebase;

    reg clk = 1'b0;
    always #8 clk = ~clk;              // 16 ns，与 ADC 标称时钟同量级

    integer failures = 0;
    integer i;

    task automatic check(input bit good, input string label_text);
        begin
            if (!good) begin
                failures = failures + 1;
                $display("[FAIL] %s", label_text);
            end
        end
    endtask

    // ---------------------------------------------------------------- 实例 A：常规
    reg        resetn_a = 1'b0;
    reg        tick_a   = 1'b0;
    wire [47:0] id_a;
    wire [47:0] next_a, current_a;
    wire current_valid_a;

    sample_timebase #(.INITIAL_SAMPLE_ID(48'd0)) dut_a (
        .adc_clk     (clk),
        .adc_resetn  (resetn_a),
        .sample_tick (tick_a),
        .sample_id   (id_a),
        .next_sample_id(next_a),
        .current_sample_id(current_a),
        .current_valid(current_valid_a)
    );

    // ---------------------------------------------------------------- 实例 B：回绕
    reg        resetn_b = 1'b0;
    reg        tick_b   = 1'b0;
    wire [47:0] id_b;
    wire [47:0] next_b, current_b;
    wire current_valid_b;

    sample_timebase #(.INITIAL_SAMPLE_ID(48'hffff_ffff_fffe)) dut_b (
        .adc_clk     (clk),
        .adc_resetn  (resetn_b),
        .sample_tick (tick_b),
        .sample_id   (id_b),
        .next_sample_id(next_b),
        .current_sample_id(current_b),
        .current_valid(current_valid_b)
    );

    // 与 ring 完全一致的地址推导：addr = sample_id[13:0]
    wire [13:0] addr_a = id_a[13:0];

    initial begin
        // 复位保持两拍，让两个实例都从 INITIAL 起步
        repeat (2) @(negedge clk);
        resetn_a = 1'b1;
        resetn_b = 1'b1;

        // ---- S1：复位释放后的第一拍就是 sample #0，id 必须等于 INITIAL ----
        tick_a = 1'b0;
        @(negedge clk); #1;
        check(id_a == 48'd0, "S1 after reset the first presented sample id is 0");
        check(id_a == next_a && !current_valid_a,
              "S1 sample_id is next ID; no committed sample after reset");
        check(addr_a == 14'd0, "S1 the first presented sample maps to ring addr 0");

        // ---- S2/S3：tick 恒 1，逐拍 +1；addr 与序号 mod 16K 一致 ----
        for (i = 0; i < 40; i = i + 1) begin
            @(negedge clk);
            tick_a = 1'b1;
            #1;
            check(id_a == i, "S2 sample id advances exactly one per tick");
            check(id_a == next_a, "S2 consumers receive the pre-edge next ID");
            check(addr_a == (i % 16384), "S3 ring addr equals sample index mod 16K");
            @(posedge clk);
        end
        #1;   // 等非阻塞赋值落定后再读，否则读到的是本拍之前的旧值
        check(id_a == 48'd40, "S2 after 40 ticks the id is 40");
        check(current_valid_a && current_a == 48'd39,
              "S2 after tick current ID is the last committed sample");

        // 第 16384 个样本必须与第 0 个样本落在同一个物理地址。这里不跑到
        // 16384 拍（那是 262 us，且已由 tb_sample_ring_buffer 用穷举读回
        // 真正覆盖），只断言上面循环里已经验证的映射关系：
        //     addr == sample_index mod 16K
        // 该关系在 index=0 与 index=16384 上给出同一个值。此处不重复断言。

        // ---- S4：tick 拉低期间冻结，且不跳号续接 ----
        @(negedge clk);
        tick_a = 1'b0;
        repeat (7) begin
            @(posedge clk); #1;
            check(id_a == 48'd40, "S4 sample id frozen while sample_tick is low");
            check(current_a == 48'd39, "S4 committed ID also holds without a tick");
        end
        @(negedge clk);
        tick_a = 1'b1;
        @(posedge clk); #1;
        check(id_a == 48'd41,
              "S4 resumed id continues from 40 to 41 with no numbering gap");
        check(current_a == 48'd40 && current_valid_a,
              "S4 resumed tick commits the pre-edge ID 40");

        // ---- S6：48 位自然回绕，且回绕前后语义不变 ----
        tick_b = 1'b1;
        check(id_b == 48'hffff_ffff_fffe, "S6 wrap instance starts at INITIAL");
        @(posedge clk); #1;
        check(id_b == 48'hffff_ffff_ffff, "S6 id reaches the 48-bit maximum");
        check(current_b == 48'hffff_ffff_fffe && current_valid_b,
              "S6 committed ID precedes next ID before wrap");
        @(posedge clk); #1;
        check(id_b == 48'h0000_0000_0000, "S6 id wraps naturally to zero");
        check(current_b == 48'hffff_ffff_ffff,
              "S6 last committed ID survives next-ID wrap");
        @(posedge clk); #1;
        check(id_b == 48'h0000_0000_0001, "S6 id continues after the wrap");
        @(negedge clk);
        tick_b = 1'b0;

        // ---- S5：复位丢弃旧世代 ----
        @(negedge clk);
        resetn_a = 1'b0;
        repeat (2) @(posedge clk); #1;
        check(id_a == 48'd0, "S5 reset returns the id to INITIAL");
        check(!current_valid_a, "S5 reset clears committed-ID validity");
        @(negedge clk);
        resetn_a = 1'b1;
        tick_a   = 1'b0;
        @(posedge clk); #1;
        check(id_a == 48'd0, "S5 the first sample of the new generation is id 0 again");

        if (failures == 0)
            $display("RESULT: PASS checks=timebase_semantics_and_tick_gating");
        else
            $display("RESULT: FAIL failures=%0d", failures);
        $finish;
    end

    initial begin
        #200000;
        $display("RESULT: FAIL timeout");
        $finish;
    end

endmodule
