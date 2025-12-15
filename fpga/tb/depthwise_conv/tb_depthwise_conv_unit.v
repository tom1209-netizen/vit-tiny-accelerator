`timescale 1ns / 1ps

module tb_depthwise_conv_unit;
    // Parameters (match DUT)
    parameter DATA_WIDTH = 8;
    parameter LANES = 8;
    parameter INPUT_WIDTH = 64;
    parameter OUTPUT_WIDTH = 256;
    parameter MAX_WIDTH = 64;
    parameter MAX_CHANNELS = 128;
    parameter ACC_WIDTH = 32;

    // Set USE_MODULAR=1 to test the modular version
    parameter USE_MODULAR = 0;

    // Clock and reset
    reg                           clk;
    reg                           rst_n;

    // Control signals
    reg                           start;
    wire                          done;
    reg        [            15:0] cfg_height;
    reg        [            15:0] cfg_width;
    reg        [            15:0] cfg_channels;

    // Kernel input interface
    reg        [ INPUT_WIDTH-1:0] axis_kernel_in_tdata;
    reg                           axis_kernel_in_tvalid;
    wire                          axis_kernel_in_tready;

    // Data input interface
    reg        [ INPUT_WIDTH-1:0] axis_data_in_tdata;
    reg                           axis_data_in_tvalid;
    reg                           axis_data_in_tlast;
    wire                          axis_data_in_tready;

    // Data output interface
    wire       [OUTPUT_WIDTH-1:0] axis_data_out_tdata;
    wire                          axis_data_out_tvalid;
    wire                          axis_data_out_tlast;
    reg                           axis_data_out_tready;

    // Testbench storage
    reg signed [             7:0] input_image           [0:MAX_WIDTH*MAX_WIDTH*MAX_CHANNELS-1];
    reg signed [             7:0] kernel_mem            [                  0:MAX_CHANNELS*9-1];
    reg signed [            31:0] expected_out          [0:MAX_WIDTH*MAX_WIDTH*MAX_CHANNELS-1];
    reg signed [            31:0] actual_out            [0:MAX_WIDTH*MAX_WIDTH*MAX_CHANNELS-1];

    // Test control
    integer                       test_num;
    integer                       errors;
    integer                       total_tests;
    integer i, j, c, ki, kj;
    integer in_beat_cnt, out_beat_cnt;
    integer kernel_beat_cnt;

    // DUT instantiation
    depthwise_conv_unit #(
        .DATA_WIDTH(DATA_WIDTH),
        .LANES(LANES),
        .INPUT_WIDTH(INPUT_WIDTH),
        .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .MAX_WIDTH(MAX_WIDTH),
        .MAX_CHANNELS(MAX_CHANNELS),
        .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .done(done),
        .cfg_height(cfg_height),
        .cfg_width(cfg_width),
        .cfg_channels(cfg_channels),
        .axis_kernel_in_tdata(axis_kernel_in_tdata),
        .axis_kernel_in_tvalid(axis_kernel_in_tvalid),
        .axis_kernel_in_tready(axis_kernel_in_tready),
        .axis_data_in_tdata(axis_data_in_tdata),
        .axis_data_in_tvalid(axis_data_in_tvalid),
        .axis_data_in_tlast(axis_data_in_tlast),
        .axis_data_in_tready(axis_data_in_tready),
        .axis_data_out_tdata(axis_data_out_tdata),
        .axis_data_out_tvalid(axis_data_out_tvalid),
        .axis_data_out_tlast(axis_data_out_tlast),
        .axis_data_out_tready(axis_data_out_tready)
    );

    // Clock generation
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // Task
    task reset_dut;
        begin
            rst_n = 0;
            start = 0;
            cfg_height = 0;
            cfg_width = 0;
            cfg_channels = 0;
            axis_kernel_in_tdata = 0;
            axis_kernel_in_tvalid = 0;
            axis_data_in_tdata = 0;
            axis_data_in_tvalid = 0;
            axis_data_in_tlast = 0;
            axis_data_out_tready = 0;
            repeat (10) @(posedge clk);
            rst_n = 1;
            repeat (5) @(posedge clk);
        end
    endtask

    task generate_identity_kernel;
        input integer num_channels;
        integer ch, pos;
        begin
            // Identity kernel: only center (position 4) is 1
            for (ch = 0; ch < num_channels; ch = ch + 1) begin
                for (pos = 0; pos < 9; pos = pos + 1) begin
                    if (pos == 4) kernel_mem[ch*9+pos] = 8'sd1;
                    else kernel_mem[ch*9+pos] = 8'sd0;
                end
            end
        end
    endtask

    task generate_random_kernel;
        input integer num_channels;
        integer ch, pos;
        begin
            for (ch = 0; ch < num_channels; ch = ch + 1) begin
                for (pos = 0; pos < 9; pos = pos + 1) begin
                    kernel_mem[ch*9+pos] = $random % 16;  // -16 to 15
                end
            end
        end
    endtask

    task generate_gradient_input;
        input integer height;
        input integer width;
        input integer channels;
        integer row, col, ch;
        begin
            for (row = 0; row < height; row = row + 1) begin
                for (col = 0; col < width; col = col + 1) begin
                    for (ch = 0; ch < channels; ch = ch + 1) begin
                        input_image[(row*width + col)*channels + ch] = 
                            (col * 128 / width - 64);  // -64 to +63 gradient
                    end
                end
            end
        end
    endtask

    task generate_random_input;
        input integer height;
        input integer width;
        input integer channels;
        integer idx;
        begin
            for (idx = 0; idx < height * width * channels; idx = idx + 1) begin
                input_image[idx] = $random % 256 - 128;
            end
        end
    endtask

    // Print input matrix for channel 0 (2D view)
    task print_input_ch0;
        input integer height;
        input integer width;
        input integer channels;
        integer row, col;
        begin
            $display("\n  Input Image [ch0]:");
            for (row = 0; row < height; row = row + 1) begin
                $write("    [ ");
                for (col = 0; col < width; col = col + 1) begin
                    $write("%4d ", input_image[(row*width+col)*channels]);
                end
                $display("]");
            end
        end
    endtask

    // Print kernel for channel 0 (3x3 format)
    task print_kernel_ch0;
        integer kr, kc;
        begin
            $display("\n  Kernel [ch0] (3x3):");
            for (kr = 0; kr < 3; kr = kr + 1) begin
                $write("    [ ");
                for (kc = 0; kc < 3; kc = kc + 1) begin
                    $write("%4d ", kernel_mem[kr*3+kc]);
                end
                $display("]");
            end
        end
    endtask

    // Print expected output for channel 0
    task print_expected_ch0;
        input integer height;
        input integer width;
        input integer channels;
        integer row, col;
        begin
            $display("\n  Expected Output [ch0]:");
            for (row = 0; row < height; row = row + 1) begin
                $write("    [ ");
                for (col = 0; col < width; col = col + 1) begin
                    $write("%6d ", expected_out[(row*width+col)*channels]);
                end
                $display("]");
            end
        end
    endtask

    // Print actual output for channel 0
    task print_actual_ch0;
        input integer height;
        input integer width;
        input integer channels;
        integer row, col;
        begin
            $display("\n  Actual Output [ch0]:");
            for (row = 0; row < height; row = row + 1) begin
                $write("    [ ");
                for (col = 0; col < width; col = col + 1) begin
                    $write("%6d ", actual_out[(row*width+col)*channels]);
                end
                $display("]");
            end
        end
    endtask

    task compute_expected_output;
        input integer height;
        input integer width;
        input integer channels;
        integer row, col, ch, kr, kc;
        integer in_row, in_col;
        integer sum;
        reg signed [7:0] pixel_val;
        reg signed [7:0] kern_val;
        begin
            for (row = 0; row < height; row = row + 1) begin
                for (col = 0; col < width; col = col + 1) begin
                    for (ch = 0; ch < channels; ch = ch + 1) begin
                        sum = 0;
                        // 3x3 convolution
                        for (kr = 0; kr < 3; kr = kr + 1) begin
                            for (kc = 0; kc < 3; kc = kc + 1) begin
                                in_row = row + kr - 1;
                                in_col = col + kc - 1;

                                // Zero padding for borders
                                if (in_row < 0 || in_row >= height || 
                                    in_col < 0 || in_col >= width) begin
                                    pixel_val = 0;
                                end else begin
                                    pixel_val = input_image[(in_row*width+in_col)*channels+ch];
                                end

                                // Kernel indexed same way as load_kernels: (ch_group*LANES + lane)*9 + coeff
                                // where ch = ch_group * LANES + lane
                                kern_val = kernel_mem[ch*9+kr*3+kc];
                                sum = sum + (pixel_val * kern_val);
                            end
                        end
                        expected_out[(row*width+col)*channels+ch] = sum;
                    end
                end
            end
        end
    endtask

    task load_kernels;
        input integer num_channels;
        integer ch_group, coeff, lane;
        reg [INPUT_WIDTH-1:0] beat_data;
        begin
            kernel_beat_cnt = 0;

            // Load kernel weights: (C/8) groups × 9 coefficients
            for (ch_group = 0; ch_group < num_channels / LANES; ch_group = ch_group + 1) begin
                for (coeff = 0; coeff < 9; coeff = coeff + 1) begin
                    // Pack 8 channels for this coefficient
                    beat_data = 0;
                    for (lane = 0; lane < LANES; lane = lane + 1) begin
                        beat_data[lane*DATA_WIDTH +: DATA_WIDTH] = 
                            kernel_mem[(ch_group*LANES + lane)*9 + coeff];
                    end

                    axis_kernel_in_tdata  = beat_data;
                    axis_kernel_in_tvalid = 1;

                    @(posedge clk);
                    while (!axis_kernel_in_tready) @(posedge clk);

                    kernel_beat_cnt = kernel_beat_cnt + 1;
                end
            end

            axis_kernel_in_tvalid = 0;
            $display("  Loaded %0d kernel beats", kernel_beat_cnt);
        end
    endtask

    task drive_input_stream;
        input integer height;
        input integer width;
        input integer channels;
        integer row, col, ch_beat, lane;
        integer total_beats;
        reg [INPUT_WIDTH-1:0] beat_data;
        begin
            in_beat_cnt = 0;
            total_beats = height * width * (channels / LANES);

            for (row = 0; row < height; row = row + 1) begin
                for (col = 0; col < width; col = col + 1) begin
                    for (ch_beat = 0; ch_beat < channels / LANES; ch_beat = ch_beat + 1) begin
                        // Pack 8 channels
                        beat_data = 0;
                        for (lane = 0; lane < LANES; lane = lane + 1) begin
                            beat_data[lane*DATA_WIDTH +: DATA_WIDTH] = 
                                input_image[(row*width + col)*channels + ch_beat*LANES + lane];
                        end

                        axis_data_in_tdata  = beat_data;
                        axis_data_in_tvalid = 1;
                        axis_data_in_tlast  = (in_beat_cnt == total_beats - 1);

                        @(posedge clk);
                        while (!axis_data_in_tready) @(posedge clk);

                        in_beat_cnt = in_beat_cnt + 1;
                    end
                end
            end

            axis_data_in_tvalid = 0;
            axis_data_in_tlast  = 0;
            $display("  Sent %0d input beats", in_beat_cnt);
        end
    endtask

    task monitor_output_stream;
        input integer height;
        input integer width;
        input integer channels;
        integer row, col, ch_beat, lane;
        integer total_beats;
        integer idx;
        begin
            out_beat_cnt = 0;
            total_beats = height * width * (channels / LANES);
            axis_data_out_tready = 1;

            while (out_beat_cnt < total_beats) begin
                @(posedge clk);
                if (axis_data_out_tvalid && axis_data_out_tready) begin
                    // Unpack INT32 values
                    for (lane = 0; lane < LANES; lane = lane + 1) begin
                        idx = out_beat_cnt * LANES + lane;
                        actual_out[idx] = $signed(axis_data_out_tdata[lane*ACC_WIDTH+:ACC_WIDTH]);
                    end
                    out_beat_cnt = out_beat_cnt + 1;
                end
            end

            axis_data_out_tready = 0;
            $display("  Received %0d output beats", out_beat_cnt);
        end
    endtask

    task compare_results;
        input integer height;
        input integer width;
        input integer channels;
        integer idx, total_elements;
        integer local_errors;
        begin
            total_elements = height * width * channels;
            local_errors   = 0;

            for (idx = 0; idx < total_elements; idx = idx + 1) begin
                if (expected_out[idx] !== actual_out[idx]) begin
                    if (local_errors < 10) begin
                        $display("  ERROR at idx %0d: expected %0d, got %0d", idx,
                                 expected_out[idx], actual_out[idx]);
                    end
                    local_errors = local_errors + 1;
                end
            end

            if (local_errors == 0) begin
                $display("  PASSED: All %0d elements match", total_elements);
            end else begin
                $display("  FAILED: %0d/%0d mismatches", local_errors, total_elements);
            end

            errors = errors + local_errors;
        end
    endtask

    task run_test;
        input integer test_id;
        input integer height;
        input integer width;
        input integer channels;
        input integer kernel_type;  // 0=identity, 1=random
        input integer input_type;  // 0=gradient, 1=random
        begin
            $display("\n========================================");
            $display("TEST %0d: %0dx%0dx%0d", test_id, height, width, channels);
            $display("========================================");

            // Generate test vectors
            if (kernel_type == 0) begin
                generate_identity_kernel(channels);
                $display("  Kernel type: Identity (center=1, others=0)");
            end else begin
                generate_random_kernel(channels);
                $display("  Kernel type: Random INT8 values");
            end

            if (input_type == 0) begin
                generate_gradient_input(height, width, channels);
                $display("  Input type: Horizontal gradient (-64 to +63)");
            end else begin
                generate_random_input(height, width, channels);
                $display("  Input type: Random INT8 values");
            end

            // Print full matrices for channel 0
            print_kernel_ch0;
            print_input_ch0(height, width, channels);

            // Compute expected output
            compute_expected_output(height, width, channels);

            // Print expected output
            print_expected_ch0(height, width, channels);

            // Configure DUT
            cfg_height = height;
            cfg_width = width;
            cfg_channels = channels;

            // Start DUT
            @(posedge clk);
            start = 1;
            @(posedge clk);
            start = 0;

            // Load kernels
            load_kernels(channels);

            // Drive input and monitor output in parallel
            fork
                drive_input_stream(height, width, channels);
                monitor_output_stream(height, width, channels);
            join

            // Wait for done
            while (!done) @(posedge clk);

            // Print actual output
            print_actual_ch0(height, width, channels);

            // Compare results
            compare_results(height, width, channels);

            total_tests = total_tests + 1;
            repeat (10) @(posedge clk);
        end
    endtask

    // Main test sequence
    initial begin
        $display("\n==============================================");
        $display("Depthwise Conv Unit Testbench");
        $display("==============================================\n");

        errors = 0;
        total_tests = 0;

        reset_dut();

        // Test 1: Small image with identity kernel
        run_test(1, 4, 4, 8, 0, 0);

        // Test 2: Larger image with identity kernel
        run_test(2, 8, 8, 8, 0, 1);

        // Test 3: Random kernel with gradient input
        run_test(3, 4, 4, 8, 1, 0);

        // Test 4: Random kernel with random input
        run_test(4, 8, 8, 16, 1, 1);

        // Test 5: Larger channels
        run_test(5, 4, 4, 32, 1, 1);

        // Test 6: TinyViT-like dimensions (smaller for simulation)
        run_test(6, 7, 7, 64, 1, 1);

        // Summary
        $display("\n==============================================");
        $display("SUMMARY: %0d/%0d tests passed", total_tests - (errors > 0 ? 1 : 0), total_tests);
        if (errors == 0) $display("ALL TESTS PASSED!");
        else $display("FAILED with %0d total errors", errors);
        $display("==============================================\n");

        $finish;
    end

    // Timeout watchdog
    initial begin
        #1000000;  // 1ms timeout
        $display("ERROR: Simulation timeout!");
        $finish;
    end

endmodule
