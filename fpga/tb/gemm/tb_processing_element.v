`timescale 1ns / 1ps

module tb_processing_element;
    parameter DATA_WIDTH = 8;
    parameter ACC_WIDTH = 32;
    parameter CLK_PERIOD = 10;

    reg                          clk;
    reg                          rst_n;

    reg signed  [DATA_WIDTH-1:0] a_in;
    reg                          a_valid_in;
    reg signed  [DATA_WIDTH-1:0] b_in;
    reg                          b_valid_in;

    wire signed [DATA_WIDTH-1:0] a_out;
    wire                         a_valid_out;
    wire signed [DATA_WIDTH-1:0] b_out;
    wire                         b_valid_out;

    reg                          clear_acc;
    wire signed [ ACC_WIDTH-1:0] acc_out;

    integer                      errors;
    integer                      test_num;
    integer                      i;

    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // Instantiation
    processing_element #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH (ACC_WIDTH)
    ) dut (
        .clk  (clk),
        .rst_n(rst_n),

        .a_in(a_in),
        .a_valid_in(a_valid_in),
        .a_out(a_out),
        .a_valid_out(a_valid_out),

        .b_in(b_in),
        .b_valid_in(b_valid_in),
        .b_out(b_out),
        .b_valid_out(b_valid_out),

        .clear_acc(clear_acc),
        .acc_out  (acc_out)
    );

    initial begin
        $display("========================================");
        $display("Processing Element Testbench");
        $display("Time: %0t", $time);
        $display("========================================");

        errors = 0;
        test_num = 0;

        rst_n = 0;
        a_in = 0;
        b_in = 0;
        a_valid_in = 0;
        b_valid_in = 0;
        clear_acc = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Test 1
        test_num = 1;
        $display("\nTest %0d: Single MAC (2 * 3 = 6)", test_num);
        a_in = 8'sd2;
        b_in = 8'sd3;
        a_valid_in = 1;
        b_valid_in = 1;
        @(posedge clk);
        a_valid_in = 0;
        b_valid_in = 0;
        @(posedge clk);
        @(posedge clk);
        check_acc(32'd6);

        // Test 2
        test_num = 2;
        $display("\nTest %0d: Accumulation (6 + 4*5 = 26)", test_num);
        a_in = 8'sd4;
        b_in = 8'sd5;
        a_valid_in = 1;
        b_valid_in = 1;
        @(posedge clk);
        a_valid_in = 0;
        b_valid_in = 0;
        @(posedge clk);
        @(posedge clk);
        check_acc(32'd26);

        // Test 3
        test_num = 3;
        $display("\nTest %0d: Negative numbers (26 + (-3)*2 = 20)", test_num);
        a_in = -8'sd3;
        b_in = 8'sd2;
        a_valid_in = 1;
        b_valid_in = 1;
        @(posedge clk);
        a_valid_in = 0;
        b_valid_in = 0;
        @(posedge clk);
        @(posedge clk);
        check_acc(32'd20);

        // Test 4
        test_num = 4;
        $display("\nTest %0d: Clear accumulator", test_num);
        clear_acc = 1;
        @(posedge clk);
        clear_acc = 0;
        @(posedge clk);
        @(posedge clk);
        check_acc(32'd0);

        // Test 5
        test_num = 5;
        $display("\nTest %0d: Valid=0, no accumulation", test_num);
        a_in = 8'sd10;
        b_in = 8'sd10;
        a_valid_in = 0;
        b_valid_in = 0;
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);
        check_acc(32'd0);

        // Test 6
        test_num = 6;
        $display("\nTest %0d: Series of operations", test_num);
        clear_acc = 1;
        @(posedge clk);
        clear_acc = 0;

        @(posedge clk);

        a_valid_in = 1;
        b_valid_in = 1;
        for (i = 1; i <= 5; i = i + 1) begin
            a_in = i;
            b_in = i;
            @(posedge clk);
        end
        a_valid_in = 0;
        b_valid_in = 0;
        @(posedge clk);
        @(posedge clk);
        check_acc(32'd55);  // 1+4+9+16+25 = 55

        // Test 7: Max positive values
        test_num = 7;
        $display("\nTest %0d: Max positive values (127 * 127 = 16129)", test_num);
        clear_acc = 1;
        @(posedge clk);
        clear_acc = 0;
        @(posedge clk);
        a_in = 8'sd127;
        b_in = 8'sd127;
        a_valid_in = 1;
        b_valid_in = 1;
        @(posedge clk);
        a_valid_in = 0;
        b_valid_in = 0;
        @(posedge clk);
        @(posedge clk);
        check_acc(32'd16129);

        // Test 8: Min negative values
        test_num = 8;
        $display("\nTest %0d: Min negative values (-128 * -128 = 16384)", test_num);
        clear_acc = 1;
        @(posedge clk);
        clear_acc = 0;
        @(posedge clk);
        a_in = -8'sd128;
        b_in = -8'sd128;
        a_valid_in = 1;
        b_valid_in = 1;
        @(posedge clk);
        a_valid_in = 0;
        b_valid_in = 0;
        @(posedge clk);
        @(posedge clk);
        check_acc(32'd16384);

        // Test 9: Mixed max/min values
        test_num = 9;
        $display("\nTest %0d: Mixed max/min values (127 * -128 = -16256)", test_num);
        clear_acc = 1;
        @(posedge clk);
        clear_acc = 0;
        @(posedge clk);
        a_in = 8'sd127;
        b_in = -8'sd128;
        a_valid_in = 1;
        b_valid_in = 1;
        @(posedge clk);
        a_valid_in = 0;
        b_valid_in = 0;
        @(posedge clk);
        @(posedge clk);
        check_acc(-32'sd16256);

        // Test 10: Staggered valid inputs
        test_num = 10;
        $display("\nTest %0d: Staggered valid inputs, no accumulation", test_num);
        clear_acc = 1;
        @(posedge clk);
        clear_acc = 0;
        @(posedge clk);
        // Staggered a and b valid signals
        a_in = 8'sd10;
        b_in = 8'sd10;
        a_valid_in = 1;
        b_valid_in = 0;
        @(posedge clk);
        a_valid_in = 0;
        b_valid_in = 1;
        @(posedge clk);
        a_valid_in = 0;
        b_valid_in = 0;
        @(posedge clk);
        check_acc(32'd0);

        // Test 11: Reset during accumulation
        test_num = 11;
        $display("\nTest %0d: Reset during accumulation", test_num);
        clear_acc = 1;
        @(posedge clk);
        clear_acc = 0;
        @(posedge clk);
        a_in = 8'd5;
        b_in = 8'd5;
        a_valid_in = 1;
        b_valid_in = 1;
        @(posedge clk);  // acc = 25
        a_in = 8'd2;
        b_in = 8'd2;
        @(posedge clk);  // acc = 25 + 4 = 29
        // Assert reset
        rst_n = 0;
        @(posedge clk);
        rst_n = 1;
        a_valid_in = 0;
        b_valid_in = 0;
        @(posedge clk);
        @(posedge clk);
        check_acc(32'd0);  // Should be 0 after reset

        $display("\n========================================");
        $display("TEST SUMMARY - PE");
        $display("========================================");
        if (errors == 0) begin
            $display("*** ALL TESTS PASSED! ***");
        end else begin
            $display("*** TESTS FAILED: %0d errors ***", errors);
        end
        $display("========================================");

        $finish;
    end

    task check_acc;
        input signed [ACC_WIDTH-1:0] expected;
        begin
            if (acc_out !== expected) begin
                $display("[%0t] ERROR: Expected: %0d, Got: %0d", $time, expected, acc_out);
                errors = errors + 1;
            end else begin
                $display("[%0t] PASS: Value: %0d", $time, acc_out);
            end
        end
    endtask

    initial begin
        #100000;
        $display("\n[%0t] ERROR: Testbench timeout!", $time);
        $finish;
    end

endmodule
