`timescale 1ns / 1ps

module tb_input_buffer_controller;
    // Parameters
    parameter DATA_WIDTH = 8;
    parameter ARRAY_SIZE = 8;
    parameter AXIS_DATA_WIDTH = 64;
    parameter CLK_PERIOD = 10;

    localparam VALUES_PER_BEAT = AXIS_DATA_WIDTH / DATA_WIDTH;  // 8
    localparam TOTAL_VALUES = ARRAY_SIZE * ARRAY_SIZE;  // 64
    localparam NUM_INPUT_BEATS = TOTAL_VALUES / VALUES_PER_BEAT;  // 8
    localparam MAX_CYCLES = 20000;

    // Testbench signals
    reg                               clk;
    reg                               rst_n;
    reg                               enable;

    // AXI-Stream signals
    reg         [AXIS_DATA_WIDTH-1:0] s_axis_tdata;
    reg                               s_axis_tvalid;
    reg                               s_axis_tlast;
    wire                              s_axis_tready;

    // DUT Outputs
    wire signed [     DATA_WIDTH-1:0] data_out_0;
    wire signed [     DATA_WIDTH-1:0] data_out_1;
    wire signed [     DATA_WIDTH-1:0] data_out_2;
    wire signed [     DATA_WIDTH-1:0] data_out_3;
    wire signed [     DATA_WIDTH-1:0] data_out_4;
    wire signed [     DATA_WIDTH-1:0] data_out_5;
    wire signed [     DATA_WIDTH-1:0] data_out_6;
    wire signed [     DATA_WIDTH-1:0] data_out_7;
    wire                              data_valid;

    // Expected data stores for different tests
    reg signed  [     DATA_WIDTH-1:0] sent_data_continuous  [0:TOTAL_VALUES-1];
    reg signed  [     DATA_WIDTH-1:0] sent_data_backpressure[0:TOTAL_VALUES-1];
    reg signed  [     DATA_WIDTH-1:0] sent_data_intermittent[0:TOTAL_VALUES-1];

    // Internals
    integer i, j, k, errors, out_row;
    integer                       idx;
    reg     [               31:0] val32;
    reg     [AXIS_DATA_WIDTH-1:0] beat;
    reg     [               31:0] cycles;
    reg     [               31:0] handshakes;

    // Test control
    reg test_continuous, test_backpressure, test_intermittent, test_reset;
    reg [7:0] current_test;
    integer total_errors;

    // Backpressure control
    reg apply_backpressure;
    integer backpressure_cycles;

    // DUT
    input_buffer_controller #(
        .DATA_WIDTH(DATA_WIDTH),
        .ARRAY_SIZE(ARRAY_SIZE),
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        .data_out_0(data_out_0),
        .data_out_1(data_out_1),
        .data_out_2(data_out_2),
        .data_out_3(data_out_3),
        .data_out_4(data_out_4),
        .data_out_5(data_out_5),
        .data_out_6(data_out_6),
        .data_out_7(data_out_7),
        .data_valid(data_valid)
    );

    // Clock
    initial clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // Watchdog
    initial cycles = 0;
    always @(posedge clk) cycles = cycles + 1;

    always @(posedge clk) begin
        if (cycles == MAX_CYCLES) begin
            $display("TIMEOUT at cycle %0d in test %0d", cycles, current_test);
            $display("  tvalid=%0b tready=%0b data_valid=%0b", s_axis_tvalid, s_axis_tready,
                     data_valid);
            $finish;
        end
    end

    // Main test sequence
    initial begin
        total_errors = 0;
        initialize_tests();

        $display("==========================================");
        $display("Input Buffer Controller Testbench");
        $display("==========================================");

        // Run all tests
        run_continuous_test();
        run_backpressure_test();
        run_intermittent_test();
        run_reset_test();

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

    task initialize_tests;
        begin
            // Initialize all signals
            rst_n              = 1'b0;
            enable             = 1'b0;
            s_axis_tdata       = {AXIS_DATA_WIDTH{1'b0}};
            s_axis_tvalid      = 1'b0;
            s_axis_tlast       = 1'b0;
            apply_backpressure = 1'b0;

            test_continuous    = 1'b0;
            test_backpressure  = 1'b0;
            test_intermittent  = 1'b0;
            test_reset         = 1'b0;
            current_test       = 0;

            // Precompute test data patterns
            for (i = 0; i < NUM_INPUT_BEATS; i = i + 1) begin
                for (j = 0; j < VALUES_PER_BEAT; j = j + 1) begin
                    // Continuous test: sequential numbers
                    val32 = i * VALUES_PER_BEAT + j;
                    sent_data_continuous[i*VALUES_PER_BEAT+j] = val32[DATA_WIDTH-1:0];

                    // Backpressure test: different pattern
                    val32 = i * VALUES_PER_BEAT + j + 100;
                    sent_data_backpressure[i*VALUES_PER_BEAT+j] = val32[DATA_WIDTH-1:0];

                    // Intermittent test: another pattern
                    val32 = i * VALUES_PER_BEAT + j + 200;
                    sent_data_intermittent[i*VALUES_PER_BEAT+j] = val32[DATA_WIDTH-1:0];
                end
            end

            // Release reset after setup
            repeat (5) @(posedge clk);
            rst_n  = 1'b1;
            enable = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    // Test 1: Continuous streaming (original test)
    task run_continuous_test;
        begin
            current_test = 1;
            test_continuous = 1'b1;
            errors = 0;
            out_row = 0;
            idx = 0;
            handshakes = 0;
            cycles = 0;

            $display("\n=== Test 1: Continuous Streaming ===");
            $display("Sending %0d beats continuously", NUM_INPUT_BEATS);

            fork
                begin : continuous_driver
                    wait (rst_n == 1'b1);
                    @(posedge clk);
                    // Wait for initial ready
                    wait (s_axis_tready);
                    @(posedge clk);

                    // Prepare first beat
                    beat = {AXIS_DATA_WIDTH{1'b0}};
                    for (j = 0; j < VALUES_PER_BEAT; j = j + 1) begin
                        val32 = idx * VALUES_PER_BEAT + j;
                        beat[j*DATA_WIDTH+:DATA_WIDTH] = val32[DATA_WIDTH-1:0];
                    end
                    s_axis_tdata  = beat;
                    s_axis_tlast  = (idx == NUM_INPUT_BEATS - 1);
                    s_axis_tvalid = 1'b1;

                    // Stream all beats continuously
                    while (idx < NUM_INPUT_BEATS) begin
                        @(posedge clk);
                        if (s_axis_tready) begin
                            handshakes = handshakes + 1;
                            $display("  Handshake #%0d (beat %0d) TLAST=%0b", handshakes, idx,
                                     s_axis_tlast);
                            idx = idx + 1;
                            if (idx < NUM_INPUT_BEATS) begin
                                beat = {AXIS_DATA_WIDTH{1'b0}};
                                for (j = 0; j < VALUES_PER_BEAT; j = j + 1) begin
                                    val32 = idx * VALUES_PER_BEAT + j;
                                    beat[j*DATA_WIDTH+:DATA_WIDTH] = val32[DATA_WIDTH-1:0];
                                end
                                s_axis_tdata = beat;
                                s_axis_tlast = (idx == NUM_INPUT_BEATS - 1);
                            end
                        end
                    end

                    // Deassert after last handshake
                    s_axis_tvalid = 1'b0;
                    s_axis_tlast  = 1'b0;
                    s_axis_tdata  = {AXIS_DATA_WIDTH{1'b0}};
                end

                begin : continuous_monitor
                    wait (rst_n == 1'b1);
                    @(posedge clk);

                    while (out_row < NUM_INPUT_BEATS) begin
                        @(posedge clk);
                        if (data_valid) begin
                            $display("  Consumed beat %0d", out_row);
                            // Compare each lane explicitly
                            if (data_out_0 !== sent_data_continuous[out_row*ARRAY_SIZE+0]) begin
                                errors = errors + 1;
                                $display("ERROR: data_out_0: expected %0d, got %0d",
                                         sent_data_continuous[out_row*ARRAY_SIZE+0], data_out_0);
                            end
                            if (data_out_1 !== sent_data_continuous[out_row*ARRAY_SIZE+1]) begin
                                errors = errors + 1;
                                $display("ERROR: data_out_1: expected %0d, got %0d",
                                         sent_data_continuous[out_row*ARRAY_SIZE+1], data_out_1);
                            end
                            if (data_out_2 !== sent_data_continuous[out_row*ARRAY_SIZE+2]) begin
                                errors = errors + 1;
                                $display("ERROR: data_out_2: expected %0d, got %0d",
                                         sent_data_continuous[out_row*ARRAY_SIZE+2], data_out_2);
                            end
                            if (data_out_3 !== sent_data_continuous[out_row*ARRAY_SIZE+3]) begin
                                errors = errors + 1;
                                $display("ERROR: data_out_3: expected %0d, got %0d",
                                         sent_data_continuous[out_row*ARRAY_SIZE+3], data_out_3);
                            end
                            if (data_out_4 !== sent_data_continuous[out_row*ARRAY_SIZE+4]) begin
                                errors = errors + 1;
                                $display("ERROR: data_out_4: expected %0d, got %0d",
                                         sent_data_continuous[out_row*ARRAY_SIZE+4], data_out_4);
                            end
                            if (data_out_5 !== sent_data_continuous[out_row*ARRAY_SIZE+5]) begin
                                errors = errors + 1;
                                $display("ERROR: data_out_5: expected %0d, got %0d",
                                         sent_data_continuous[out_row*ARRAY_SIZE+5], data_out_5);
                            end
                            if (data_out_6 !== sent_data_continuous[out_row*ARRAY_SIZE+6]) begin
                                errors = errors + 1;
                                $display("ERROR: data_out_6: expected %0d, got %0d",
                                         sent_data_continuous[out_row*ARRAY_SIZE+6], data_out_6);
                            end
                            if (data_out_7 !== sent_data_continuous[out_row*ARRAY_SIZE+7]) begin
                                errors = errors + 1;
                                $display("ERROR: data_out_7: expected %0d, got %0d",
                                         sent_data_continuous[out_row*ARRAY_SIZE+7], data_out_7);
                            end
                            out_row = out_row + 1;
                        end
                    end
                end
            join

            if (errors == 0)
                $display("PASS: Continuous test - All %0d beats matched", NUM_INPUT_BEATS);
            else $display("FAIL: Continuous test - %0d mismatches", errors);

            total_errors = total_errors + errors;
            test_continuous = 1'b0;
            // Small gap between tests
            repeat (10) @(posedge clk);
        end
    endtask

    // Test 2: Backpressure simulation
    task run_backpressure_test;
        begin
            current_test = 2;
            test_backpressure = 1'b1;
            errors = 0;
            out_row = 0;
            idx = 0;
            handshakes = 0;
            cycles = 0;
            apply_backpressure = 1'b0;

            $display("\n=== Test 2: Backpressure Simulation ===");
            $display("Sending %0d beats with random backpressure", NUM_INPUT_BEATS);

            fork
                begin : backpressure_driver
                    wait (rst_n == 1'b1);
                    @(posedge clk);
                    wait (s_axis_tready);
                    @(posedge clk);

                    while (idx < NUM_INPUT_BEATS) begin
                        // Random backpressure: 25% chance to pause
                        if (($urandom % 4) == 0) begin
                            apply_backpressure = 1'b1;
                            backpressure_cycles = ($urandom % 3) + 1;
                            s_axis_tvalid = 1'b0;
                            $display("  Backpressure: pausing for %0d cycles", backpressure_cycles);
                            repeat (backpressure_cycles) @(posedge clk);
                            apply_backpressure = 1'b0;
                        end

                        if (!apply_backpressure) begin
                            // Prepare and send beat
                            beat = {AXIS_DATA_WIDTH{1'b0}};
                            for (j = 0; j < VALUES_PER_BEAT; j = j + 1) begin
                                val32 = idx * VALUES_PER_BEAT + j + 100;  // Different pattern
                                beat[j*DATA_WIDTH+:DATA_WIDTH] = val32[DATA_WIDTH-1:0];
                            end
                            s_axis_tdata  = beat;
                            s_axis_tlast  = (idx == NUM_INPUT_BEATS - 1);
                            s_axis_tvalid = 1'b1;

                            @(posedge clk);
                            if (s_axis_tready) begin
                                handshakes = handshakes + 1;
                                $display("  Handshake #%0d (beat %0d) TLAST=%0b", handshakes, idx,
                                         s_axis_tlast);
                                idx = idx + 1;
                            end else begin
                                // If not ready, keep data asserted
                                s_axis_tvalid = 1'b1;
                            end
                        end
                    end

                    s_axis_tvalid = 1'b0;
                    s_axis_tlast  = 1'b0;
                end

                begin : backpressure_monitor
                    wait (rst_n == 1'b1);
                    @(posedge clk);

                    while (out_row < NUM_INPUT_BEATS) begin
                        @(posedge clk);
                        if (data_valid) begin
                            $display("  Consumed beat %0d", out_row);
                            // Check against backpressure test data
                            if (data_out_0 !== sent_data_backpressure[out_row*ARRAY_SIZE+0])
                                errors = errors + 1;
                            if (data_out_1 !== sent_data_backpressure[out_row*ARRAY_SIZE+1])
                                errors = errors + 1;
                            if (data_out_2 !== sent_data_backpressure[out_row*ARRAY_SIZE+2])
                                errors = errors + 1;
                            if (data_out_3 !== sent_data_backpressure[out_row*ARRAY_SIZE+3])
                                errors = errors + 1;
                            if (data_out_4 !== sent_data_backpressure[out_row*ARRAY_SIZE+4])
                                errors = errors + 1;
                            if (data_out_5 !== sent_data_backpressure[out_row*ARRAY_SIZE+5])
                                errors = errors + 1;
                            if (data_out_6 !== sent_data_backpressure[out_row*ARRAY_SIZE+6])
                                errors = errors + 1;
                            if (data_out_7 !== sent_data_backpressure[out_row*ARRAY_SIZE+7])
                                errors = errors + 1;
                            out_row = out_row + 1;
                        end
                    end
                end
            join

            if (errors == 0)
                $display("PASS: Backpressure test - All %0d beats matched", NUM_INPUT_BEATS);
            else $display("FAIL: Backpressure test - %0d mismatches", errors);

            total_errors = total_errors + errors;
            test_backpressure = 1'b0;
            repeat (10) @(posedge clk);
        end
    endtask

    // Test 3: Intermittent streaming (start/stop)
    task run_intermittent_test;
        integer pause_cycles;
        begin
            pause_cycles = ($urandom % 3) + 1;
            current_test = 3;
            test_intermittent = 1'b1;
            errors = 0;
            out_row = 0;
            idx = 0;
            handshakes = 0;
            cycles = 0;

            $display("\n=== Test 3: Intermittent Streaming ===");
            $display("Sending %0d beats with start/stop pattern", NUM_INPUT_BEATS);

            fork
                begin : intermittent_driver
                    wait (rst_n == 1'b1);
                    @(posedge clk);
                    wait (s_axis_tready);
                    @(posedge clk);

                    while (idx < NUM_INPUT_BEATS) begin : intermittent_send
                        // Send 2-4 beats then pause
                        integer beats_to_send;
                        beats_to_send = ($urandom % 3) + 2;  // 2-4 beats

                        // Send burst
                        for (k = 0; k < beats_to_send && idx < NUM_INPUT_BEATS; k = k + 1) begin
                            beat = {AXIS_DATA_WIDTH{1'b0}};
                            for (j = 0; j < VALUES_PER_BEAT; j = j + 1) begin
                                val32 = idx * VALUES_PER_BEAT + j + 200;  // Different pattern
                                beat[j*DATA_WIDTH+:DATA_WIDTH] = val32[DATA_WIDTH-1:0];
                            end
                            s_axis_tdata  = beat;
                            s_axis_tlast  = (idx == NUM_INPUT_BEATS - 1);
                            s_axis_tvalid = 1'b1;

                            @(posedge clk);
                            if (s_axis_tready) begin
                                handshakes = handshakes + 1;
                                $display("  Handshake #%0d (beat %0d) TLAST=%0b", handshakes, idx,
                                         s_axis_tlast);
                                idx = idx + 1;
                            end else begin
                                // Retry if not ready
                                k = k - 1;
                            end
                        end

                        // Pause for 1-3 cycles between bursts
                        if (idx < NUM_INPUT_BEATS) begin : cycle_burst
                            s_axis_tvalid = 1'b0;
                            $display("  Pausing for %0d cycles", pause_cycles);
                            repeat (pause_cycles) @(posedge clk);
                        end
                    end

                    s_axis_tvalid = 1'b0;
                    s_axis_tlast  = 1'b0;
                end

                begin : intermittent_monitor
                    wait (rst_n == 1'b1);
                    @(posedge clk);

                    while (out_row < NUM_INPUT_BEATS) begin
                        @(posedge clk);
                        if (data_valid) begin
                            $display("  Consumed beat %0d", out_row);
                            // Check against intermittent test data
                            if (data_out_0 !== sent_data_intermittent[out_row*ARRAY_SIZE+0])
                                errors = errors + 1;
                            if (data_out_1 !== sent_data_intermittent[out_row*ARRAY_SIZE+1])
                                errors = errors + 1;
                            if (data_out_2 !== sent_data_intermittent[out_row*ARRAY_SIZE+2])
                                errors = errors + 1;
                            if (data_out_3 !== sent_data_intermittent[out_row*ARRAY_SIZE+3])
                                errors = errors + 1;
                            if (data_out_4 !== sent_data_intermittent[out_row*ARRAY_SIZE+4])
                                errors = errors + 1;
                            if (data_out_5 !== sent_data_intermittent[out_row*ARRAY_SIZE+5])
                                errors = errors + 1;
                            if (data_out_6 !== sent_data_intermittent[out_row*ARRAY_SIZE+6])
                                errors = errors + 1;
                            if (data_out_7 !== sent_data_intermittent[out_row*ARRAY_SIZE+7])
                                errors = errors + 1;
                            out_row = out_row + 1;
                        end
                    end
                end
            join

            if (errors == 0)
                $display("PASS: Intermittent test - All %0d beats matched", NUM_INPUT_BEATS);
            else $display("FAIL: Intermittent test - %0d mismatches", errors);

            total_errors = total_errors + errors;
            test_intermittent = 1'b0;
            repeat (10) @(posedge clk);
        end
    endtask

    // Test 4: Reset during operation
    task run_reset_test;
        begin
            current_test = 4;
            test_reset = 1'b1;
            errors = 0;
            out_row = 0;
            idx = 0;
            handshakes = 0;
            cycles = 0;

            $display("\n=== Test 4: Reset During Operation ===");
            $display("Testing reset behavior during streaming");

            fork
                begin : reset_driver
                    wait (rst_n == 1'b1);
                    @(posedge clk);
                    wait (s_axis_tready);
                    @(posedge clk);

                    // Send a few beats
                    while (idx < 3) begin
                        beat = {AXIS_DATA_WIDTH{1'b0}};
                        for (j = 0; j < VALUES_PER_BEAT; j = j + 1) begin
                            val32 = idx * VALUES_PER_BEAT + j;
                            beat[j*DATA_WIDTH+:DATA_WIDTH] = val32[DATA_WIDTH-1:0];
                        end
                        s_axis_tdata  = beat;
                        s_axis_tlast  = 1'b0;
                        s_axis_tvalid = 1'b1;

                        @(posedge clk);
                        if (s_axis_tready) begin
                            handshakes = handshakes + 1;
                            $display("  Handshake #%0d (beat %0d) before reset", handshakes, idx);
                            idx = idx + 1;
                        end
                    end

                    // Apply reset during operation
                    $display("  Applying reset during operation...");
                    rst_n = 1'b0;
                    s_axis_tvalid = 1'b0;  // Stop driving during reset
                    repeat (3) @(posedge clk);
                    rst_n = 1'b1;
                    $display("  Reset released");

                    // Wait for recovery and re-sync
                    repeat (2) @(posedge clk);
                    wait (s_axis_tready);
                    @(posedge clk);

                    // Continue streaming from beat 3 (data after reset)
                    while (idx < NUM_INPUT_BEATS) begin
                        beat = {AXIS_DATA_WIDTH{1'b0}};
                        for (j = 0; j < VALUES_PER_BEAT; j = j + 1) begin
                            val32 = idx * VALUES_PER_BEAT + j;
                            beat[j*DATA_WIDTH+:DATA_WIDTH] = val32[DATA_WIDTH-1:0];
                        end
                        s_axis_tdata  = beat;
                        s_axis_tlast  = (idx == NUM_INPUT_BEATS - 1);
                        s_axis_tvalid = 1'b1;

                        @(posedge clk);
                        if (s_axis_tready) begin
                            handshakes = handshakes + 1;
                            $display("  Handshake #%0d (beat %0d) after reset", handshakes, idx);
                            idx = idx + 1;
                        end
                    end

                    s_axis_tvalid = 1'b0;
                    s_axis_tlast  = 1'b0;
                end

                begin : reset_monitor
                    integer beats_after_reset;
                    reg monitoring_after_reset;
                    integer global_index;

                    beats_after_reset = 0;
                    monitoring_after_reset = 1'b0;

                    wait (rst_n == 1'b1);
                    @(posedge clk);

                    // Only start counting AFTER reset is applied and released
                    while (beats_after_reset < 5) begin
                        @(posedge clk);
                        if (data_valid && monitoring_after_reset) begin
                            $display("  Consumed beat %0d after reset (global index %0d)",
                                     beats_after_reset, beats_after_reset + 3);

                            global_index = beats_after_reset + 3;
                            if (data_out_0 !== sent_data_continuous[global_index*ARRAY_SIZE+0]) begin
                                errors = errors + 1;
                                $display(
                                    "ERROR: data_out_0: expected %0d, got %0d at global index %0d",
                                    sent_data_continuous[global_index*ARRAY_SIZE+0], data_out_0,
                                    global_index);
                            end
                            if (data_out_1 !== sent_data_continuous[global_index*ARRAY_SIZE+1]) begin
                                errors = errors + 1;
                                $display(
                                    "ERROR: data_out_1: expected %0d, got %0d at global index %0d",
                                    sent_data_continuous[global_index*ARRAY_SIZE+1], data_out_1,
                                    global_index);
                            end
                            if (data_out_2 !== sent_data_continuous[global_index*ARRAY_SIZE+2]) begin
                                errors = errors + 1;
                                $display(
                                    "ERROR: data_out_2: expected %0d, got %0d at global index %0d",
                                    sent_data_continuous[global_index*ARRAY_SIZE+2], data_out_2,
                                    global_index);
                            end
                            if (data_out_3 !== sent_data_continuous[global_index*ARRAY_SIZE+3]) begin
                                errors = errors + 1;
                                $display(
                                    "ERROR: data_out_3: expected %0d, got %0d at global index %0d",
                                    sent_data_continuous[global_index*ARRAY_SIZE+3], data_out_3,
                                    global_index);
                            end
                            if (data_out_4 !== sent_data_continuous[global_index*ARRAY_SIZE+4]) begin
                                errors = errors + 1;
                                $display(
                                    "ERROR: data_out_4: expected %0d, got %0d at global index %0d",
                                    sent_data_continuous[global_index*ARRAY_SIZE+4], data_out_4,
                                    global_index);
                            end
                            if (data_out_5 !== sent_data_continuous[global_index*ARRAY_SIZE+5]) begin
                                errors = errors + 1;
                                $display(
                                    "ERROR: data_out_5: expected %0d, got %0d at global index %0d",
                                    sent_data_continuous[global_index*ARRAY_SIZE+5], data_out_5,
                                    global_index);
                            end
                            if (data_out_6 !== sent_data_continuous[global_index*ARRAY_SIZE+6]) begin
                                errors = errors + 1;
                                $display(
                                    "ERROR: data_out_6: expected %0d, got %0d at global index %0d",
                                    sent_data_continuous[global_index*ARRAY_SIZE+6], data_out_6,
                                    global_index);
                            end
                            if (data_out_7 !== sent_data_continuous[global_index*ARRAY_SIZE+7]) begin
                                errors = errors + 1;
                                $display(
                                    "ERROR: data_out_7: expected %0d, got %0d at global index %0d",
                                    sent_data_continuous[global_index*ARRAY_SIZE+7], data_out_7,
                                    global_index);
                            end
                            beats_after_reset = beats_after_reset + 1;
                        end

                        if (!monitoring_after_reset) begin
                            @(negedge rst_n);
                            @(posedge rst_n);
                            repeat (2) @(posedge clk);
                            monitoring_after_reset = 1'b1;
                            $display("  Started monitoring after reset recovery");
                        end
                    end
                end
            join

            if (errors == 0)
                $display(
                    "PASS: Reset test - System recovered correctly, 5 beats matched after reset"
                );
            else $display("FAIL: Reset test - %0d mismatches after reset", errors);

            total_errors = total_errors + errors;
            test_reset   = 1'b0;
        end
    endtask

endmodule
