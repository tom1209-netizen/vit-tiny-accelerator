`timescale 1ns / 1ps

module tb_output_collector;
    // Parameters
    parameter ARRAY_SIZE = 8;
    parameter ACC_WIDTH = 32;
    parameter AXIS_DATA_WIDTH = 64;
    parameter VALUES_PER_BEAT = 2;  // 64 / 32
    parameter CLK_PERIOD = 10;

    localparam BEATS_PER_ROW = (ARRAY_SIZE + VALUES_PER_BEAT - 1) / VALUES_PER_BEAT;  // 4
    localparam TOTAL_BEATS = ARRAY_SIZE * BEATS_PER_ROW;  // 32

    // Clock and control
    reg                              clk;
    reg                              rst_n;
    reg                              start_output;

    // AXI-Stream out
    wire       [AXIS_DATA_WIDTH-1:0] m_axis_tdata;
    wire                             m_axis_tvalid;
    wire                             m_axis_tlast;
    reg                              m_axis_tready;

    // Status
    wire                             done;

    // Inputs to DUT (8x8 accumulators)
    reg signed [      ACC_WIDTH-1:0] acc_in        [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    // DUT
    output_collector #(
        .ACC_WIDTH(ACC_WIDTH),
        .ARRAY_SIZE(ARRAY_SIZE),
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
        .VALUES_PER_BEAT(VALUES_PER_BEAT)
    ) dut (
        .clk  (clk),
        .rst_n(rst_n),

        // Flattened inputs
        .acc_in_0_0(acc_in[0][0]),
        .acc_in_0_1(acc_in[0][1]),
        .acc_in_0_2(acc_in[0][2]),
        .acc_in_0_3(acc_in[0][3]),
        .acc_in_0_4(acc_in[0][4]),
        .acc_in_0_5(acc_in[0][5]),
        .acc_in_0_6(acc_in[0][6]),
        .acc_in_0_7(acc_in[0][7]),
        .acc_in_1_0(acc_in[1][0]),
        .acc_in_1_1(acc_in[1][1]),
        .acc_in_1_2(acc_in[1][2]),
        .acc_in_1_3(acc_in[1][3]),
        .acc_in_1_4(acc_in[1][4]),
        .acc_in_1_5(acc_in[1][5]),
        .acc_in_1_6(acc_in[1][6]),
        .acc_in_1_7(acc_in[1][7]),
        .acc_in_2_0(acc_in[2][0]),
        .acc_in_2_1(acc_in[2][1]),
        .acc_in_2_2(acc_in[2][2]),
        .acc_in_2_3(acc_in[2][3]),
        .acc_in_2_4(acc_in[2][4]),
        .acc_in_2_5(acc_in[2][5]),
        .acc_in_2_6(acc_in[2][6]),
        .acc_in_2_7(acc_in[2][7]),
        .acc_in_3_0(acc_in[3][0]),
        .acc_in_3_1(acc_in[3][1]),
        .acc_in_3_2(acc_in[3][2]),
        .acc_in_3_3(acc_in[3][3]),
        .acc_in_3_4(acc_in[3][4]),
        .acc_in_3_5(acc_in[3][5]),
        .acc_in_3_6(acc_in[3][6]),
        .acc_in_3_7(acc_in[3][7]),
        .acc_in_4_0(acc_in[4][0]),
        .acc_in_4_1(acc_in[4][1]),
        .acc_in_4_2(acc_in[4][2]),
        .acc_in_4_3(acc_in[4][3]),
        .acc_in_4_4(acc_in[4][4]),
        .acc_in_4_5(acc_in[4][5]),
        .acc_in_4_6(acc_in[4][6]),
        .acc_in_4_7(acc_in[4][7]),
        .acc_in_5_0(acc_in[5][0]),
        .acc_in_5_1(acc_in[5][1]),
        .acc_in_5_2(acc_in[5][2]),
        .acc_in_5_3(acc_in[5][3]),
        .acc_in_5_4(acc_in[5][4]),
        .acc_in_5_5(acc_in[5][5]),
        .acc_in_5_6(acc_in[5][6]),
        .acc_in_5_7(acc_in[5][7]),
        .acc_in_6_0(acc_in[6][0]),
        .acc_in_6_1(acc_in[6][1]),
        .acc_in_6_2(acc_in[6][2]),
        .acc_in_6_3(acc_in[6][3]),
        .acc_in_6_4(acc_in[6][4]),
        .acc_in_6_5(acc_in[6][5]),
        .acc_in_6_6(acc_in[6][6]),
        .acc_in_6_7(acc_in[6][7]),
        .acc_in_7_0(acc_in[7][0]),
        .acc_in_7_1(acc_in[7][1]),
        .acc_in_7_2(acc_in[7][2]),
        .acc_in_7_3(acc_in[7][3]),
        .acc_in_7_4(acc_in[7][4]),
        .acc_in_7_5(acc_in[7][5]),
        .acc_in_7_6(acc_in[7][6]),
        .acc_in_7_7(acc_in[7][7]),

        .start_output(start_output),

        .m_axis_tdata (m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast (m_axis_tlast),
        .m_axis_tready(m_axis_tready),

        .done(done)
    );

    // Clock
    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    integer i, j;
    integer errors;
    integer beats_seen;
    integer row_chk, col_chk;
    reg signed [ACC_WIDTH-1:0] exp0, exp1;
    reg signed [ACC_WIDTH-1:0] got0, got1;

    initial begin
        $display("========================================");
        $display("Output Collector Testbench (AXIS 64-bit)");
        $display("========================================");

        // Init
        rst_n         = 1'b0;
        start_output  = 1'b0;
        m_axis_tready = 1'b1;  // always ready
        errors        = 0;

        for (i = 0; i < ARRAY_SIZE; i = i + 1)
        for (j = 0; j < ARRAY_SIZE; j = j + 1) acc_in[i][j] = 0;

        // Reset
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Load deterministic matrix: val = i*ARRAY_SIZE + j
        for (i = 0; i < ARRAY_SIZE; i = i + 1)
        for (j = 0; j < ARRAY_SIZE; j = j + 1) acc_in[i][j] = i * ARRAY_SIZE + j;

        // Start streaming
        start_output = 1'b1;
        @(posedge clk);
        start_output = 1'b0;

        // Check each accepted beat
        beats_seen = 0;
        row_chk = 0;
        col_chk = 0;

        while (beats_seen < TOTAL_BEATS) begin
            @(posedge clk);
            if (m_axis_tvalid && m_axis_tready) begin
                got0 = m_axis_tdata[31:0];
                got1 = m_axis_tdata[63:32];

                exp0 = acc_in[row_chk][col_chk];
                if (col_chk + 1 < ARRAY_SIZE) exp1 = acc_in[row_chk][col_chk+1];
                else exp1 = 0;

                $display("Beat %0d row %0d col %0d: got=(%0d,%0d) exp=(%0d,%0d) tlast=%0b",
                         beats_seen, row_chk, col_chk, got0, got1, exp0, exp1, m_axis_tlast);

                if (got0 != exp0) begin
                    $display("ERROR: lane0 mismatch at row %0d col %0d", row_chk, col_chk);
                    errors = errors + 1;
                end
                if (got1 != exp1) begin
                    $display("ERROR: lane1 mismatch at row %0d col %0d", row_chk, col_chk + 1);
                    errors = errors + 1;
                end

                // TLAST check
                if (beats_seen == TOTAL_BEATS - 1) begin
                    if (m_axis_tlast !== 1'b1) begin
                        $display("ERROR: TLAST not asserted on final beat");
                        errors = errors + 1;
                    end
                end else begin
                    if (m_axis_tlast !== 1'b0) begin
                        $display("ERROR: TLAST asserted early at beat %0d", beats_seen);
                        errors = errors + 1;
                    end
                end

                // Advance expected indices
                col_chk = col_chk + VALUES_PER_BEAT;
                if (col_chk >= ARRAY_SIZE) begin
                    col_chk = 0;
                    row_chk = row_chk + 1;
                end

                beats_seen = beats_seen + 1;
            end
        end

        // done should be high at/after the final transfer
        @(posedge clk);
        if (done !== 1'b1) begin
            $display("ERROR: done not asserted after final beat");
            errors = errors + 1;
        end else begin
            $display("PASS: done asserted as expected");
        end

        $display("\n========================================");
        if (errors == 0) $display("*** ALL TESTS PASSED ***");
        else $display("*** TESTS FAILED: %0d errors ***", errors);
        $display("========================================");

        $finish;
    end

    // Safety timeout
    initial begin
        #(CLK_PERIOD * 10000);
        $display("\n[%0t] ERROR: Testbench timeout!", $time);
        $finish;
    end

endmodule
