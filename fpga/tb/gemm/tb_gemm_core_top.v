`timescale 1ns / 1ps

module tb_gemm_core_top;
    // Parameters
    parameter DATA_WIDTH = 8;
    parameter ACC_WIDTH = 32;
    parameter ARRAY_SIZE = 8;
    parameter AXIS_DATA_WIDTH = 64;
    parameter CLK_PERIOD = 10;  // 100 MHz

    // NOTE: Uses 2-stage pipelined MAC processing elements
    // Additional latency added per PE for pipeline stages

    localparam TOTAL_RESULTS = ARRAY_SIZE * ARRAY_SIZE;
    localparam VALUES_PER_BEAT = AXIS_DATA_WIDTH / ACC_WIDTH;  // 2
    localparam TOTAL_BEATS = TOTAL_RESULTS / VALUES_PER_BEAT;  // 32
    localparam MAX_CYCLES = 15000;  // Increased for pipelined timing

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
    reg signed [     DATA_WIDTH-1:0] A                 [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    reg signed [     DATA_WIDTH-1:0] B                 [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    reg signed [      ACC_WIDTH-1:0] C_exp             [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    reg signed [      ACC_WIDTH-1:0] C_act             [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    integer ii, jj, kk;
    integer errors;
    integer cycles;
    integer start_cycle, end_cycle, latency_cycles;

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

    // Watchdog timer
    initial cycles = 0;
    always @(posedge aclk) cycles = cycles + 1;
    always @(posedge aclk) begin
        if (cycles == MAX_CYCLES) begin
            $display("TIMEOUT at cycle %0d", cycles);
            $finish;
        end
    end

    // Debug Trace
    always @(posedge aclk) begin
        // Log when there is active input streaming or output draining
        if (s_axis_a_tvalid || s_axis_b_tvalid || m_axis_out_tready || m_axis_out_tvalid) begin
            $display("[Trace %0d] OUT: V=%b R=%b L=%b D=%h | IN A: V=%b R=%b | IN B: V=%b R=%b",
                     cycles, m_axis_out_tvalid, m_axis_out_tready, m_axis_out_tlast,
                     m_axis_out_tdata, s_axis_a_tvalid, s_axis_a_tready, s_axis_b_tvalid,
                     s_axis_b_tready);
        end
    end

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
            cycles            = 0;
        end
    endtask

    task reset_dut;
        begin
            @(posedge aclk);
            aresetn = 1'b1;
            @(posedge aclk);
        end
    endtask

    // Recompute expected matrix given current A and B contents
    task compute_expected;
        begin
            for (ii = 0; ii < ARRAY_SIZE; ii = ii + 1) begin
                for (jj = 0; jj < ARRAY_SIZE; jj = jj + 1) begin
                    C_exp[ii][jj] = 0;
                    C_act[ii][jj] = 0;
                    for (kk = 0; kk < ARRAY_SIZE; kk = kk + 1) begin
                        C_exp[ii][jj] = C_exp[ii][jj] + A[ii][kk] * B[kk][jj];
                    end
                end
            end
        end
    endtask

    // Program A/B contents for a given test case
    task prepare_case;
        input integer case_id;
        begin
            for (ii = 0; ii < ARRAY_SIZE; ii = ii + 1) begin
                for (jj = 0; jj < ARRAY_SIZE; jj = jj + 1) begin
                    case (case_id)
                        0: begin
                            // Baseline: additive ramp multiplied by 2*I
                            A[ii][jj] = ii + jj;
                            B[ii][jj] = (ii == jj) ? 2 : 0;
                        end
                        1: begin
                            // Identity A with distinct diagonal scaling, B is a ramp matrix
                            A[ii][jj] = (ii == jj) ? (jj + 1) : 0;
                            B[ii][jj] = jj + (ii * 2);
                        end
                        2: begin
                            // Alternating sign rows multiplied by a checkerboard B
                            A[ii][jj] = ((ii % 2) == 0) ? (jj + 1) : -(jj + 1);
                            B[ii][jj] = ((jj % 2) == 0) ? (ii - jj) : (jj - ii);
                        end
                        3: begin
                            // Pseudo-random but deterministic content stressing negatives
                            A[ii][jj] = ((ii * 5 + jj * 3) % 13) - 6;
                            B[ii][jj] = ((ii * 7 - jj * 4) % 11) - 5;
                        end
                        4: begin
                            // Lower-triangular A times upper-triangular B
                            A[ii][jj] = (ii >= jj) ? (ii - jj + 1) : 0;
                            B[ii][jj] = (ii <= jj) ? (jj - ii + 2) : 0;
                        end
                        default: begin
                            // Fallback: lower-triangular emphasis
                            A[ii][jj] = (ii <= jj) ? (ii + jj) : -(ii + jj);
                            B[ii][jj] = (ii >= jj) ? (ii - jj + 1) : 0;
                        end
                    endcase
                end
            end

            compute_expected;
        end
    endtask

    // Stream complete matrices using TLAST with wavefront scheduling
    task stream_matrices_with_tlast;
        integer cycle;
        integer handshakes_a, handshakes_b;
        integer i, j;
        reg [AXIS_DATA_WIDTH-1:0] a_beat, b_beat;
        begin
            s_axis_a_tvalid <= 1'b0;
            s_axis_b_tvalid <= 1'b0;
            s_axis_a_tlast  <= 1'b0;
            s_axis_b_tlast  <= 1'b0;
            handshakes_a = 0;
            handshakes_b = 0;

            // Wait for initial ready signals
            wait (s_axis_a_tready && s_axis_b_tready);

            // Stream using wavefront scheduling - total cycles needed: 2*ARRAY_SIZE-1
            for (cycle = 0; cycle < (2 * ARRAY_SIZE - 1); cycle = cycle + 1) begin
                // Build A beat for this cycle
                a_beat = {AXIS_DATA_WIDTH{1'b0}};
                for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                    j = cycle - i;
                    if (j >= 0 && j < ARRAY_SIZE) begin
                        a_beat[i*DATA_WIDTH+:DATA_WIDTH] = A[i][j];
                    end
                end

                // Build B beat for this cycle  
                b_beat = {AXIS_DATA_WIDTH{1'b0}};
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    i = cycle - j;
                    if (i >= 0 && i < ARRAY_SIZE) begin
                        b_beat[j*DATA_WIDTH+:DATA_WIDTH] = B[i][j];
                    end
                end

                // Set TLAST on final cycle
                s_axis_a_tlast  <= (cycle == (2 * ARRAY_SIZE - 2));
                s_axis_b_tlast  <= (cycle == (2 * ARRAY_SIZE - 2));
                s_axis_a_tdata  <= a_beat;
                s_axis_b_tdata  <= b_beat;
                s_axis_a_tvalid <= 1'b1;
                s_axis_b_tvalid <= 1'b1;

                @(posedge aclk);

                // Count handshakes
                if (s_axis_a_tvalid && s_axis_a_tready) begin
                    handshakes_a = handshakes_a + 1;
                    $display("  A handshake #%0d (cycle %0d) TLAST=%0b", handshakes_a, cycle,
                             s_axis_a_tlast);
                end
                if (s_axis_b_tvalid && s_axis_b_tready) begin
                    handshakes_b = handshakes_b + 1;
                    $display("  B handshake #%0d (cycle %0d) TLAST=%0b", handshakes_b, cycle,
                             s_axis_b_tlast);
                end

                // If not ready, wait until ready
                while (!(s_axis_a_tready && s_axis_b_tready)) @(posedge aclk);
            end

            // Deassert after final beat (the extra @(posedge aclk) is removed from here)
            s_axis_a_tvalid <= 1'b0;
            s_axis_b_tvalid <= 1'b0;
            s_axis_a_tlast  <= 1'b0;
            s_axis_b_tlast  <= 1'b0;

            $display("  Total A handshakes: %0d", handshakes_a);
            $display("  Total B handshakes: %0d", handshakes_b);
        end
    endtask

    // Drain all output beats into C_act with proper handshake
    task drain_results;
        integer beats;
        integer r, c;
        integer output_handshakes;
        begin
            beats = 0;
            r = 0;
            c = 0;
            output_handshakes = 0;
            m_axis_out_tready <= 1'b1;

            $display("  Starting output collection...");

            while (beats < TOTAL_BEATS) begin
                @(posedge aclk);
                if (m_axis_out_tvalid && m_axis_out_tready) begin
                    output_handshakes = output_handshakes + 1;

                    // Unpack 2 results per beat
                    C_act[r][c] = m_axis_out_tdata[31:0];
                    if (c + 1 < ARRAY_SIZE) C_act[r][c+1] = m_axis_out_tdata[63:32];

                    $display("  Output handshake #%0d: row=%0d, col=%0d, data=%0d,%0d, TLAST=%0b",
                             output_handshakes, r, c, m_axis_out_tdata[31:0],
                             m_axis_out_tdata[63:32], m_axis_out_tlast);

                    // Advance indices
                    c = c + VALUES_PER_BEAT;
                    if (c >= ARRAY_SIZE) begin
                        c = 0;
                        r = r + 1;
                    end

                    beats = beats + 1;

                    // Check TLAST on final beat
                    if (beats == TOTAL_BEATS && !m_axis_out_tlast) begin
                        $display("ERROR: TLAST not asserted on final output beat");
                        errors = errors + 1;
                    end
                end
            end

            m_axis_out_tready <= 1'b0;
            $display("  Collected %0d output beats", output_handshakes);
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
                        $display("ERROR at C[%0d][%0d]: Expected=%0d, Got=%0d", ii, jj,
                                 C_exp[ii][jj], C_act[ii][jj]);
                        mismatches = mismatches + 1;
                    end
                end
            end

            if (mismatches == 0) begin
                $display("PASS: All results matched");
            end else begin
                $display("FAIL: %0d errors", mismatches);
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

    // Execute a full tile for the selected scenario
    task run_test_case;
        input integer case_id;
        input [8*64-1:0] test_name;
        integer wait_cycles;
        begin
            $display("\n=== Test %0d: %0s ===", case_id, test_name);
            prepare_case(case_id);
            print_matrix_a;
            print_matrix_b;

            // Launch tile
            start_cycle = cycles;
            @(posedge aclk);
            start_tile <= 1'b1;
            @(posedge aclk);
            start_tile <= 1'b0;

            stream_matrices_with_tlast;
            drain_results;

            // Allow collector to finish
            wait_cycles = 0;
            while (!tile_done && wait_cycles < 1000) begin
                wait_cycles = wait_cycles + 1;
                @(posedge aclk);
            end

            if (!tile_done) begin
                $display("WARNING: tile_done not asserted after waiting %0d cycles", wait_cycles);
            end
            end_cycle = cycles;
            latency_cycles = end_cycle - start_cycle;
            $display("  Tile latency: %0d cycles (start=%0d -> end=%0d)", latency_cycles,
                     start_cycle, end_cycle);

            check_results;
        end
    endtask

    // Main Test Sequence
    initial begin : main_test
        $display("========================================");
        $display("GEMM Core Top-Level Testbench");
        $display("========================================");

        initialize_sim;
        reset_dut;

        run_test_case(0, "Baseline: (ii+jj) * 2I");
        // run_test_case(1, "Identity A times ramp B");
        // run_test_case(2, "Alternating signs * checkerboard");
        // run_test_case(3, "Pseudo-random signed matrices");
        // run_test_case(4, "Lower-triangular vs upper-triangular");
        // run_test_case(5, "Fallback stress pattern");
        print_summary;

        $finish;
    end

endmodule
