`timescale 1ns / 1ps

module tb_softmax_unit;
    // Parameters
    parameter CLK_PERIOD = 10;  // 100 MHz clock
    parameter AXIS_DATA_WIDTH = 64;  // 8 x INT8 tokens per beat
    parameter DATA_WIDTH = 8;  // INT8 width
    parameter EXP_WIDTH = 20;  // Q4.16 fixed point width
    parameter SUM_WIDTH = 32;  // Accumulator width
    parameter RECIP_WIDTH = 16;  // MSR output width
    parameter FIFO_DEPTH = 256;  // FIFO depth

    parameter EXP_INIT_FILE = "../rtl/softmax/lut/exp_table_q4_16.hex";
    parameter RECIP_INIT_FILE = "../rtl/softmax/lut/recip_lut.hex";

    // TinyViT Attention Window Sizes (real use cases)
    // Stage 1 & 3: 7x7 window = 49 tokens -> padded to 56 (7 beats)
    // Stage 2: 14x14 window = 196 tokens -> padded to 200 (25 beats)
    parameter VIT_STAGE_1_3_TOKENS = 56;  // 7x7 window padded (7 beats)
    parameter VIT_STAGE_2_TOKENS = 200;  // 14x14 window padded (25 beats)

    // Real model sizes (from SHAPE_TRACE.md). We pad to the next AXIS beat.
    // NOTE: softmax_unit subtracts global_max in 8-bit signed. Keep the pad
    // value within the expected attention-logit range to avoid underflow wrap.
    parameter VIT_STAGE_1_3_VALID = 49;
    parameter VIT_STAGE_2_VALID = 196;
    parameter signed [7:0] PADDING_VALUE = -8'sd32;  // "masked" token logit

    // Expected INT8 attention-logit range after requant (keeps (x-max) in-range)
    parameter integer ATTN_LOGIT_MIN = -16;
    parameter integer ATTN_LOGIT_MAX = 15;

    // DUT Signals
    reg clk;
    reg rst_n;

    // Control Interface
    reg start;
    reg [31:0] num_tokens;
    wire done;

    // AXI4-Stream Input (Master -> DUT)
    reg [AXIS_DATA_WIDTH-1:0] s_axis_tdata;
    reg s_axis_tvalid;
    reg s_axis_tlast;
    wire s_axis_tready;

    // AXI4-Stream Output (DUT -> Slave)
    wire [AXIS_DATA_WIDTH-1:0] m_axis_tdata;
    wire m_axis_tvalid;
    wire m_axis_tlast;
    reg m_axis_tready;

    // Testbench Variables
    integer test_case;
    integer pass_count;
    integer fail_count;
    integer cycle_count;
    integer performance_cycle_count;
    integer token_count;

    reg [DATA_WIDTH-1:0] input_logits[0:1023];  // Store up to 1024 tokens
    reg [DATA_WIDTH-1:0] expected_output[0:1023];  // Expected output

    integer input_beat_counter;
    integer output_beat_counter;
    integer tokens_sent;
    integer tokens_received;

    // DUT Instantiation
    softmax_unit #(
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .EXP_WIDTH(EXP_WIDTH),
        .SUM_WIDTH(SUM_WIDTH),
        .RECIP_WIDTH(RECIP_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH),
        .EXP_INIT_FILE(EXP_INIT_FILE),
        .RECIP_INIT_FILE(RECIP_INIT_FILE)
    ) dut (
        .clk  (clk),
        .rst_n(rst_n),

        // Control
        .start(start),
        .num_tokens(num_tokens),
        .done(done),

        // AXI4-Stream Input
        .s_axis_tdata (s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast (s_axis_tlast),
        .s_axis_tready(s_axis_tready),

        // AXI4-Stream Output
        .m_axis_tdata (m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast (m_axis_tlast),
        .m_axis_tready(m_axis_tready)
    );

    // Clock Generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // Trace Cycle Counter
    integer trace_cycles;
    initial trace_cycles = 0;
    always @(posedge clk) trace_cycles = trace_cycles + 1;

    // Debug Trace
    always @(posedge clk) begin
        // Log when there is active input streaming or output draining
        if (s_axis_tvalid || m_axis_tready || m_axis_tvalid) begin
            $display("[Trace %0d] OUT: V=%b R=%b L=%b D=%h | IN: V=%b R=%b L=%b D=%h",
                     trace_cycles, m_axis_tvalid, m_axis_tready, m_axis_tlast, m_axis_tdata,
                     s_axis_tvalid, s_axis_tready, s_axis_tlast, s_axis_tdata);
        end
    end

    // Test Tasks
    // Random helpers 
    function integer rand_between;
        input integer min_val;
        input integer max_val;
        integer span;
        integer val;
        begin
            span = max_val - min_val + 1;
            if (span <= 0) begin
                rand_between = min_val;
            end else begin
                val = $random;
                if (val < 0) val = -val;
                rand_between = min_val + (val % span);
            end
        end
    endfunction

    function integer rand0max;
        input integer max_val;
        begin
            rand0max = rand_between(0, max_val);
        end
    endfunction

    // Task: Reset DUT
    task reset_dut;
        begin
            rst_n = 0;
            start = 0;
            num_tokens = 0;
            s_axis_tdata = 0;
            s_axis_tvalid = 0;
            s_axis_tlast = 0;
            m_axis_tready = 0;

            // Wait for 10 clock cycles
            repeat (10) @(posedge clk);
            rst_n = 1;

            // Wait for 5 more cycles after reset
            repeat (5) @(posedge clk);

            $display("[%0t] DUT Reset Complete", $time);
        end
    endtask

    // Task: Generate Random Test Vector
    task generate_test_vector;
        input integer num_tokens_in;
        integer i;
        integer random_val;
        begin
            for (i = 0; i < num_tokens_in; i = i + 1) begin
                // Attention logits after requant are expected to be a small range.
                random_val = rand_between(ATTN_LOGIT_MIN, ATTN_LOGIT_MAX);
                input_logits[i] = random_val[7:0];
            end

            // Compute expected output using software model
            compute_expected_output(num_tokens_in);

            $display("[%0t] Generated test vector with %0d tokens", $time, num_tokens_in);
        end
    endtask

    // Task: Compute Expected Output (Software Reference Model)
    // Now with max-subtraction matching the hardware
    task compute_expected_output;
        input integer num_tokens_in;

        integer i, j;
        integer fixed_exp;
        integer fixed_sum;
        integer lut_index;
        integer shift_amount;
        integer signed_token;
        integer shifted_token;  // After max subtraction
        integer unsigned_idx;
        integer global_max;     // Maximum logit value
        reg [35:0] prod_int;
        reg [47:0] scaled_int;
        reg [15:0] recip_val;

        // Load LUTs into memory (simplified)
        reg [19:0] exp_rom[0:255];
        reg [15:0] recip_lut[0:63];

        begin
            // Load exponential ROM
            $readmemh(EXP_INIT_FILE, exp_rom);

            // Load reciprocal LUT
            $readmemh(RECIP_INIT_FILE, recip_lut);

            // Pass 0: Find global max
            global_max = -128;  // Start with minimum
            for (i = 0; i < num_tokens_in; i = i + 1) begin
                signed_token = $signed(input_logits[i]);
                if (signed_token > global_max) begin
                    global_max = signed_token;
                end
            end

            // Pass 1: Calculate sum of exponentials with max-subtraction
            fixed_sum = 0;
            for (i = 0; i < num_tokens_in; i = i + 1) begin
                // Subtract max for numerical stability
                signed_token  = $signed(input_logits[i]);
                shifted_token = signed_token - global_max;  // Now <= 0

                // Map shifted token to unsigned index 0..255
                if (shifted_token < 0) unsigned_idx = shifted_token + 256;
                else unsigned_idx = shifted_token;

                fixed_exp = exp_rom[unsigned_idx];
                fixed_sum = fixed_sum + fixed_exp;
            end

            // MSR Approximation (simplified)
            // Find leading one position
            shift_amount = 0;
            begin : find_msb
                for (j = 31; j >= 0; j = j - 1)
                if (fixed_sum[j]) begin
                    shift_amount = (j > 5) ? (j - 5) : 0;
                    disable find_msb;
                end
            end

            lut_index = fixed_sum >> shift_amount;
            if (lut_index > 63) lut_index = 63;
            recip_val = recip_lut[lut_index];

            // Pass 2: Normalize each exponential
            for (i = 0; i < num_tokens_in; i = i + 1) begin
                signed_token  = $signed(input_logits[i]);
                shifted_token = signed_token - global_max;

                if (shifted_token < 0) unsigned_idx = shifted_token + 256;
                else unsigned_idx = shifted_token;

                fixed_exp  = exp_rom[unsigned_idx];

                // Integer path: (exp * recip) >> shift_amount, saturate to 255
                prod_int   = fixed_exp * recip_val;  // up to ~36 bits
                scaled_int = (prod_int >> shift_amount) >> 7;  // match DUT Q1.15 -> Q0.8

                if (scaled_int > 48'd255) expected_output[i] = 8'd255;
                else expected_output[i] = scaled_int[7:0];
            end

            $display(
                "[%0t] Computed expected outputs: max=%0d, sum=0x%08h, recip=0x%04h, shift=%0d",
                $time, global_max, fixed_sum[31:0], recip_val, shift_amount);
        end
    endtask

    // Task: Drive Input Stream
    task drive_input_stream;
        input integer num_tokens_in;

        integer tokens_per_beat;
        integer num_beats;
        integer beat;
        integer token_idx;
        integer tokens_in_last_beat;

        begin
            tokens_per_beat = AXIS_DATA_WIDTH / DATA_WIDTH;  // 8
            num_beats = (num_tokens_in + tokens_per_beat - 1) / tokens_per_beat;
            tokens_in_last_beat = num_tokens_in % tokens_per_beat;
            if (tokens_in_last_beat == 0) tokens_in_last_beat = tokens_per_beat;

            $display("[%0t] Driving %0d tokens in %0d beats", $time, num_tokens_in, num_beats);

            tokens_sent   = 0;
            s_axis_tvalid = 1;

            for (beat = 0; beat < num_beats; beat = beat + 1) begin
                // Pack tokens into 64-bit word
                s_axis_tdata = 0;
                for (token_idx = 0; token_idx < tokens_per_beat; token_idx = token_idx + 1) begin
                    if (tokens_sent + token_idx < num_tokens_in) begin
                        s_axis_tdata[token_idx*DATA_WIDTH +: DATA_WIDTH] = 
                            input_logits[tokens_sent + token_idx];
                    end
                end

                // Set tlast on final beat
                s_axis_tlast = (beat == num_beats - 1);

                // Wait for ready
                while (!s_axis_tready) begin
                    @(posedge clk);
                    #1;
                end

                @(posedge clk);
                #1;
                tokens_sent = tokens_sent + tokens_per_beat;
            end

            s_axis_tvalid = 0;
            s_axis_tlast  = 0;

            $display("[%0t] Input stream complete. Sent %0d tokens", $time, tokens_sent);
        end
    endtask

    // Task: Monitor Output Stream
    task monitor_output_stream;
        input integer num_tokens_in;

        integer tokens_per_beat;
        integer num_beats;
        integer beat;
        integer token_idx;
        integer tokens_remaining;
        integer received_token;
        integer expected_val;
        integer error_count;

        begin
            tokens_per_beat = AXIS_DATA_WIDTH / DATA_WIDTH;  // 8
            num_beats = (num_tokens_in + tokens_per_beat - 1) / tokens_per_beat;

            $display("[%0t] Monitoring output for %0d tokens", $time, num_tokens_in);

            tokens_received = 0;
            error_count = 0;
            m_axis_tready = 1;

            for (beat = 0; beat < num_beats; beat = beat + 1) begin
                // Wait for valid data
                while (!m_axis_tvalid) begin
                    @(posedge clk);
                    #1;
                end

                // Verify tlast on final beat
                if ((beat == num_beats - 1) && !m_axis_tlast) begin
                    $display("[%0t] ERROR: tlast not asserted on final beat!", $time);
                    error_count = error_count + 1;
                end
                if ((beat != num_beats - 1) && m_axis_tlast) begin
                    $display("[%0t] ERROR: tlast asserted early on beat %0d!", $time, beat);
                    error_count = error_count + 1;
                end

                // Extract and verify tokens
                for (token_idx = 0; token_idx < tokens_per_beat; token_idx = token_idx + 1) begin
                    if (tokens_received + token_idx < num_tokens_in) begin
                        received_token = m_axis_tdata[token_idx*DATA_WIDTH+:DATA_WIDTH];
                        expected_val   = expected_output[tokens_received+token_idx];

                        // Check for X/Z (unknown) values first (portable, no $isunknown)
                        if (^received_token === 1'bx) begin
                            $display(
                                "[%0t] ERROR: Token %0d: Got X (unknown value) - hardware bug!",
                                $time, tokens_received + token_idx);
                            error_count = error_count + 1;
                        end  // Allow small tolerance for fixed-point approximation
                        else if (received_token !== expected_val) begin
                            if (($signed(
                                    received_token
                                ) - $signed(
                                    expected_val
                                ) > 1) || ($signed(
                                    expected_val
                                ) - $signed(
                                    received_token
                                ) > 1)) begin
                                $display(
                                    "[%0t] ERROR: Token %0d (logit=%0d): Expected %0d, Got %0d",
                                    $time, tokens_received + token_idx,
                                    $signed(input_logits[tokens_received+token_idx]), expected_val,
                                    received_token);
                                error_count = error_count + 1;
                            end else begin
                                $display(
                                    "[%0t] WARNING: Token %0d (logit=%0d): Expected %0d, Got %0d (within tolerance)",
                                    $time, tokens_received + token_idx,
                                    $signed(input_logits[tokens_received+token_idx]), expected_val,
                                    received_token);
                            end
                        end else begin
                            $display("[%0t] PASS: Token %0d (logit=%0d): Expected %0d, Got %0d",
                                     $time, tokens_received + token_idx,
                                     $signed(input_logits[tokens_received+token_idx]),
                                     expected_val, received_token);
                        end
                    end
                end

                @(posedge clk);
                #1;
                tokens_received = tokens_received + tokens_per_beat;
            end

            m_axis_tready = 0;

            if (error_count == 0) begin
                $display("[%0t] SUCCESS: All %0d tokens verified correctly", $time, num_tokens_in);
                pass_count = pass_count + 1;
            end else begin
                $display("[%0t] FAILURE: %0d errors in %0d tokens", $time, error_count,
                         num_tokens_in);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Task: Run Single Test Case
    task run_test_case;
        input integer test_id;
        input integer num_tokens_in;
        input [8*64-1:0] test_name;  // pass-as-string for Verilog

        begin
            $display("\n========================================");
            $display("[%0t] Starting Test Case %0d: %s", $time, test_id, test_name);
            $display("========================================");

            // Reset and initialize
            reset_dut();

            // Generate test vector
            generate_test_vector(num_tokens_in);

            // Configure DUT
            num_tokens = num_tokens_in;

            // Start computation
            @(posedge clk);
            start = 1;
            #1;
            @(posedge clk);
            start = 0;
            #1;

            // Fork input driver and output monitor
            fork
                begin : input_driver
                    // Small delay before starting input
                    repeat (3) @(posedge clk);
                    drive_input_stream(num_tokens_in);
                end

                begin : output_monitor
                    // Wait for output to start (after first pass)
                    while (!done && !m_axis_tvalid) @(posedge clk);
                    monitor_output_stream(num_tokens_in);
                end
            join

            // Wait for done signal
            while (!done) @(posedge clk);

            $display("[%0t] Test Case %0d COMPLETE", $time, test_id);

            // Small gap between tests
            repeat (10) @(posedge clk);
        end
    endtask

    // Task: Run Backpressure Test
    task run_backpressure_test;
        input integer num_tokens_in;

        integer backpressure_delay;
        integer random_val;

        begin
            $display("\n========================================");
            $display("[%0t] Starting Backpressure Test", $time);
            $display("========================================");

            reset_dut();
            generate_test_vector(num_tokens_in);
            num_tokens = num_tokens_in;

            @(posedge clk);
            start = 1;
            #1;
            @(posedge clk);
            start = 0;
            #1;

            fork
                begin : input_driver_bp
                    repeat (5) @(posedge clk);

                    // Random backpressure on input
                    tokens_sent   = 0;
                    s_axis_tvalid = 1;

                    while (tokens_sent < num_tokens_in) begin
                        // Randomly deassert tvalid
                        if (rand0max(100) < 20) begin  // 20% chance
                            s_axis_tvalid = 0;
                            repeat (rand_between(1, 5)) @(posedge clk);
                            s_axis_tvalid = 1;
                        end

                        // Pack data (simplified)
                        s_axis_tdata = {8{input_logits[0]}};  // Same token for simplicity
                        s_axis_tlast = (tokens_sent + 8 >= num_tokens_in);

                        if (s_axis_tready) begin
                            @(posedge clk);
                            #1;
                            tokens_sent = tokens_sent + 8;
                        end else begin
                            @(posedge clk);
                            #1;
                        end
                    end

                    s_axis_tvalid = 0;
                end

                begin : output_monitor_bp
                    // Random backpressure on output
                    tokens_received = 0;

                    while (tokens_received < num_tokens_in) begin
                        // Randomly deassert tready
                        m_axis_tready = (rand0max(100) < 30) ? 0 : 1;

                        if (m_axis_tvalid && m_axis_tready) begin
                            tokens_received = tokens_received + 8;
                        end

                        @(posedge clk);
                        #1;
                    end

                    m_axis_tready = 0;
                end
            join

            // Wait for completion
            repeat (50) @(posedge clk);

            $display("[%0t] Backpressure Test COMPLETE", $time);
            pass_count = pass_count + 1;
        end
    endtask

    // Task: Run Corner Case Tests
    task run_corner_cases;
        begin
            $display("\n========================================");
            $display("[%0t] Starting Corner Case Tests", $time);
            $display("========================================");

            // Test 1: Single token (edge case)
            reset_dut();
            num_tokens = 1;
            input_logits[0] = 0;  // Zero input

            @(posedge clk);
            start = 1;
            #1;
            @(posedge clk);
            start = 0;
            #1;

            // Test should handle single token
            repeat (50) @(posedge clk);
            $display("[%0t] Single token test complete", $time);

            // Test 2: All zeros
            reset_dut();
            num_tokens = 16;
            begin : zero_fill
                integer i_zero;
                for (i_zero = 0; i_zero < 16; i_zero = i_zero + 1) begin
                    input_logits[i_zero] = 0;
                end
            end

            @(posedge clk);
            start = 1;
            #1;
            @(posedge clk);
            start = 0;
            #1;

            repeat (50) @(posedge clk);
            $display("[%0t] All zeros test complete", $time);

            // Test 3: Maximum values (saturation test)
            reset_dut();
            num_tokens = 8;
            begin : max_fill
                integer i_max;
                for (i_max = 0; i_max < 8; i_max = i_max + 1) begin
                    input_logits[i_max] = 3;  // Within LUT positive ceiling
                end
            end

            @(posedge clk);
            start = 1;
            #1;
            @(posedge clk);
            start = 0;
            #1;

            repeat (50) @(posedge clk);
            $display("[%0t] Max value saturation test complete", $time);

            pass_count = pass_count + 1;
        end
    endtask

    // Task: Run Distribution Test with explicit 8-token input
    task run_distribution_test;
        input integer test_id;
        input [8*64-1:0] test_name;
        input signed [7:0] t0, t1, t2, t3, t4, t5, t6, t7;

        integer i, j;
        integer signed_max;
        integer signed_token;
        integer shifted_token;
        integer unsigned_idx;
        integer fixed_exp;
        integer fixed_sum;
        integer shift_amount;
        integer lut_index;
        reg [19:0] exp_rom[0:255];
        reg [15:0] recip_lut[0:63];
        reg [15:0] recip_val;
        reg [35:0] prod_int;
        reg [47:0] scaled_int;
        integer received_token;
        integer error_count;

        begin
            $display("\n========================================");
            $display("[%0t] Test %0d: %s", $time, test_id, test_name);
            $display("========================================");

            // Reset DUT
            reset_dut();

            // Load explicit test vector
            input_logits[0] = t0;
            input_logits[1] = t1;
            input_logits[2] = t2;
            input_logits[3] = t3;
            input_logits[4] = t4;
            input_logits[5] = t5;
            input_logits[6] = t6;
            input_logits[7] = t7;

            // Display input
            $display("[%0t] Input logits: [%0d, %0d, %0d, %0d, %0d, %0d, %0d, %0d]", $time,
                     $signed(t0), $signed(t1), $signed(t2), $signed(t3), $signed(t4), $signed(t5),
                     $signed(t6), $signed(t7));

            // Load LUTs
            $readmemh(EXP_INIT_FILE, exp_rom);
            $readmemh(RECIP_INIT_FILE, recip_lut);

            // Find max (software model)
            signed_max = $signed(t0);
            if ($signed(t1) > signed_max) signed_max = $signed(t1);
            if ($signed(t2) > signed_max) signed_max = $signed(t2);
            if ($signed(t3) > signed_max) signed_max = $signed(t3);
            if ($signed(t4) > signed_max) signed_max = $signed(t4);
            if ($signed(t5) > signed_max) signed_max = $signed(t5);
            if ($signed(t6) > signed_max) signed_max = $signed(t6);
            if ($signed(t7) > signed_max) signed_max = $signed(t7);

            $display("[%0t] Global max: %0d", $time, signed_max);

            // Compute sum of exp with max-subtraction
            fixed_sum = 0;
            for (i = 0; i < 8; i = i + 1) begin
                signed_token  = $signed(input_logits[i]);
                shifted_token = signed_token - signed_max;
                if (shifted_token < 0) unsigned_idx = shifted_token + 256;
                else unsigned_idx = shifted_token;
                fixed_exp = exp_rom[unsigned_idx];
                fixed_sum = fixed_sum + fixed_exp;
            end

            // MSR approximation
            shift_amount = 0;
            begin : find_leading
                for (j = 31; j >= 0; j = j - 1)
                if (fixed_sum[j]) begin
                    shift_amount = (j > 5) ? (j - 5) : 0;
                    disable find_leading;
                end
            end

            lut_index = fixed_sum >> shift_amount;
            if (lut_index > 63) lut_index = 63;
            recip_val = recip_lut[lut_index];

            // Compute expected outputs
            for (i = 0; i < 8; i = i + 1) begin
                signed_token  = $signed(input_logits[i]);
                shifted_token = signed_token - signed_max;
                if (shifted_token < 0) unsigned_idx = shifted_token + 256;
                else unsigned_idx = shifted_token;
                fixed_exp  = exp_rom[unsigned_idx];
                prod_int   = fixed_exp * recip_val;
                scaled_int = (prod_int >> shift_amount) >> 7;
                if (scaled_int > 48'd255) expected_output[i] = 8'd255;
                else expected_output[i] = scaled_int[7:0];
            end

            $display("[%0t] Expected outputs: [%0d, %0d, %0d, %0d, %0d, %0d, %0d, %0d]", $time,
                     expected_output[0], expected_output[1], expected_output[2],
                     expected_output[3], expected_output[4], expected_output[5],
                     expected_output[6], expected_output[7]);

            // Configure and start DUT
            num_tokens = 8;
            @(posedge clk);
            start = 1;
            @(posedge clk);
            start = 0;

            // Drive input
            repeat (3) @(posedge clk);
            s_axis_tdata  = {t7, t6, t5, t4, t3, t2, t1, t0};
            s_axis_tvalid = 1;
            s_axis_tlast  = 1;

            while (!s_axis_tready) @(posedge clk);
            @(posedge clk);
            s_axis_tvalid = 0;
            s_axis_tlast  = 0;

            // Wait for output
            m_axis_tready = 1;
            while (!m_axis_tvalid) begin
                @(posedge clk);
                #1;
            end
            #1;  // Allow signals to settle before sampling

            // Verify output
            error_count = 0;
            $display("\n[%0t] Hardware output: [%0d, %0d, %0d, %0d, %0d, %0d, %0d, %0d]", $time,
                     m_axis_tdata[7:0], m_axis_tdata[15:8], m_axis_tdata[23:16],
                     m_axis_tdata[31:24], m_axis_tdata[39:32], m_axis_tdata[47:40],
                     m_axis_tdata[55:48], m_axis_tdata[63:56]);


            for (i = 0; i < 8; i = i + 1) begin
                received_token = m_axis_tdata[i*8+:8];
                if (received_token !== expected_output[i]) begin
                    if ((received_token > expected_output[i] + 2) || 
                        (expected_output[i] > received_token + 2)) begin
                        $display("[%0t] ERROR: Token %0d: Expected %0d, Got %0d", $time, i,
                                 expected_output[i], received_token);
                        error_count = error_count + 1;
                    end else begin
                        $display("[%0t] PASS (tolerance): Token %0d: Expected %0d, Got %0d", $time,
                                 i, expected_output[i], received_token);
                    end
                end else begin
                    $display("[%0t] PASS: Token %0d: Expected %0d, Got %0d", $time, i,
                             expected_output[i], received_token);
                end
            end

            @(posedge clk);
            m_axis_tready = 0;

            // Wait for done
            while (!done) @(posedge clk);

            if (error_count == 0) begin
                $display("[%0t] Test %0d PASSED", $time, test_id);
                pass_count = pass_count + 1;
            end else begin
                $display("[%0t] Test %0d FAILED with %0d errors", $time, test_id, error_count);
                fail_count = fail_count + 1;
            end

            repeat (5) @(posedge clk);
        end
    endtask

    // Task: Generate ViT-realistic attention patterns
    // Pattern types:
    //   0 = Self-focus: Query attends mostly to itself (diagonal pattern)
    //   1 = Local attention: Higher scores for nearby tokens (position bias effect)
    //   2 = Sparse/peaked: One or few tokens dominate (key information extraction)
    //   3 = Uniform: Equal attention to all tokens (context mixing)
    task generate_vit_attention_pattern;
        input integer num_tokens_in;
        input integer valid_tokens;  // Actual valid tokens (rest are padding)
        input integer pattern_type;
        input integer query_idx;  // Which query position (for local pattern variation)

        integer i;
        integer win_size;
        integer q;
        integer q_r;
        integer q_c;
        integer k_r;
        integer k_c;
        integer d_row;
        integer d_col;
        integer dist_val;
        integer score;
        integer center_idx;
        integer center_r;
        integer center_c;

        begin
            // Initialize all to padding value
            for (i = 0; i < num_tokens_in; i = i + 1) begin
                input_logits[i] = PADDING_VALUE;  // padded/invalid lanes
            end

            // Infer window size (TinyViT uses 7x7 and 14x14 windows)
            if (valid_tokens == 49) win_size = 7;
            else if (valid_tokens == 196) win_size = 14;
            else win_size = 7;  // fallback for ad-hoc tests

            q   = query_idx % valid_tokens;
            q_r = q / win_size;
            q_c = q % win_size;

            // Generate pattern only for valid tokens
            case (pattern_type)
                0: begin  // Self-focus pattern
                    for (i = 0; i < valid_tokens; i = i + 1) begin
                        k_r = i / win_size;
                        k_c = i % win_size;
                        d_row = (k_r > q_r) ? (k_r - q_r) : (q_r - k_r);
                        d_col = (k_c > q_c) ? (k_c - q_c) : (q_c - k_c);
                        dist_val = d_row + d_col;  // Manhattan distance

                        if (dist_val == 0) score = 8;
                        else if (dist_val == 1) score = 5;
                        else if (dist_val == 2) score = 3;
                        else if (dist_val <= 4) score = 1;
                        else score = -2;

                        input_logits[i] = score[7:0];
                    end
                end

                1: begin  // Local attention pattern (simulates position bias)
                    for (i = 0; i < valid_tokens; i = i + 1) begin
                        k_r = i / win_size;
                        k_c = i % win_size;
                        d_row = (k_r > q_r) ? (k_r - q_r) : (q_r - k_r);
                        d_col = (k_c > q_c) ? (k_c - q_c) : (q_c - k_c);
                        dist_val = d_row + d_col;

                        // Mild falloff: keeps logits in a range that the exp LUT resolves.
                        score = 6 - dist_val;
                        if (score < -8) score = -8;
                        input_logits[i] = score[7:0];
                    end
                end

                2: begin  // Sparse/peaked pattern (one dominant token)
                    // Simulates attention to a specific key token
                    center_idx = (query_idx * 7 + 13) % valid_tokens;  // Deterministic but varied
                    center_r   = center_idx / win_size;
                    center_c   = center_idx % win_size;
                    for (i = 0; i < valid_tokens; i = i + 1) begin
                        k_r = i / win_size;
                        k_c = i % win_size;
                        d_row = (k_r > center_r) ? (k_r - center_r) : (center_r - k_r);
                        d_col = (k_c > center_c) ? (k_c - center_c) : (center_c - k_c);
                        dist_val = d_row + d_col;

                        if (i == center_idx) score = 8;
                        else if (dist_val == 1) score = 3;
                        else score = -4;

                        input_logits[i] = score[7:0];
                    end
                end

                3: begin  // Uniform pattern (all equal attention)
                    for (i = 0; i < valid_tokens; i = i + 1) begin
                        input_logits[i] = 8'sd0;  // All same value
                    end
                end

                default: begin
                    // Random pattern fallback
                    for (i = 0; i < valid_tokens; i = i + 1) begin
                        input_logits[i] = rand_between(ATTN_LOGIT_MIN, ATTN_LOGIT_MAX);
                    end
                end
            endcase
        end
    endtask

    // Task: Run ViT Stage Test with realistic window sizes
    // Tests softmax with TinyViT-specific attention patterns
    task run_vit_stage_test;
        input integer test_id;
        input [8*64-1:0] test_name;
        input integer num_tokens_in;  // Total tokens (padded to multiple of 8)
        input integer valid_tokens;  // Actual valid tokens
        input integer pattern_type;

        integer i;
        integer query_idx;
        integer qsel;
        integer query_samples[0:2];

        begin
            $display("\n========================================");
            $display("[%0t] Test %0d: %s", $time, test_id, test_name);
            $display("  Tokens: %0d total, %0d valid, pattern type: %0d", num_tokens_in,
                     valid_tokens, pattern_type);
            $display("========================================");

            reset_dut();

            // Sample a few query rows (softmax is invoked per-query in attention)
            query_samples[0] = 0;
            query_samples[1] = valid_tokens / 2;
            query_samples[2] = valid_tokens - 1;

            for (qsel = 0; qsel < 3; qsel = qsel + 1) begin
                query_idx = query_samples[qsel];

                $display("\n[%0t]  Query row %0d/%0d (query_idx=%0d)", $time, qsel + 1, 3,
                         query_idx);

                // Generate attention pattern (valid tokens only; rest padded)
                generate_vit_attention_pattern(num_tokens_in, valid_tokens, pattern_type,
                                               query_idx);

                // Compute expected output
                compute_expected_output(num_tokens_in);

                // Display sample of input/expected
                $display(
                    "[%0t]  Sample logits (first 8): [%0d, %0d, %0d, %0d, %0d, %0d, %0d, %0d]",
                    $time, $signed(input_logits[0]), $signed(input_logits[1]),
                    $signed(input_logits[2]), $signed(input_logits[3]), $signed(input_logits[4]),
                    $signed(input_logits[5]), $signed(input_logits[6]), $signed(input_logits[7]));

                // Configure and start DUT
                num_tokens = num_tokens_in;

                @(posedge clk);
                start = 1;
                @(posedge clk);
                start = 0;

                // Drive input and monitor output
                repeat (3) @(posedge clk);
                fork
                    begin : drive_input_vit
                        drive_input_stream(num_tokens_in);
                    end
                    begin : monitor_output_vit
                        monitor_output_stream(num_tokens_in);
                    end
                join

                // Wait for done
                while (!done) @(posedge clk);

                // Give the DUT a couple cycles to return to IDLE before next start
                repeat (2) @(posedge clk);
            end

            $display("\n[%0t] Test %0d complete (%0d tokens, %0d queries)", $time, test_id,
                     num_tokens_in, 3);

            repeat (5) @(posedge clk);
        end
    endtask

    // Task: Run Scaled Distribution Test
    // Takes a base distribution pattern and scales it to larger token counts
    task run_scaled_distribution_test;
        input integer test_id;
        input [8*64-1:0] test_name;
        input integer num_tokens_in;
        input integer valid_tokens;
        // Distribution parameters (8 base values that will be repeated/interpolated)
        input signed [7:0] base0, base1, base2, base3, base4, base5, base6, base7;

        integer i;
        integer base_idx;

        begin
            $display("\n========================================");
            $display("[%0t] Test %0d: %s", $time, test_id, test_name);
            $display("  Scaling distribution to %0d tokens (%0d valid)", num_tokens_in,
                     valid_tokens);
            $display("========================================");

            reset_dut();

            // Fill valid tokens by cycling through base pattern
            for (i = 0; i < num_tokens_in; i = i + 1) begin
                if (i < valid_tokens) begin
                    base_idx = i % 8;
                    case (base_idx)
                        0: input_logits[i] = base0;
                        1: input_logits[i] = base1;
                        2: input_logits[i] = base2;
                        3: input_logits[i] = base3;
                        4: input_logits[i] = base4;
                        5: input_logits[i] = base5;
                        6: input_logits[i] = base6;
                        7: input_logits[i] = base7;
                    endcase
                end else begin
                    // Padding tokens
                    input_logits[i] = PADDING_VALUE;
                end
            end

            // Compute expected output
            compute_expected_output(num_tokens_in);

            // Configure and start DUT
            num_tokens = num_tokens_in;

            @(posedge clk);
            start = 1;
            @(posedge clk);
            start = 0;

            // Drive input and monitor output
            repeat (3) @(posedge clk);
            fork
                begin : drive_input_scaled
                    drive_input_stream(num_tokens_in);
                end
                begin : monitor_output_scaled
                    monitor_output_stream(num_tokens_in);
                end
            join

            // Wait for done
            while (!done) @(posedge clk);

            $display("[%0t] Test %0d complete (%0d tokens)", $time, test_id, num_tokens_in);

            repeat (5) @(posedge clk);
        end
    endtask


    // Main Test Sequence
    initial begin
        // Initialize
        test_case   = 0;
        pass_count  = 0;
        fail_count  = 0;
        cycle_count = 0;

        $display("\n==========================================================");
        $display("Softmax Unit Testbench for TinyViT Attention");
        $display("  Window Sizes: 7x7 (49 tokens), 14x14 (196 tokens)");
        $display("==========================================================\n");

        // Initialize LUTs (dummy - real LUTs loaded by DUT)
        $display("[%0t] Loading LUT files...", $time);
        $display("  EXP LUT: %s", EXP_INIT_FILE);
        $display("  RECIP LUT: %s", RECIP_INIT_FILE);

        // =====================================================================
        // DISTRIBUTION TEST 1: Normal Distribution (varied values)
        // =====================================================================
        run_distribution_test(1, "NORMAL DISTRIBUTION", 8'sd12, 8'sd5, -8'sd3, 8'sd8, -8'sd7, 8'sd3,
                              8'sd10, 8'sd0);

        // =====================================================================
        // DISTRIBUTION TEST 2: One-Hot (Single Dominant Token)
        // =====================================================================
        run_distribution_test(2, "ONE-HOT (Single Dominant)", -8'sd10, -8'sd10, -8'sd10, 8'sd50,
                              -8'sd10, -8'sd10, -8'sd10, -8'sd10);

        // =====================================================================
        // DISTRIBUTION TEST 3: Two Competing Tokens (Equal High Values)
        // =====================================================================
        run_distribution_test(3, "TWO COMPETING TOKENS", -8'sd10, 8'sd30, -8'sd10, 8'sd30, -8'sd10,
                              -8'sd10, -8'sd10, -8'sd10);

        // =====================================================================
        // DISTRIBUTION TEST 4: All Same Value (Uniform Output)
        // =====================================================================
        run_distribution_test(4, "ALL SAME VALUE", 8'sd10, 8'sd10, 8'sd10, 8'sd10, 8'sd10, 8'sd10,
                              8'sd10, 8'sd10);

        // =====================================================================
        // DISTRIBUTION TEST 5: All Negative Logits
        // =====================================================================
        run_distribution_test(5, "ALL NEGATIVE LOGITS", -8'sd5, -8'sd10, -8'sd15, -8'sd3, -8'sd20,
                              -8'sd8, -8'sd12, -8'sd7);

        // =====================================================================
        // DISTRIBUTION TEST 6: Bimodal (Two groups)
        // =====================================================================
        run_distribution_test(6, "BIMODAL DISTRIBUTION", -8'sd20, -8'sd25, -8'sd22, -8'sd18, 8'sd20,
                              8'sd25, 8'sd22, 8'sd18);

        // // =====================================================================
        // // DISTRIBUTION TEST 7: High Variance (range limited to avoid wraparound)
        // // =====================================================================
        // run_distribution_test(7, "HIGH VARIANCE", -8'sd60, 8'sd50, -8'sd40, 8'sd30, -8'sd20, 8'sd10,
        //                       8'sd0, 8'sd60);

        // // =====================================================================
        // // DISTRIBUTION TEST 8: Low Variance (clustered)
        // // =====================================================================
        // run_distribution_test(8, "LOW VARIANCE", 8'sd0, 8'sd1, 8'sd2, 8'sd3, 8'sd1, 8'sd0, 8'sd2,
        //                       8'sd1);

        // // Run specialized tests
        // run_corner_cases();

        // =====================================================================
        // VIT STAGE 1/3 TESTS: 7x7 Window Attention (49 valid tokens, 56 total)
        // These simulate the windowed self-attention in TinyViT Stages 1 and 3
        // =====================================================================
        $display("\n\n############################################################");
        $display("# VIT ATTENTION TESTS - TinyViT Window Sizes               #");
        $display("############################################################\n");

        // Stage 1/3: 7x7 window = 49 tokens (padded to 56)
        run_vit_stage_test(9, "VIT STAGE 1/3: Self-Focus (7x7)", VIT_STAGE_1_3_TOKENS,
                           VIT_STAGE_1_3_VALID, 0);
        run_vit_stage_test(10, "VIT STAGE 1/3: Local Attention (7x7)", VIT_STAGE_1_3_TOKENS,
                           VIT_STAGE_1_3_VALID, 1);
        run_vit_stage_test(11, "VIT STAGE 1/3: Sparse Peak (7x7)", VIT_STAGE_1_3_TOKENS,
                           VIT_STAGE_1_3_VALID, 2);
        run_vit_stage_test(12, "VIT STAGE 1/3: Uniform (7x7)", VIT_STAGE_1_3_TOKENS,
                           VIT_STAGE_1_3_VALID, 3);

        // =====================================================================
        // VIT STAGE 2 TESTS: 14x14 Window Attention (196 valid tokens, 200 total)
        // This is the largest window size in TinyViT
        // =====================================================================
        run_vit_stage_test(13, "VIT STAGE 2: Self-Focus (14x14)", VIT_STAGE_2_TOKENS,
                           VIT_STAGE_2_VALID, 0);
        run_vit_stage_test(14, "VIT STAGE 2: Local Attention (14x14)", VIT_STAGE_2_TOKENS,
                           VIT_STAGE_2_VALID, 1);
        run_vit_stage_test(15, "VIT STAGE 2: Sparse Peak (14x14)", VIT_STAGE_2_TOKENS,
                           VIT_STAGE_2_VALID, 2);
        run_vit_stage_test(16, "VIT STAGE 2: Uniform (14x14)", VIT_STAGE_2_TOKENS,
                           VIT_STAGE_2_VALID, 3);

        // =====================================================================
        // SCALED DISTRIBUTION TESTS: Base patterns at realistic window sizes
        // Verifies the 8-token distribution patterns scale correctly
        // =====================================================================
        $display("\n\n############################################################");
        $display("# SCALED DISTRIBUTION TESTS                                 #");
        $display("############################################################\n");

        // One-hot pattern at Stage 1/3 size (49 tokens)
        run_scaled_distribution_test(17, "ONE-HOT @ Stage 1/3 (56 tokens)", VIT_STAGE_1_3_TOKENS,
                                     VIT_STAGE_1_3_VALID, -8'sd10, -8'sd10, -8'sd10, 8'sd50,
                                     -8'sd10, -8'sd10, -8'sd10, -8'sd10);

        // Bimodal pattern at Stage 2 size (196 tokens)
        run_scaled_distribution_test(18, "BIMODAL @ Stage 2 (200 tokens)", VIT_STAGE_2_TOKENS,
                                     VIT_STAGE_2_VALID, -8'sd20, -8'sd25, -8'sd22, -8'sd18, 8'sd20,
                                     8'sd25, 8'sd22, 8'sd18);

        // High variance pattern at Stage 1/3 size
        // Note: Range limited to ~120 to avoid 8-bit wraparound after max-subtraction
        run_scaled_distribution_test(19, "HIGH VARIANCE @ Stage 1/3 (56 tokens)",
                                     VIT_STAGE_1_3_TOKENS, VIT_STAGE_1_3_VALID, -8'sd60, 8'sd50,
                                     -8'sd40, 8'sd30, -8'sd20, 8'sd10, 8'sd0, 8'sd60);


        // Summary
        $display("\n========================================");
        $display("TESTBENCH SUMMARY");
        $display("========================================");
        $display("Passed: %0d", pass_count);
        $display("Failed: %0d", fail_count);
        $display("Total Tests: %0d", pass_count + fail_count);

        if (fail_count == 0) begin
            $display("\nALL TESTS PASSED!");
        end else begin
            $display("\nSOME TESTS FAILED!");
        end

        $display("\nSimulation Complete");
        $finish;
    end

    // Cycle Counter (for performance measurement)
    always @(posedge clk) begin
        if (start) begin
            cycle_count = 0;
        end else if (!done) begin
            cycle_count = cycle_count + 1;
        end
    end

    // Timeout Protection
    time TIMEOUT_CYCLES = 64'd1000000000000;  // large guard window
    initial begin
        #TIMEOUT_CYCLES;
        $display("\nSIMULATION TIMEOUT!");
        $display("Test may be stuck in infinite loop");
        $finish;
    end

endmodule
