`timescale 1ns / 1ps

module tb_residual_add;
    localparam DATA_WIDTH = 64;
    localparam ELEM_WIDTH = 8;
    localparam integer LANES = DATA_WIDTH / ELEM_WIDTH;
    localparam CLK_PERIOD = 10;  // 100 MHz
    localparam integer MAX_CYCLES = 10000;

    // Clock / reset
    reg                      clk;
    reg                      rst_n;

    // AXIS A
    reg     [DATA_WIDTH-1:0] s_axis_a_tdata;
    reg                      s_axis_a_tvalid;
    reg                      s_axis_a_tlast;
    wire                     s_axis_a_tready;

    // AXIS B
    reg     [DATA_WIDTH-1:0] s_axis_b_tdata;
    reg                      s_axis_b_tvalid;
    reg                      s_axis_b_tlast;
    wire                     s_axis_b_tready;

    // AXIS output
    wire    [DATA_WIDTH-1:0] m_axis_tdata;
    wire                     m_axis_tvalid;
    wire                     m_axis_tlast;
    reg                      m_axis_tready;

    integer                  cycles;
    integer                  errors;

    // DUT
    residual_add #(
        .DATA_WIDTH(DATA_WIDTH),
        .ELEM_WIDTH(ELEM_WIDTH)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_a_tdata (s_axis_a_tdata),
        .s_axis_a_tvalid(s_axis_a_tvalid),
        .s_axis_a_tlast (s_axis_a_tlast),
        .s_axis_a_tready(s_axis_a_tready),
        .s_axis_b_tdata (s_axis_b_tdata),
        .s_axis_b_tvalid(s_axis_b_tvalid),
        .s_axis_b_tlast (s_axis_b_tlast),
        .s_axis_b_tready(s_axis_b_tready),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tlast   (m_axis_tlast),
        .m_axis_tready  (m_axis_tready)
    );

    // Clock generator
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // Watchdog, like tb_gemm_core_top
    initial cycles = 0;
    always @(posedge clk) cycles = cycles + 1;
    always @(posedge clk) begin
        if (cycles == MAX_CYCLES) begin
            $display("TIMEOUT at cycle %0d", cycles);
            $finish;
        end
    end

    // Expected queue / scoreboard
    reg     [DATA_WIDTH-1:0] exp_data          [0:255];
    reg                      exp_last          [0:255];
    integer                  exp_head;
    integer                  exp_tail;

    reg     [      8*64-1:0] current_test_name;
    integer                  unnamed_beat_idx;

    // Test name banner 
    task set_test_name;
        input [8*64-1:0] name;
        begin
            current_test_name = name;
            unnamed_beat_idx  = 0;
            $display("\n=== %0s ===", current_test_name);
        end
    endtask

    // Initialize / reset tasks to match GEMM TB style
    task initialize_sim;
        begin
            s_axis_a_tdata  = {DATA_WIDTH{1'b0}};
            s_axis_b_tdata  = {DATA_WIDTH{1'b0}};
            s_axis_a_tvalid = 1'b0;
            s_axis_b_tvalid = 1'b0;
            s_axis_a_tlast  = 1'b0;
            s_axis_b_tlast  = 1'b0;
            m_axis_tready   = 1'b1;
            rst_n           = 1'b0;
            exp_head        = 0;
            exp_tail        = 0;
            errors          = 0;
            cycles          = 0;
        end
    endtask

    task reset_dut;
        begin
            @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    // Saturating add helper aligned with the fixed residual_add module
    function [ELEM_WIDTH-1:0] sat_add;
        input signed [ELEM_WIDTH-1:0] a;
        input signed [ELEM_WIDTH-1:0] b;
        reg signed [ELEM_WIDTH : 0] a_ext;
        reg signed [ELEM_WIDTH : 0] b_ext;
        reg signed [ELEM_WIDTH : 0] sum_ext;
        begin
            a_ext   = {a[ELEM_WIDTH-1], a};
            b_ext   = {b[ELEM_WIDTH-1], b};
            sum_ext = a_ext + b_ext;

            // Overflow if MSB differs from next bit
            if (sum_ext[ELEM_WIDTH] != sum_ext[ELEM_WIDTH-1]) begin
                if (sum_ext[ELEM_WIDTH] == 1'b0)
                    sat_add = {1'b0, {(ELEM_WIDTH - 1) {1'b1}}};  // +max
                else sat_add = {1'b1, {(ELEM_WIDTH - 1) {1'b0}}};  // -min
            end else begin
                sat_add = sum_ext[ELEM_WIDTH-1:0];
            end
        end
    endfunction

    // Push expected beat into scoreboard
    task push_expected;
        input [DATA_WIDTH-1:0] a_vec;
        input [DATA_WIDTH-1:0] b_vec;
        input last;
        integer                  lane;
        reg     [DATA_WIDTH-1:0] sum_vec;
        begin
            for (lane = 0; lane < LANES; lane = lane + 1) begin
                sum_vec[lane*ELEM_WIDTH+:ELEM_WIDTH] =
                    sat_add(a_vec[lane*ELEM_WIDTH+:ELEM_WIDTH], b_vec[lane*ELEM_WIDTH+:ELEM_WIDTH]);
            end
            exp_data[exp_tail] = sum_vec;
            exp_last[exp_tail] = last;
            exp_tail           = exp_tail + 1;
        end
    endtask

    // Drive a single pair with optional backpressure on output
    task drive_pair_with_stall;
        input [DATA_WIDTH-1:0] a_vec;
        input [DATA_WIDTH-1:0] b_vec;
        input last;
        input integer stall_cycles;
        input integer beat_idx;
        integer sc;
        begin
            // For TLAST expectations we assume AND semantics here:
            // test passes last = 1 only when both inputs intend to be 'last'
            push_expected(a_vec, b_vec, last);

            $display("[%0t] %0s Beat %0d: A=%h B=%h LAST=%0b (stall %0d cycles)", $time,
                     current_test_name, beat_idx, a_vec, b_vec, last, stall_cycles);

            s_axis_a_tdata  <= a_vec;
            s_axis_b_tdata  <= b_vec;
            s_axis_a_tlast  <= last;
            s_axis_b_tlast  <= last;
            s_axis_a_tvalid <= 1'b1;
            s_axis_b_tvalid <= 1'b1;

            if (stall_cycles > 0) begin
                m_axis_tready <= 1'b0;
                for (sc = 0; sc < stall_cycles; sc = sc + 1) @(posedge clk);
            end

            m_axis_tready <= 1'b1;

            // Wait one cycle then handshake on both inputs
            @(posedge clk);
            while (!(s_axis_a_tready && s_axis_b_tready)) @(posedge clk);

            s_axis_a_tvalid <= 1'b0;
            s_axis_b_tvalid <= 1'b0;
            s_axis_a_tlast  <= 1'b0;
            s_axis_b_tlast  <= 1'b0;
        end
    endtask

    task drive_pair;
        input [DATA_WIDTH-1:0] a_vec;
        input [DATA_WIDTH-1:0] b_vec;
        input last;
        begin
            drive_pair_with_stall(a_vec, b_vec, last, 0, unnamed_beat_idx);
            unnamed_beat_idx = unnamed_beat_idx + 1;
        end
    endtask

    // Test 1: deterministic AXI stream
    task base_axi_stream_test;
        integer beat;
        reg [DATA_WIDTH-1:0] seq_a[0:3];
        reg [DATA_WIDTH-1:0] seq_b[0:3];
        begin
            set_test_name("Base 64-bit AXI stream");

            seq_a[0] = 64'h0807060504030201;
            seq_a[1] = 64'h100F0E0D0C0B0A09;
            seq_a[2] = 64'h1817161514131211;
            seq_a[3] = 64'h201F1E1D1C1B1A19;

            seq_b[0] = 64'h0101010101010101;
            seq_b[1] = 64'h0202020202020202;
            seq_b[2] = 64'h0303030303030303;
            seq_b[3] = 64'h0404040404040404;

            for (beat = 0; beat < 4; beat = beat + 1) begin
                drive_pair_with_stall(seq_a[beat], seq_b[beat], (beat == 3), 0, beat);
            end
        end
    endtask

    // Test 2: saturation extremes
    task saturation_extremes_test;
        begin
            set_test_name("Saturation extremes");

            // Large positive + positive
            drive_pair({LANES{8'sd120}}, {LANES{8'sd120}}, 1'b1);

            // Large negative + negative
            drive_pair({LANES{-8'sd100}}, {LANES{-8'sd60}}, 1'b1);
        end
    endtask

    // Test 3: zeros vs random values with backpressure
    task zero_vs_random_test;
        integer beat;
        begin
            set_test_name("Zero vs random");
            for (beat = 0; beat < 4; beat = beat + 1) begin
                drive_pair_with_stall({DATA_WIDTH{1'b0}}, {$random, $random, $random, $random},
                                      (beat == 3), beat % 2,  // introduce some stalls
                                      beat);
            end
        end
    endtask

    // Test 4: alternating sign pattern
    task alternating_sign_test;
        integer beat;
        reg [DATA_WIDTH-1:0] vec_a, vec_b;
        begin
            set_test_name("Alternating sign vectors");
            for (beat = 0; beat < 3; beat = beat + 1) begin
                vec_a = {LANES{(beat[0]) ? 8'sd30 : -8'sd30}};
                vec_b = {LANES{(beat[0]) ? -8'sd25 : 8'sd25}};
                drive_pair(vec_a, vec_b, (beat == 2));
            end
        end
    endtask

    // Test 5: TLAST mismatch scenario
    task tlast_mismatch_test;
        reg [DATA_WIDTH-1:0] a_vec, b_vec;
        begin
            set_test_name("TLAST mismatch scenario");

            a_vec = 64'h0505050505050505;
            b_vec = 64'h0101010101010101;

            // Expect TLAST = 0 because DUT uses AND semantics
            push_expected(a_vec, b_vec, 1'b0);

            s_axis_a_tdata  <= a_vec;
            s_axis_b_tdata  <= b_vec;
            s_axis_a_tlast  <= 1'b1;
            s_axis_b_tlast  <= 1'b0;
            s_axis_a_tvalid <= 1'b1;
            s_axis_b_tvalid <= 1'b1;

            @(posedge clk);
            while (!(s_axis_a_tready && s_axis_b_tready)) @(posedge clk);

            s_axis_a_tvalid <= 1'b0;
            s_axis_b_tvalid <= 1'b0;
            s_axis_a_tlast  <= 1'b0;
            s_axis_b_tlast  <= 1'b0;

            // allow beat to drain
            @(posedge clk);
        end
    endtask

    // Output monitor / scoreboard drain
    always @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            $display("[%0t] Output beat %0d (Test: %0s): data=%h exp=%h last=%0b exp_last=%0b",
                     $time, exp_head, current_test_name, m_axis_tdata, exp_data[exp_head],
                     m_axis_tlast, exp_last[exp_head]);

            if (m_axis_tdata !== exp_data[exp_head]) begin
                $display("ERROR: Data mismatch beat %0d exp=%0h got=%0h", exp_head,
                         exp_data[exp_head], m_axis_tdata);
                errors = errors + 1;
            end
            if (m_axis_tlast !== exp_last[exp_head]) begin
                $display("ERROR: TLAST mismatch beat %0d exp=%0b got=%0b", exp_head,
                         exp_last[exp_head], m_axis_tlast);
                errors = errors + 1;
            end

            exp_head = exp_head + 1;
        end
    end

    // Summary task
    task print_summary;
        begin
            $display("\n========================================");
            if (errors == 0) begin
                $display("*** residual_add: ALL TESTS PASSED! ***");
            end else begin
                $display("*** residual_add: FAILED with %0d errors ***", errors);
            end
            $display("========================================");
        end
    endtask

    // Main test sequence
    initial begin : main_test
        $display("========================================");
        $display("Residual Add Testbench");
        $display("========================================");

        initialize_sim;
        @(posedge clk);
        reset_dut;

        base_axi_stream_test;
        @(posedge clk);
        saturation_extremes_test;
        @(posedge clk);
        zero_vs_random_test;
        @(posedge clk);
        alternating_sign_test;
        @(posedge clk);
        tlast_mismatch_test;

        // Wait for all expected beats to be observed
        wait (exp_head == exp_tail);

        print_summary;

        $finish;
    end

endmodule
