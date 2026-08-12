// =============================================================
// mac_accelerator_tb.v
// Self-checking testbench for mac_accelerator
// Two DUT instances: default (VECTOR_LEN=8) and VECTOR_LEN=4
// to exercise different configurations.
// =============================================================
`timescale 1ns/1ps

module mac_accelerator_tb;

    localparam DATA_WIDTH = 8;
    localparam ACC_WIDTH  = 32;

    // -------- DUT #1: default VECTOR_LEN = 8 --------
    localparam VLEN8 = 8;
    reg                     clk;
    reg                     rst_n;
    reg                     start8;
    reg  [DATA_WIDTH-1:0]   a_in8, b_in8;
    wire [ACC_WIDTH-1:0]    result8;
    wire                    busy8, done8;

    mac_accelerator #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .VECTOR_LEN(VLEN8)) dut8 (
        .clk(clk), .rst_n(rst_n), .start(start8),
        .a_in(a_in8), .b_in(b_in8),
        .result(result8), .busy(busy8), .done(done8)
    );

    // -------- DUT #2: VECTOR_LEN = 4 (different config) --------
    localparam VLEN4 = 4;
    reg                     start4;
    reg  [DATA_WIDTH-1:0]   a_in4, b_in4;
    wire [ACC_WIDTH-1:0]    result4;
    wire                    busy4, done4;

    mac_accelerator #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .VECTOR_LEN(VLEN4)) dut4 (
        .clk(clk), .rst_n(rst_n), .start(start4),
        .a_in(a_in4), .b_in(b_in4),
        .result(result4), .busy(busy4), .done(done4)
    );

    // -------- Clock: 10ns period --------
    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    // -------------------------------------------------------
    // Reusable task: run one MAC sequence on DUT8, check result
    // a_arr/b_arr are pre-loaded into memory arrays by the caller
    // -------------------------------------------------------
    reg [DATA_WIDTH-1:0] a_mem [0:31];
    reg [DATA_WIDTH-1:0] b_mem [0:31];

    task run_vec8;
        input [8*32-1:0] test_name; // for display only, packed string
        input integer len;
        integer i;
        reg [ACC_WIDTH-1:0] expected;
        begin
            expected = 0;
            for (i = 0; i < len; i = i + 1)
                expected = expected + (a_mem[i] * b_mem[i]);

            @(negedge clk);
            start8 = 1;
            a_in8 = a_mem[0];
            b_in8 = b_mem[0];
            @(negedge clk);
            start8 = 0;
            // from here, busy8 should be high; drive remaining elements
            for (i = 1; i < len; i = i + 1) begin
                a_in8 = a_mem[i];
                b_in8 = b_mem[i];
                @(negedge clk);
            end

            // wait for done
            wait (done8 == 1);
            #1;
            if (result8 === expected) begin
                $display("PASS [%0s] result=%0d expected=%0d", test_name, result8, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL [%0s] result=%0d expected=%0d", test_name, result8, expected);
                fail_count = fail_count + 1;
            end
            @(negedge clk); // let DONE pulse retire, FSM back to IDLE
        end
    endtask

    integer j;

    initial begin
        $dumpfile("waveform.vcd");
        $dumpvars(0, mac_accelerator_tb);

        // ---------------- init ----------------
        rst_n  = 0;
        start8 = 0; a_in8 = 0; b_in8 = 0;
        start4 = 0; a_in4 = 0; b_in4 = 0;

        repeat (3) @(negedge clk);

        // ================= TEST 1: Reset behavior =================
        if (result8 === 0 && busy8 === 0 && done8 === 0)
            begin $display("PASS [Reset] outputs are 0 after reset"); pass_count = pass_count+1; end
        else
            begin $display("FAIL [Reset] result=%0d busy=%0b done=%0b", result8, busy8, done8); fail_count = fail_count+1; end

        rst_n = 1;
        @(negedge clk);

        // ================= TEST 2: Single MAC-sequence, small positive values =================
        for (j = 0; j < 8; j = j + 1) begin a_mem[j] = j+1; b_mem[j] = j+2; end
        run_vec8("Positive values", 8);

        // ================= TEST 3: All-zero inputs =================
        for (j = 0; j < 8; j = j + 1) begin a_mem[j] = 0; b_mem[j] = 0; end
        run_vec8("All-zero inputs", 8);

        // ================= TEST 4: Maximum input values (255*255*8) =================
        for (j = 0; j < 8; j = j + 1) begin a_mem[j] = 255; b_mem[j] = 255; end
        run_vec8("Max input values", 8);

        // ================= TEST 5: Multiple consecutive operations (back to back) =================
        for (j = 0; j < 8; j = j + 1) begin a_mem[j] = 2; b_mem[j] = 3; end
        run_vec8("Consecutive op #1", 8);
        for (j = 0; j < 8; j = j + 1) begin a_mem[j] = 5; b_mem[j] = 1; end
        run_vec8("Consecutive op #2", 8);
        for (j = 0; j < 8; j = j + 1) begin a_mem[j] = 10; b_mem[j] = 10; end
        run_vec8("Consecutive op #3", 8);

        // ================= TEST 6: start asserted while busy (must be ignored) =================
        for (j = 0; j < 8; j = j + 1) begin a_mem[j] = 1; b_mem[j] = 1; end
        begin : start_while_busy_test
            reg [ACC_WIDTH-1:0] expected;
            expected = 8; // sum of 1*1 eight times
            @(negedge clk);
            start8 = 1; a_in8 = a_mem[0]; b_in8 = b_mem[0];
            @(negedge clk);
            start8 = 1; // illegally re-assert start mid-sequence
            a_in8 = a_mem[1]; b_in8 = b_mem[1];
            @(negedge clk);
            start8 = 0;
            for (j = 2; j < 8; j = j + 1) begin
                a_in8 = a_mem[j]; b_in8 = b_mem[j];
                @(negedge clk);
            end
            wait (done8 == 1);
            #1;
            if (result8 === expected) begin
                $display("PASS [start-while-busy ignored] result=%0d expected=%0d", result8, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL [start-while-busy ignored] result=%0d expected=%0d", result8, expected);
                fail_count = fail_count + 1;
            end
            @(negedge clk);
        end

        // ================= TEST 7: Different vector length (VECTOR_LEN=4 instance) =================
        begin : vlen4_test
            reg [ACC_WIDTH-1:0] expected;
            reg [DATA_WIDTH-1:0] a4 [0:3];
            reg [DATA_WIDTH-1:0] b4 [0:3];
            integer k;
            a4[0]=3; a4[1]=4; a4[2]=5; a4[3]=6;
            b4[0]=1; b4[1]=2; b4[2]=3; b4[3]=4;
            expected = 3*1 + 4*2 + 5*3 + 6*4; // 3+8+15+24 = 50

            @(negedge clk);
            start4 = 1; a_in4 = a4[0]; b_in4 = b4[0];
            @(negedge clk);
            start4 = 0;
            for (k = 1; k < 4; k = k + 1) begin
                a_in4 = a4[k]; b_in4 = b4[k];
                @(negedge clk);
            end
            wait (done4 == 1);
            #1;
            if (result4 === expected) begin
                $display("PASS [VECTOR_LEN=4] result=%0d expected=%0d", result4, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL [VECTOR_LEN=4] result=%0d expected=%0d", result4, expected);
                fail_count = fail_count + 1;
            end
            @(negedge clk);
        end

        // ================= TEST 8: Reset asserted mid-computation =================
        begin : reset_mid_test
            for (j = 0; j < 8; j = j + 1) begin a_mem[j] = 9; b_mem[j] = 9; end
            @(negedge clk);
            start8 = 1; a_in8 = a_mem[0]; b_in8 = b_mem[0];
            @(negedge clk);
            start8 = 0; a_in8 = a_mem[1]; b_in8 = b_mem[1];
            @(negedge clk); // now mid-COMPUTE
            rst_n = 0; // assert reset mid-sequence
            @(negedge clk);
            rst_n = 1;
            if (busy8 === 0 && done8 === 0) begin
                $display("PASS [Reset mid-computation] FSM returned to IDLE, busy=0 done=0");
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL [Reset mid-computation] busy=%0b done=%0b", busy8, done8);
                fail_count = fail_count + 1;
            end
            @(negedge clk);
        end

        // ================= TEST 9: Post-reset-mid-op, verify DUT still works correctly =================
        for (j = 0; j < 8; j = j + 1) begin a_mem[j] = 4; b_mem[j] = 4; end
        run_vec8("Functional after mid-op reset", 8);

        // ================= TEST 10: Done is exactly one cycle =================
        begin : done_pulse_test
            integer done_cycles;
            done_cycles = 0;
            for (j = 0; j < 8; j = j + 1) begin a_mem[j] = 1; b_mem[j] = 2; end
            @(negedge clk);
            start8 = 1; a_in8 = a_mem[0]; b_in8 = b_mem[0];
            @(negedge clk);
            start8 = 0;
            for (j = 1; j < 8; j = j + 1) begin
                a_in8 = a_mem[j]; b_in8 = b_mem[j];
                @(negedge clk);
            end
            // now DUT should be transitioning to DONE; sample done over next 3 cycles
            repeat (3) begin
                @(negedge clk);
                if (done8) done_cycles = done_cycles + 1;
            end
            if (done_cycles == 1) begin
                $display("PASS [Done single-cycle pulse] done asserted for exactly 1 cycle");
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL [Done single-cycle pulse] done asserted for %0d cycles", done_cycles);
                fail_count = fail_count + 1;
            end
        end

        // ================= Summary =================
        $display("----------------------------------------------------");
        $display("TOTAL: %0d PASS, %0d FAIL", pass_count, fail_count);
        if (fail_count == 0)
            $display("=== ALL TESTS PASSED ===");
        else
            $display("=== TESTS FAILED ===");
        $display("----------------------------------------------------");

        $finish;
    end

endmodule
