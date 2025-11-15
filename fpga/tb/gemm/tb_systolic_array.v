`timescale 1ns / 1ps

module tb_systolic_array;

    parameter DATA_WIDTH = 8;
    parameter ACC_WIDTH = 32;
    parameter ARRAY_SIZE = 8;
    parameter CLK_PERIOD = 10;

    reg clk;
    reg rst_n;
    reg clear_acc;

    reg signed [DATA_WIDTH-1:0] a_in_0, a_in_1, a_in_2, a_in_3, a_in_4, a_in_5, a_in_6, a_in_7;
    reg a_valid_in_0, a_valid_in_1, a_valid_in_2, a_valid_in_3;
    reg a_valid_in_4, a_valid_in_5, a_valid_in_6, a_valid_in_7;
    reg signed [DATA_WIDTH-1:0] b_in_0, b_in_1, b_in_2, b_in_3, b_in_4, b_in_5, b_in_6, b_in_7;
    reg b_valid_in_0, b_valid_in_1, b_valid_in_2, b_valid_in_3;
    reg b_valid_in_4, b_valid_in_5, b_valid_in_6, b_valid_in_7;

    wire signed [ACC_WIDTH-1:0] acc_out_0_0, acc_out_0_1, acc_out_0_2, acc_out_0_3;
    wire signed [ACC_WIDTH-1:0] acc_out_0_4, acc_out_0_5, acc_out_0_6, acc_out_0_7;
    wire signed [ACC_WIDTH-1:0] acc_out_1_0, acc_out_1_1, acc_out_1_2, acc_out_1_3;
    wire signed [ACC_WIDTH-1:0] acc_out_1_4, acc_out_1_5, acc_out_1_6, acc_out_1_7;
    wire signed [ACC_WIDTH-1:0] acc_out_2_0, acc_out_2_1, acc_out_2_2, acc_out_2_3;
    wire signed [ACC_WIDTH-1:0] acc_out_2_4, acc_out_2_5, acc_out_2_6, acc_out_2_7;
    wire signed [ACC_WIDTH-1:0] acc_out_3_0, acc_out_3_1, acc_out_3_2, acc_out_3_3;
    wire signed [ACC_WIDTH-1:0] acc_out_3_4, acc_out_3_5, acc_out_3_6, acc_out_3_7;
    wire signed [ACC_WIDTH-1:0] acc_out_4_0, acc_out_4_1, acc_out_4_2, acc_out_4_3;
    wire signed [ACC_WIDTH-1:0] acc_out_4_4, acc_out_4_5, acc_out_4_6, acc_out_4_7;
    wire signed [ACC_WIDTH-1:0] acc_out_5_0, acc_out_5_1, acc_out_5_2, acc_out_5_3;
    wire signed [ACC_WIDTH-1:0] acc_out_5_4, acc_out_5_5, acc_out_5_6, acc_out_5_7;
    wire signed [ACC_WIDTH-1:0] acc_out_6_0, acc_out_6_1, acc_out_6_2, acc_out_6_3;
    wire signed [ACC_WIDTH-1:0] acc_out_6_4, acc_out_6_5, acc_out_6_6, acc_out_6_7;
    wire signed [ACC_WIDTH-1:0] acc_out_7_0, acc_out_7_1, acc_out_7_2, acc_out_7_3;
    wire signed [ACC_WIDTH-1:0] acc_out_7_4, acc_out_7_5, acc_out_7_6, acc_out_7_7;
    wire array_active;

    reg signed [DATA_WIDTH-1:0] matrix_A[0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    reg signed [DATA_WIDTH-1:0] matrix_B[0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    reg signed [ACC_WIDTH-1:0] expected_C[0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    reg signed [ACC_WIDTH-1:0] actual_C[0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    integer errors;
    integer i, j, k;
    integer cycle;

    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    systolic_array #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH (ACC_WIDTH),
        .ARRAY_SIZE(ARRAY_SIZE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .a_in_0(a_in_0),
        .a_in_1(a_in_1),
        .a_in_2(a_in_2),
        .a_in_3(a_in_3),
        .a_in_4(a_in_4),
        .a_in_5(a_in_5),
        .a_in_6(a_in_6),
        .a_in_7(a_in_7),
        .a_valid_in_0(a_valid_in_0),
        .a_valid_in_1(a_valid_in_1),
        .a_valid_in_2(a_valid_in_2),
        .a_valid_in_3(a_valid_in_3),
        .a_valid_in_4(a_valid_in_4),
        .a_valid_in_5(a_valid_in_5),
        .a_valid_in_6(a_valid_in_6),
        .a_valid_in_7(a_valid_in_7),
        .b_in_0(b_in_0),
        .b_in_1(b_in_1),
        .b_in_2(b_in_2),
        .b_in_3(b_in_3),
        .b_in_4(b_in_4),
        .b_in_5(b_in_5),
        .b_in_6(b_in_6),
        .b_in_7(b_in_7),
        .b_valid_in_0(b_valid_in_0),
        .b_valid_in_1(b_valid_in_1),
        .b_valid_in_2(b_valid_in_2),
        .b_valid_in_3(b_valid_in_3),
        .b_valid_in_4(b_valid_in_4),
        .b_valid_in_5(b_valid_in_5),
        .b_valid_in_6(b_valid_in_6),
        .b_valid_in_7(b_valid_in_7),
        .clear_acc(clear_acc),
        .acc_out_0_0(acc_out_0_0),
        .acc_out_0_1(acc_out_0_1),
        .acc_out_0_2(acc_out_0_2),
        .acc_out_0_3(acc_out_0_3),
        .acc_out_0_4(acc_out_0_4),
        .acc_out_0_5(acc_out_0_5),
        .acc_out_0_6(acc_out_0_6),
        .acc_out_0_7(acc_out_0_7),
        .acc_out_1_0(acc_out_1_0),
        .acc_out_1_1(acc_out_1_1),
        .acc_out_1_2(acc_out_1_2),
        .acc_out_1_3(acc_out_1_3),
        .acc_out_1_4(acc_out_1_4),
        .acc_out_1_5(acc_out_1_5),
        .acc_out_1_6(acc_out_1_6),
        .acc_out_1_7(acc_out_1_7),
        .acc_out_2_0(acc_out_2_0),
        .acc_out_2_1(acc_out_2_1),
        .acc_out_2_2(acc_out_2_2),
        .acc_out_2_3(acc_out_2_3),
        .acc_out_2_4(acc_out_2_4),
        .acc_out_2_5(acc_out_2_5),
        .acc_out_2_6(acc_out_2_6),
        .acc_out_2_7(acc_out_2_7),
        .acc_out_3_0(acc_out_3_0),
        .acc_out_3_1(acc_out_3_1),
        .acc_out_3_2(acc_out_3_2),
        .acc_out_3_3(acc_out_3_3),
        .acc_out_3_4(acc_out_3_4),
        .acc_out_3_5(acc_out_3_5),
        .acc_out_3_6(acc_out_3_6),
        .acc_out_3_7(acc_out_3_7),
        .acc_out_4_0(acc_out_4_0),
        .acc_out_4_1(acc_out_4_1),
        .acc_out_4_2(acc_out_4_2),
        .acc_out_4_3(acc_out_4_3),
        .acc_out_4_4(acc_out_4_4),
        .acc_out_4_5(acc_out_4_5),
        .acc_out_4_6(acc_out_4_6),
        .acc_out_4_7(acc_out_4_7),
        .acc_out_5_0(acc_out_5_0),
        .acc_out_5_1(acc_out_5_1),
        .acc_out_5_2(acc_out_5_2),
        .acc_out_5_3(acc_out_5_3),
        .acc_out_5_4(acc_out_5_4),
        .acc_out_5_5(acc_out_5_5),
        .acc_out_5_6(acc_out_5_6),
        .acc_out_5_7(acc_out_5_7),
        .acc_out_6_0(acc_out_6_0),
        .acc_out_6_1(acc_out_6_1),
        .acc_out_6_2(acc_out_6_2),
        .acc_out_6_3(acc_out_6_3),
        .acc_out_6_4(acc_out_6_4),
        .acc_out_6_5(acc_out_6_5),
        .acc_out_6_6(acc_out_6_6),
        .acc_out_6_7(acc_out_6_7),
        .acc_out_7_0(acc_out_7_0),
        .acc_out_7_1(acc_out_7_1),
        .acc_out_7_2(acc_out_7_2),
        .acc_out_7_3(acc_out_7_3),
        .acc_out_7_4(acc_out_7_4),
        .acc_out_7_5(acc_out_7_5),
        .acc_out_7_6(acc_out_7_6),
        .acc_out_7_7(acc_out_7_7),
        .array_active(array_active)
    );

    task collect_outputs;
        begin
            actual_C[0][0] = acc_out_0_0;
            actual_C[0][1] = acc_out_0_1;
            actual_C[0][2] = acc_out_0_2;
            actual_C[0][3] = acc_out_0_3;
            actual_C[0][4] = acc_out_0_4;
            actual_C[0][5] = acc_out_0_5;
            actual_C[0][6] = acc_out_0_6;
            actual_C[0][7] = acc_out_0_7;
            actual_C[1][0] = acc_out_1_0;
            actual_C[1][1] = acc_out_1_1;
            actual_C[1][2] = acc_out_1_2;
            actual_C[1][3] = acc_out_1_3;
            actual_C[1][4] = acc_out_1_4;
            actual_C[1][5] = acc_out_1_5;
            actual_C[1][6] = acc_out_1_6;
            actual_C[1][7] = acc_out_1_7;
            actual_C[2][0] = acc_out_2_0;
            actual_C[2][1] = acc_out_2_1;
            actual_C[2][2] = acc_out_2_2;
            actual_C[2][3] = acc_out_2_3;
            actual_C[2][4] = acc_out_2_4;
            actual_C[2][5] = acc_out_2_5;
            actual_C[2][6] = acc_out_2_6;
            actual_C[2][7] = acc_out_2_7;
            actual_C[3][0] = acc_out_3_0;
            actual_C[3][1] = acc_out_3_1;
            actual_C[3][2] = acc_out_3_2;
            actual_C[3][3] = acc_out_3_3;
            actual_C[3][4] = acc_out_3_4;
            actual_C[3][5] = acc_out_3_5;
            actual_C[3][6] = acc_out_3_6;
            actual_C[3][7] = acc_out_3_7;
            actual_C[4][0] = acc_out_4_0;
            actual_C[4][1] = acc_out_4_1;
            actual_C[4][2] = acc_out_4_2;
            actual_C[4][3] = acc_out_4_3;
            actual_C[4][4] = acc_out_4_4;
            actual_C[4][5] = acc_out_4_5;
            actual_C[4][6] = acc_out_4_6;
            actual_C[4][7] = acc_out_4_7;
            actual_C[5][0] = acc_out_5_0;
            actual_C[5][1] = acc_out_5_1;
            actual_C[5][2] = acc_out_5_2;
            actual_C[5][3] = acc_out_5_3;
            actual_C[5][4] = acc_out_5_4;
            actual_C[5][5] = acc_out_5_5;
            actual_C[5][6] = acc_out_5_6;
            actual_C[5][7] = acc_out_5_7;
            actual_C[6][0] = acc_out_6_0;
            actual_C[6][1] = acc_out_6_1;
            actual_C[6][2] = acc_out_6_2;
            actual_C[6][3] = acc_out_6_3;
            actual_C[6][4] = acc_out_6_4;
            actual_C[6][5] = acc_out_6_5;
            actual_C[6][6] = acc_out_6_6;
            actual_C[6][7] = acc_out_6_7;
            actual_C[7][0] = acc_out_7_0;
            actual_C[7][1] = acc_out_7_1;
            actual_C[7][2] = acc_out_7_2;
            actual_C[7][3] = acc_out_7_3;
            actual_C[7][4] = acc_out_7_4;
            actual_C[7][5] = acc_out_7_5;
            actual_C[7][6] = acc_out_7_6;
            actual_C[7][7] = acc_out_7_7;
        end
    endtask

    task set_inputs;
        input integer cyc;
        integer k, i, j;
        integer k_a;
        integer k_b;
        begin
            k_a = cyc - 0;
            if (k_a >= 0 && k_a < ARRAY_SIZE) begin
                a_in_0 = matrix_A[0][k_a];
                a_valid_in_0 = 1;
            end else begin
                a_in_0 = 0;
                a_valid_in_0 = 0;
            end
            k_a = cyc - 1;
            if (k_a >= 0 && k_a < ARRAY_SIZE) begin
                a_in_1 = matrix_A[1][k_a];
                a_valid_in_1 = 1;
            end else begin
                a_in_1 = 0;
                a_valid_in_1 = 0;
            end
            k_a = cyc - 2;
            if (k_a >= 0 && k_a < ARRAY_SIZE) begin
                a_in_2 = matrix_A[2][k_a];
                a_valid_in_2 = 1;
            end else begin
                a_in_2 = 0;
                a_valid_in_2 = 0;
            end
            k_a = cyc - 3;
            if (k_a >= 0 && k_a < ARRAY_SIZE) begin
                a_in_3 = matrix_A[3][k_a];
                a_valid_in_3 = 1;
            end else begin
                a_in_3 = 0;
                a_valid_in_3 = 0;
            end
            k_a = cyc - 4;
            if (k_a >= 0 && k_a < ARRAY_SIZE) begin
                a_in_4 = matrix_A[4][k_a];
                a_valid_in_4 = 1;
            end else begin
                a_in_4 = 0;
                a_valid_in_4 = 0;
            end
            k_a = cyc - 5;
            if (k_a >= 0 && k_a < ARRAY_SIZE) begin
                a_in_5 = matrix_A[5][k_a];
                a_valid_in_5 = 1;
            end else begin
                a_in_5 = 0;
                a_valid_in_5 = 0;
            end
            k_a = cyc - 6;
            if (k_a >= 0 && k_a < ARRAY_SIZE) begin
                a_in_6 = matrix_A[6][k_a];
                a_valid_in_6 = 1;
            end else begin
                a_in_6 = 0;
                a_valid_in_6 = 0;
            end
            k_a = cyc - 7;
            if (k_a >= 0 && k_a < ARRAY_SIZE) begin
                a_in_7 = matrix_A[7][k_a];
                a_valid_in_7 = 1;
            end else begin
                a_in_7 = 0;
                a_valid_in_7 = 0;
            end

            k_b = cyc - 0;
            if (k_b >= 0 && k_b < ARRAY_SIZE) begin
                b_in_0 = matrix_B[k_b][0];
                b_valid_in_0 = 1;
            end else begin
                b_in_0 = 0;
                b_valid_in_0 = 0;
            end
            k_b = cyc - 1;
            if (k_b >= 0 && k_b < ARRAY_SIZE) begin
                b_in_1 = matrix_B[k_b][1];
                b_valid_in_1 = 1;
            end else begin
                b_in_1 = 0;
                b_valid_in_1 = 0;
            end
            k_b = cyc - 2;
            if (k_b >= 0 && k_b < ARRAY_SIZE) begin
                b_in_2 = matrix_B[k_b][2];
                b_valid_in_2 = 1;
            end else begin
                b_in_2 = 0;
                b_valid_in_2 = 0;
            end
            k_b = cyc - 3;
            if (k_b >= 0 && k_b < ARRAY_SIZE) begin
                b_in_3 = matrix_B[k_b][3];
                b_valid_in_3 = 1;
            end else begin
                b_in_3 = 0;
                b_valid_in_3 = 0;
            end
            k_b = cyc - 4;
            if (k_b >= 0 && k_b < ARRAY_SIZE) begin
                b_in_4 = matrix_B[k_b][4];
                b_valid_in_4 = 1;
            end else begin
                b_in_4 = 0;
                b_valid_in_4 = 0;
            end
            k_b = cyc - 5;
            if (k_b >= 0 && k_b < ARRAY_SIZE) begin
                b_in_5 = matrix_B[k_b][5];
                b_valid_in_5 = 1;
            end else begin
                b_in_5 = 0;
                b_valid_in_5 = 0;
            end
            k_b = cyc - 6;
            if (k_b >= 0 && k_b < ARRAY_SIZE) begin
                b_in_6 = matrix_B[k_b][6];
                b_valid_in_6 = 1;
            end else begin
                b_in_6 = 0;
                b_valid_in_6 = 0;
            end
            k_b = cyc - 7;
            if (k_b >= 0 && k_b < ARRAY_SIZE) begin
                b_in_7 = matrix_B[k_b][7];
                b_valid_in_7 = 1;
            end else begin
                b_in_7 = 0;
                b_valid_in_7 = 0;
            end
        end
    endtask

    task initialize_sim;
        begin
            errors = 0;
            rst_n = 0;
            clear_acc = 0;
            set_inputs(999);
        end
    endtask

    task reset_dut;
        begin
            repeat (5) @(posedge clk);
            rst_n = 1;
            @(posedge clk);
        end
    endtask

    task compute_expected_c;
        begin
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    expected_C[i][j] = 0;
                    for (k = 0; k < ARRAY_SIZE; k = k + 1) begin
                        expected_C[i][j] = expected_C[i][j] + (matrix_A[i][k] * matrix_B[k][j]);
                    end
                end
            end
        end
    endtask

    task run_computation;
        localparam NUM_CYCLES = ARRAY_SIZE * 3 + 10;
        begin
            clear_acc = 1;
            @(posedge clk);
            clear_acc = 0;

            for (cycle = 0; cycle < NUM_CYCLES; cycle = cycle + 1) begin
                set_inputs(cycle);
                @(posedge clk);
            end

            set_inputs(999);
            repeat (5) @(posedge clk);
        end
    endtask

    task check_results;
        integer test_errors;
        begin
            test_errors = 0;
            print_expected_c;
            collect_outputs();
            print_actual_c;

            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    if (actual_C[i][j] !== expected_C[i][j]) begin
                        $display("ERROR at C[%0d][%0d]: Expected=%0d, Got=%0d", i, j,
                                 expected_C[i][j], actual_C[i][j]);
                        test_errors = test_errors + 1;
                    end
                end
            end

            if (test_errors == 0) begin
                $display("PASS");
            end else begin
                $display("FAIL (%0d errors)", test_errors);
                errors = errors + test_errors;
            end
        end
    endtask

    task print_summary;
        begin
            $display("\n========================================");
            if (errors == 0) begin
                $display("*** ALL TESTS PASSED! ***");
            end else begin
                $display("*** FAILED: %0d errors ***", errors);
            end
            $display("========================================");
        end
    endtask

    task print_matrix_a;
        integer i, j;
        begin
            $display("\nMatrix A:");
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                $write("  [ ");
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    $write("%4d ", matrix_A[i][j]);
                end
                $display("]");
            end
        end
    endtask

    task print_matrix_b;
        integer i, j;
        begin
            $display("\nMatrix B:");
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                $write("  [ ");
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    $write("%4d ", matrix_B[i][j]);
                end
                $display("]");
            end
        end
    endtask

    task print_expected_c;
        integer i, j;
        begin
            $display("\nExpected C:");
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                $write("  [ ");
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    $write("%5d ", expected_C[i][j]);
                end
                $display("]");
            end
        end
    endtask

    task print_actual_c;
        integer i, j;
        begin
            $display("\nActual C:");
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                $write("  [ ");
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    $write("%5d ", actual_C[i][j]);
                end
                $display("]");
            end
        end
    endtask

    task test_identity_matrix;
        begin
            $write("\nTest: Identity Matrix");
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    matrix_A[i][j] = (i == j) ? 8'sd1 : 8'sd0;
                    matrix_B[i][j] = (i == j) ? 8'sd1 : 8'sd0;
                end
            end
            print_matrix_a;
            print_matrix_b;
            compute_expected_c;
            run_computation;
            check_results;
        end
    endtask

    task test_zero_matrix;
        begin
            $write("\nTest: Zero Matrix (A * 0)");
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    matrix_A[i][j] = (i == j) ? 8'sd1 : 8'sd0;
                    matrix_B[i][j] = 8'sd0;
                end
            end
            print_matrix_a;
            print_matrix_b;
            compute_expected_c;
            run_computation;
            check_results;
        end
    endtask

    task test_ones_matrix;
        begin
            $write("\nTest: Ones Matrix");
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    matrix_A[i][j] = 8'sd1;
                    matrix_B[i][j] = 8'sd1;
                end
            end
            print_matrix_a;
            print_matrix_b;
            compute_expected_c;
            run_computation;
            check_results;
        end
    endtask

    task test_negative_matrix;
        begin
            $write("\nTest: Negative Numbers (C = A * -I)");
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    matrix_A[i][j] = i + j + 1;
                    matrix_B[i][j] = (i == j) ? -8'sd1 : 8'sd0;
                end
            end
            print_matrix_a;
            print_matrix_b;
            compute_expected_c;
            run_computation;
            check_results;
        end
    endtask

    task test_sequential_muls;
        begin
            $display("\nTest: Sequential Multiplications (Check clear_acc)");

            $write("Sequential Run 1: Identity Matrix");
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    matrix_A[i][j] = (i == j) ? 8'sd1 : 8'sd0;
                    matrix_B[i][j] = (i == j) ? 8'sd1 : 8'sd0;
                end
            end
            print_matrix_a;
            print_matrix_b;
            compute_expected_c;
            run_computation;
            check_results;

            $write("\nSequential Run 2: Ones Matrix");
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    matrix_A[i][j] = 8'sd1;
                    matrix_B[i][j] = 8'sd1;
                end
            end
            print_matrix_a;
            print_matrix_b;
            compute_expected_c;
            run_computation;
            check_results;
        end
    endtask

    task test_random_matrix;
        input integer test_num;
        begin
            $display("\nTest: Random Matrix Run %0d", test_num);

            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    matrix_A[i][j] = $random;
                    matrix_B[i][j] = $random;
                end
            end

            compute_expected_c;
            run_computation;
            check_results;
        end
    endtask


    initial begin : main_block
        integer test_iter;
        $display("========================================");
        $display("8x8 Systolic Array Testbench");
        $display("========================================");

        initialize_sim;
        reset_dut;

        test_identity_matrix;
        test_zero_matrix;
        test_ones_matrix;
        test_negative_matrix;
        test_sequential_muls;
        for (test_iter = 0; test_iter < 100; test_iter = test_iter + 1) begin
            test_random_matrix(test_iter + 1);
        end

        print_summary;
        $finish;
    end

    initial begin
        #1000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
