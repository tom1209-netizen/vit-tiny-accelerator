`timescale 1ns / 1ps

module tb_gemm_core_top;
    // Parameters
    parameter DATA_WIDTH      = 8;
    parameter ACC_WIDTH       = 32;
    parameter ARRAY_SIZE      = 8;
    parameter AXIS_DATA_WIDTH = 64;
    parameter CLK_PERIOD      = 10;  // 100 MHz

    localparam TOTAL_RESULTS  = ARRAY_SIZE * ARRAY_SIZE;
    localparam VALUES_PER_BEAT = AXIS_DATA_WIDTH / ACC_WIDTH;  // 2
    localparam TOTAL_BEATS    = TOTAL_RESULTS / VALUES_PER_BEAT;  // 32

    
    // Signals
    // Clock / reset
    reg                              aclk;
    reg                              aresetn;

    // Control
    reg                              start_tile;
    wire                             tile_done;

    // AXIS A
    reg        [AXIS_DATA_WIDTH-1:0] s_axis_a_tdata;
    reg                              s_axis_a_tvalid;
    reg                              s_axis_a_tlast;
    wire                             s_axis_a_tready;

    // AXIS B
    reg        [AXIS_DATA_WIDTH-1:0] s_axis_b_tdata;
    reg                              s_axis_b_tvalid;
    reg                              s_axis_b_tlast;
    wire                             s_axis_b_tready;

    // AXIS output
    wire       [AXIS_DATA_WIDTH-1:0] m_axis_out_tdata;
    wire                             m_axis_out_tvalid;
    wire                             m_axis_out_tlast;
    reg                              m_axis_out_tready;

    // Matrices
    reg signed [DATA_WIDTH-1:0] A     [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    reg signed [DATA_WIDTH-1:0] B     [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    reg signed [ACC_WIDTH-1:0]  C_exp [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    reg signed [ACC_WIDTH-1:0]  C_act [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    integer ii, jj, kk;
    integer errors;

    
    // DUT Instantiation
    gemm_core_top #(
        .DATA_WIDTH     (DATA_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),
        .ARRAY_SIZE     (ARRAY_SIZE),
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH)
    ) dut (
        .aclk      (aclk),
        .aresetn   (aresetn),
        .start_tile(start_tile),
        .tile_done (tile_done),

        .s_axis_a_tdata (s_axis_a_tdata),
        .s_axis_a_tvalid(s_axis_a_tvalid),
        .s_axis_a_tlast (s_axis_a_tlast),
        .s_axis_a_tready(s_axis_a_tready),

        .s_axis_b_tdata (s_axis_b_tdata),
        .s_axis_b_tvalid(s_axis_b_tvalid),
        .s_axis_b_tlast (s_axis_b_tlast),
        .s_axis_b_tready(s_axis_b_tready),

        .m_axis_out_tdata (m_axis_out_tdata),
        .m_axis_out_tvalid(m_axis_out_tvalid),
        .m_axis_out_tlast (m_axis_out_tlast),
        .m_axis_out_tready(m_axis_out_tready)
    );

    
    // Clock Generator
    initial begin
        aclk = 1'b0;
        forever #(CLK_PERIOD / 2) aclk = ~aclk;
    end

    
    // Functions: Build wavefront-scheduled beats
    // Build A beat for given cycle: lane i = A[i][k_a] with k_a = cyc - i
    function [AXIS_DATA_WIDTH-1:0] build_A_beat;
        input integer cyc;
        integer i;
        integer k_a;
        reg [AXIS_DATA_WIDTH-1:0] beat;
        begin
            beat = {AXIS_DATA_WIDTH{1'b0}};
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                k_a = cyc - i;
                if (k_a >= 0 && k_a < ARRAY_SIZE) 
                    beat[i*DATA_WIDTH+:DATA_WIDTH] = A[i][k_a];
                else 
                    beat[i*DATA_WIDTH+:DATA_WIDTH] = {DATA_WIDTH{1'b0}};
            end
            build_A_beat = beat;
        end
    endfunction

    // Build B beat for given cycle: lane j = B[k_b][j] with k_b = cyc - j
    function [AXIS_DATA_WIDTH-1:0] build_B_beat;
        input integer cyc;
        integer j;
        integer k_b;
        reg [AXIS_DATA_WIDTH-1:0] beat;
        begin
            beat = {AXIS_DATA_WIDTH{1'b0}};
            for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                k_b = cyc - j;
                if (k_b >= 0 && k_b < ARRAY_SIZE) 
                    beat[j*DATA_WIDTH+:DATA_WIDTH] = B[k_b][j];
                else 
                    beat[j*DATA_WIDTH+:DATA_WIDTH] = {DATA_WIDTH{1'b0}};
            end
            build_B_beat = beat;
        end
    endfunction

    
    // Tasks
    task initialize_sim;
        begin
            errors            = 0;
            aresetn           = 1'b0;
            start_tile        = 1'b0;
            s_axis_a_tdata    = {AXIS_DATA_WIDTH{1'b0}};
            s_axis_b_tdata    = {AXIS_DATA_WIDTH{1'b0}};
            s_axis_a_tvalid   = 1'b0;
            s_axis_b_tvalid   = 1'b0;
            s_axis_a_tlast    = 1'b0;
            s_axis_b_tlast    = 1'b0;
            m_axis_out_tready = 1'b0;
        end
    endtask

    task reset_dut;
        begin
            repeat (5) @(posedge aclk);
            aresetn = 1'b1;
            @(posedge aclk);
        end
    endtask

    // Initialize matrices and compute expected C
    task init_matrices;
        begin
            // Initialize A, B, C_exp, C_act
            for (ii = 0; ii < ARRAY_SIZE; ii = ii + 1) begin
                for (jj = 0; jj < ARRAY_SIZE; jj = jj + 1) begin
                    A[ii][jj]     = ii + jj;
                    B[ii][jj]     = (ii == jj) ? 2 : 0;  // 2 * I
                    C_exp[ii][jj] = 0;
                    C_act[ii][jj] = 0;
                end
            end

            // Expected C = A * B
            for (ii = 0; ii < ARRAY_SIZE; ii = ii + 1) begin
                for (jj = 0; jj < ARRAY_SIZE; jj = jj + 1) begin
                    C_exp[ii][jj] = 0;
                    for (kk = 0; kk < ARRAY_SIZE; kk = kk + 1) begin
                        C_exp[ii][jj] = C_exp[ii][jj] + A[ii][kk] * B[kk][jj];
                    end
                end
            end
        end
    endtask

    // Stream A and B with wavefront timing
    task stream_inputs;
        integer cyc;
        localparam NUM_CYCLES = ARRAY_SIZE * 3 + 10;
        begin
            s_axis_a_tvalid <= 1'b0;
            s_axis_b_tvalid <= 1'b0;
            s_axis_a_tlast  <= 1'b0;
            s_axis_b_tlast  <= 1'b0;

            @(posedge aclk);

            for (cyc = 0; cyc < NUM_CYCLES; cyc = cyc + 1) begin
                @(posedge aclk);
                s_axis_a_tdata  <= build_A_beat(cyc);
                s_axis_b_tdata  <= build_B_beat(cyc);
                s_axis_a_tvalid <= 1'b1;
                s_axis_b_tvalid <= 1'b1;
                s_axis_a_tlast  <= (cyc == NUM_CYCLES - 1);
                s_axis_b_tlast  <= (cyc == NUM_CYCLES - 1);
            end

            // Deassert after final beat
            @(posedge aclk);
            s_axis_a_tvalid <= 1'b0;
            s_axis_b_tvalid <= 1'b0;
            s_axis_a_tlast  <= 1'b0;
            s_axis_b_tlast  <= 1'b0;
        end
    endtask

    // Drain all output beats into C_act
    task drain_results;
        integer beats;
        integer r, c;
        begin
            beats = 0;
            r = 0;
            c = 0;
            m_axis_out_tready <= 1'b1;

            while (beats < TOTAL_BEATS) begin
                @(posedge aclk);
                if (m_axis_out_tvalid && m_axis_out_tready) begin
                    // Unpack 2 results per beat
                    C_act[r][c] <= m_axis_out_tdata[31:0];
                    if (c + 1 < ARRAY_SIZE) 
                        C_act[r][c+1] <= m_axis_out_tdata[63:32];

                    // Advance indices
                    c = c + VALUES_PER_BEAT;
                    if (c >= ARRAY_SIZE) begin
                        c = 0;
                        r = r + 1;
                    end

                    beats = beats + 1;
                end
            end

            m_axis_out_tready <= 1'b0;
        end
    endtask

    // Compare C_act vs C_exp
    task check_results;
        integer mismatches;
        begin
            mismatches = 0;
            
            print_expected_c;
            print_actual_c;
            
            for (ii = 0; ii < ARRAY_SIZE; ii = ii + 1) begin
                for (jj = 0; jj < ARRAY_SIZE; jj = jj + 1) begin
                    if (C_act[ii][jj] !== C_exp[ii][jj]) begin
                        $display("ERROR at C[%0d][%0d]: Expected=%0d, Got=%0d", 
                                 ii, jj, C_exp[ii][jj], C_act[ii][jj]);
                        mismatches = mismatches + 1;
                    end
                end
            end

            if (mismatches == 0) begin
                $display("PASS");
            end else begin
                $display("FAIL (%0d errors)", mismatches);
                errors = errors + mismatches;
            end
        end
    endtask

    
    // Display Tasks 
    task print_matrix_a;
        integer i, j;
        begin
            $display("\nMatrix A:");
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                $write("  [ ");
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    $write("%4d ", A[i][j]);
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
                    $write("%4d ", B[i][j]);
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
                    $write("%5d ", C_exp[i][j]);
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
                    $write("%5d ", C_act[i][j]);
                end
                $display("]");
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

    
    // Main Test
    initial begin : main_test
        $display("========================================");
        $display("GEMM Core Top-Level Testbench");
        $display("========================================");

        initialize_sim;
        reset_dut;

        // Initialize matrices and expected C
        init_matrices;
        print_matrix_a;
        print_matrix_b;

        $write("\nTest: GEMM %0dx%0d (A * 2I)", ARRAY_SIZE, ARRAY_SIZE);

        // Start tile
        @(posedge aclk);
        start_tile <= 1'b1;
        @(posedge aclk);
        start_tile <= 1'b0;

        // Stream A and B
        stream_inputs;

        // Wait for computation to propagate
        repeat (20) @(posedge aclk);

        // Drain outputs
        drain_results;

        // Give tile_done a few cycles
        repeat (10) @(posedge aclk);

        if (!tile_done) begin
            $display("WARNING: tile_done not asserted");
        end

        check_results;
        print_summary;

        repeat (10) @(posedge aclk);
        $finish;
    end

    
    // Safety Timeout
    initial begin
        #(CLK_PERIOD * 100000);
        $display("TIMEOUT");
        $finish;
    end

endmodule
