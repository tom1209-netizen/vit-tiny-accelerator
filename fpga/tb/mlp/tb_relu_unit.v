`timescale 1ns / 1ps

module tb_relu_unit;

    // Parameters
    parameter AXIS_DATA_WIDTH = 64;
    parameter DATA_WIDTH      = 8;
    parameter CLK_PERIOD      = 10;

    localparam VALUES_PER_BEAT    = AXIS_DATA_WIDTH / DATA_WIDTH;
    localparam MAX_CYCLES         = 20000;

    // Hardcoded configuration for this testbench
    localparam BEAT_PER_PACKET    = 10;
    localparam MAX_BEATS          = 20;

    // Testbench Signals
    reg                         clk;
    reg                         rst_n;

    // AXI4-Stream input signals (AXIS_DATA_WIDTH = 64 bits)
    reg  [AXIS_DATA_WIDTH-1:0]  s_axis_tdata;
    reg                         s_axis_tvalid;
    reg                         s_axis_tlast;
    wire                        s_axis_tready;

    // AXI4-Stream output signals (AXIS_DATA_WIDTH = 64 bits)
    wire [AXIS_DATA_WIDTH-1:0]  m_axis_tdata;
    wire                        m_axis_tvalid;
    wire                        m_axis_tlast;
    reg                         m_axis_tready;

    reg  [31:0]                 cycles;
    reg  [7:0]                  current_test;
    integer                     total_errors;

    // Expected data stores for different tests
    reg signed [AXIS_DATA_WIDTH-1:0] sent_data_continuous  [0:MAX_BEATS-1];
    reg signed [AXIS_DATA_WIDTH-1:0] check_data_continuous [0:MAX_BEATS-1];

    // Instantiate the DUT
    relu_unit #(
        .AXIS_DATA_WIDTH (AXIS_DATA_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH)
    ) uut (
        .clk            (clk),
        .rst_n          (rst_n),

        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tlast   (s_axis_tlast),
        .s_axis_tready  (s_axis_tready),

        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tlast   (m_axis_tlast),
        .m_axis_tready  (m_axis_tready)
    );

    // Clock generation
    initial clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // Watchdog counter
    initial cycles = 0;
    always @(posedge clk) cycles = cycles + 1;

    always @(posedge clk) begin
        if (cycles == MAX_CYCLES) begin
            $display("TIMEOUT at cycle %0d in test %0d", cycles, current_test);
            $display("  tvalid=%0b tready=%0b", s_axis_tvalid, s_axis_tready);
            $finish;
        end
    end

    // Stimulus
    initial begin
        // 1. Initial reset sequence
        initialize_tests();
        #(CLK_PERIOD * 5) rst_n = 1'b1; // Deassert reset after some clock cycles

        $display("==========================================");
        $display("ReLU Unit Testbench");
        $display("==========================================");

        // Run all tests
        @(posedge clk);
        run_single_test();
        run_continuous_test();

        // Summary
        $display("\n==========================================");
        $display("TEST SUMMARY");
        $display("==========================================");
        if (total_errors == 0) begin
            $display("PASS: All tests completed successfully!");
        end else begin
            $display("FAIL: %0d total errors across all tests", total_errors);
        end
        $display("==========================================");
        $finish;
    end

    // Initialize signals and test data, mainly apply reset
    task initialize_tests;
        begin
            total_errors = 0;
            current_test = 0;

            rst_n         = 1'b0; // Active-low reset asserted

            // s_axis_tdata = {AXIS_DATA_WIDTH{1'b0}};
            s_axis_tdata  = {AXIS_DATA_WIDTH{1'bX}};
            s_axis_tvalid = 1'b0;
            s_axis_tlast  = 1'b0;

            // m_axis_tdata = {AXIS_DATA_WIDTH{1'bX}};
            m_axis_tready = 1'b0;

            // Initialize test data arrays
            // Test Case 1: +1 (all lanes) -> 0x01
            sent_data_continuous[0]  = 64'h0101010101010101;
            check_data_continuous[0] = 64'h0101010101010101;

            // Test Case 2: All ones (0xFF) -> 0x00
            sent_data_continuous[1]  = 64'hFFFFFFFFFFFFFFFF;
            check_data_continuous[1] = 64'h0000000000000000;

            // Test Case 3: +127 (all lanes) -> 0x7F
            sent_data_continuous[2]  = 64'h7F7F7F7F7F7F7F7F;
            check_data_continuous[2] = 64'h7F7F7F7F7F7F7F7F;

            // Test Case 4: -128 (all lanes) -> 0x00
            sent_data_continuous[3]  = 64'h8080808080808080;
            check_data_continuous[3] = 64'h0000000000000000;

            // Test Case 5: Mixed values (80=-128, 25=+37, 01=+1, 20=+32, 05=+5)
            sent_data_continuous[4]  = 64'h8000250001002005;
            check_data_continuous[4] = 64'h0000250001002005;

            // Test Case 6: All positives
            sent_data_continuous[5]  = 64'h7F00110004002005;
            check_data_continuous[5] = 64'h7F00110004002005;

            // Test Case 7: Mixed positives and negatives (85=-123, 95=-107, FA=-6)
            sent_data_continuous[6]  = 64'h7F0085009500FA00;
            check_data_continuous[6] = 64'h7F00000000000000;

            // Test Case 8: Mixed values (A5=-91, 88=-120)
            sent_data_continuous[7]  = 64'hA500110044008899;
            check_data_continuous[7] = 64'h0000110044000000;

            // Test Case 9: Alternating negatives
            sent_data_continuous[8]  = 64'hFF00FF00FF00FF00;
            check_data_continuous[8] = 64'h0000000000000000;

            // Test Case 10: Some negatives (80=-128, A9=-87)
            sent_data_continuous[9]  = 64'h0809008000FF00A9;
            check_data_continuous[9] = 64'h0809000000000000;

            // Test Case 11: Negative boundary (close to 0)
            sent_data_continuous[10]  = 64'hFEFEFEFEFEFEFEFE;
            check_data_continuous[10] = 64'h0000000000000000;

            // Test Case 12: Positive boundary (close to 0)
            sent_data_continuous[11]  = 64'h0202020202020202;
            check_data_continuous[11] = 64'h0202020202020202;

            // Test Case 13: Alternating negative and positive
            sent_data_continuous[12]  = 64'hA5B6C7D801020304;
            check_data_continuous[12] = 64'h0000000001020304;

            // Test Case 14: Alternating negative and zero
            sent_data_continuous[13]  = 64'h00A500B600C700D8;
            check_data_continuous[13] = 64'h0000000000000000;

            // Test Case 15: Alternating positive and zero
            sent_data_continuous[14]  = 64'h007F001000300060;
            check_data_continuous[14] = 64'h007F001000300060;

            // Test Case 16: All boundaries
            sent_data_continuous[15]  = 64'h7F8000FF01FE02FD;
            check_data_continuous[15] = 64'h7F00000001000200;

            // Test Case 17: Large/small positive values
            sent_data_continuous[16]  = 64'h7A05700A6014501E;
            check_data_continuous[16] = 64'h7A05700A6014501E;

            // Test Case 18: Large/small negative values
            sent_data_continuous[17]  = 64'h81F08AF590FA95FF;
            check_data_continuous[17] = 64'h0000000000000000;

            // Test Case 19: Half negative (first 4 bytes), half positive (last 4 bytes)
            sent_data_continuous[18]  = 64'h808080807F7F7F7F;
            check_data_continuous[18] = 64'h000000007F7F7F7F;

            // Test Case 20: All zeros
            sent_data_continuous[19]  = 64'h0000000000000000;
            check_data_continuous[19] = 64'h0000000000000000;
        end
    endtask

    // Task to print the result of each test case
    task automatic print_result;
        input integer                  id;
        input [AXIS_DATA_WIDTH-1:0]    input_val;
        input [AXIS_DATA_WIDTH-1:0]    expected_val;
        input [AXIS_DATA_WIDTH-1:0]    output_val;
        begin
            $display("\n============================================================");
            $display(" Test Case %0d", id);
            $display("------------------------------------------------------------");
            $display("   Input     : %h", input_val);
            $display("   Expected  : %h", expected_val);
            $display("   Output    : %h", output_val);
            if (output_val === expected_val) begin
                $display("   Result    : PASSED");
            end else begin
                $display("   Result    : FAILED");
                total_errors = total_errors + 1; // Update error counter
            end
            $display("============================================================\n");
        end
    endtask

    // Test 1: single-beat test cases
    localparam integer GAP_CYCLES = 0;

    task automatic run_test_case;
        input integer                test_case_id;
        input [AXIS_DATA_WIDTH-1:0]  input_data;
        input [AXIS_DATA_WIDTH-1:0]  expected_output;
        integer                      g;
        begin
            // Downstream is ready
            m_axis_tready = 1'b1;

            // Send 1 packet = 1 beat, hold until input handshake
            s_axis_tdata  = input_data;
            s_axis_tvalid = 1'b1;
            s_axis_tlast  = 1'b1;

            // Wait for input handshake
            @(posedge clk);
            while (!(s_axis_tvalid && s_axis_tready)) @(posedge clk);

            // Deassert source after handshake completes
            s_axis_tvalid = 1'b0;
            s_axis_tlast  = 1'b0;
            // s_axis_tdata  = {AXIS_DATA_WIDTH{1'bX}};

            // Wait for output handshake
            while (!(m_axis_tvalid && m_axis_tready)) @(posedge clk);

            // Compare result
            print_result(test_case_id, input_data, expected_output, m_axis_tdata);
            if (m_axis_tlast !== 1'b1)
                $error("Test %0d: Expected m_axis_tlast=1 for single-beat packet", test_case_id);

            // Optional gap between test cases
            for (g = 0; g < GAP_CYCLES; g = g + 1) @(posedge clk);

            // End of test case
            m_axis_tready = 1'b0;
        end
    endtask

    task run_single_test;
        integer i;
        begin
            current_test = 1;
            $display("\n================== Test 1: Single Test Cases ==================\n");

            // INT8 data (8 bits): bit 7 is sign bit. ReLU(x) = max(0, x).
            // Example: 0xFF = -1 (ReLU -> 0x00). 0x7F = +127 (ReLU -> 0x7F). 0x80 = -128 (ReLU -> 0x00).
            for (i = 0; i < MAX_BEATS; i = i + 1) begin
                run_test_case(i + 1, sent_data_continuous[i], check_data_continuous[i]);
            end
        end
    endtask

    // Send one packet with BEAT_PER_PACKET beats (non-continuous pattern with optional gaps)
    task automatic send_packet;
        input integer beat_counter;

        integer beat_idx;
        integer data_offset;
        begin
            beat_idx    = 0;
            data_offset = beat_counter * BEAT_PER_PACKET;

            s_axis_tvalid = 1'b0;
            m_axis_tready = 1'b1;

            if (BEAT_PER_PACKET > MAX_BEATS)
                $fatal(1, "BEAT_PER_PACKET must not exceed MAX_BEATS.");

            while (beat_idx < BEAT_PER_PACKET) begin
                @(posedge clk);
                if (s_axis_tready) begin
                    if (beat_idx < BEAT_PER_PACKET) begin
                        s_axis_tdata  = sent_data_continuous[beat_idx + data_offset];
                        s_axis_tvalid = 1'b1;
                        s_axis_tlast  = (beat_idx == BEAT_PER_PACKET - 1);
                    end
                    beat_idx = beat_idx + 1;
                end
            end

            // Deassert after the entire packet has been successfully handshaken
            @(posedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tlast  = 1'b0;
            // s_axis_tdata  = {AXIS_DATA_WIDTH{1'bX}};
        end
    endtask

    // Send one packet with BEAT_PER_PACKET beats continuously (back-to-back mode)
    task automatic send_packet_continuous;
        input integer beat_counter;

        integer beat_idx;
        integer data_offset;
        begin
            beat_idx    = 0;
            data_offset = beat_counter * BEAT_PER_PACKET;

            s_axis_tvalid = 1'b0;
            m_axis_tready = 1'b1;

            // @(posedge clk) wait(s_axis_tready);

            if (BEAT_PER_PACKET > MAX_BEATS)
                $fatal(1, "BEAT_PER_PACKET must not exceed MAX_BEATS.");

            // Main loop for send & handshake
            while (beat_idx < BEAT_PER_PACKET) begin
                @(posedge clk);
                if (s_axis_tready) begin
                    if (beat_idx < BEAT_PER_PACKET) begin
                        s_axis_tdata  = sent_data_continuous[beat_idx + data_offset];
                        s_axis_tvalid = 1'b1;
                        s_axis_tlast  = (beat_idx == BEAT_PER_PACKET - 1);
                    end
                    beat_idx = beat_idx + 1;
                end
            end

            // Deassert after the entire packet has been successfully handshaken
            @(posedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tlast  = 1'b0;
            // s_axis_tdata  = {AXIS_DATA_WIDTH{1'bX}};
        end
    endtask

    // Test 2: continuous test cases
    task automatic run_continuous_test;
        integer counter;
        integer packets_per_phase;
        begin
            current_test     = 2;
            packets_per_phase = MAX_BEATS / BEAT_PER_PACKET;

            $display("\n================== Test 2: Continuous Test Cases ==================\n");
            $display("  Configuration:");
            $display("    AXIS_DATA_WIDTH   = %0d", AXIS_DATA_WIDTH);
            $display("    DATA_WIDTH        = %0d", DATA_WIDTH);
            $display("    VALUES_PER_BEAT   = %0d", VALUES_PER_BEAT);
            $display("    BEAT_PER_PACKET   = %0d", BEAT_PER_PACKET);
            $display("    MAX_BEATS         = %0d", MAX_BEATS);
            $display("    Packets per phase = %0d", packets_per_phase);

            // Phase 1: Packets with small gaps between them (using send_packet)
            $display("\n  [Phase 1] Non-continuous streaming using send_packet()");
            counter = 0;
            while (counter < packets_per_phase) begin
                $display("    -> Sending packet %0d/%0d with send_packet() (non-continuous)",
                         counter + 1, packets_per_phase);
                send_packet(counter);
                counter = counter + 1;
                repeat (5) @(posedge clk);  // Small gap between packets
            end

            // Phase 2: Packets back-to-back (continuous streaming)
            $display("\n  [Phase 2] Continuous back-to-back streaming using send_packet_continuous()");
            counter = 0;
            while (counter < packets_per_phase) begin
                $display("    -> Sending packet %0d/%0d with send_packet_continuous() (continuous)",
                         counter + 1, packets_per_phase);
                send_packet_continuous(counter);
                counter = counter + 1;
            end

            $display("\n  [Test 2] Completed all continuous packets.\n");
            repeat (5) @(posedge clk);
        end
    endtask

endmodule
