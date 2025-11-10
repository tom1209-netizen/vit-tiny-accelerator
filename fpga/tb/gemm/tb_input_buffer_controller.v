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

    // Expected data store
    reg signed  [     DATA_WIDTH-1:0] sent_data     [0:TOTAL_VALUES-1];

    // Internals
    integer i, j, k, errors, out_row;
    integer                       idx;
    reg     [               31:0] val32;
    reg     [AXIS_DATA_WIDTH-1:0] beat;
    reg     [               31:0] cycles;
    reg     [               31:0] handshakes;

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
            $display(
                "TIMEOUT at cycle %0d: tvalid=%0b tready=%0b data_valid=%0b idx=%0d out_row=%0d",
                cycles, s_axis_tvalid, s_axis_tready, data_valid, idx, out_row);
            $finish;
        end
    end

    // Reset and setup
    initial begin
        // Init
        rst_n         = 1'b0;
        enable        = 1'b0;
        s_axis_tdata  = {AXIS_DATA_WIDTH{1'b0}};
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        errors        = 0;
        out_row       = 0;
        idx           = 0;
        handshakes    = 0;

        // Precompute expected data
        for (i = 0; i < NUM_INPUT_BEATS; i = i + 1) begin
            for (j = 0; j < VALUES_PER_BEAT; j = j + 1) begin
                val32 = i * VALUES_PER_BEAT + j;
                sent_data[i*VALUES_PER_BEAT+j] = val32[DATA_WIDTH-1:0];
            end
        end

        // Release reset and enable after setup
        repeat (5) @(posedge clk);
        rst_n  = 1'b1;
        enable = 1'b1;
        $display("Test: Continuous AXI-Stream, %0d beats, %0d values/beat", NUM_INPUT_BEATS,
                 VALUES_PER_BEAT);
    end

    // AXI master driver (continuous stream)
    initial begin : driver
        // Wait for reset deassert
        wait (rst_n == 1'b1);
        @(posedge clk);

        // Prepare first beat and assert TVALID up-front
        beat = {AXIS_DATA_WIDTH{1'b0}};
        for (j = 0; j < VALUES_PER_BEAT; j = j + 1) begin
            val32 = idx * VALUES_PER_BEAT + j;
            beat[j*DATA_WIDTH+:DATA_WIDTH] = val32[DATA_WIDTH-1:0];
        end
        s_axis_tdata  = beat;
        s_axis_tlast  = (idx == NUM_INPUT_BEATS - 1);
        s_axis_tvalid = 1'b1;

        // Stream all beats
        while (idx < NUM_INPUT_BEATS) begin
            @(posedge clk);
            if (s_axis_tready) begin
                handshakes = handshakes + 1;
                $display("%t HANDSHAKE #%0d (idx=%0d) TLAST=%0b", $time, handshakes, idx,
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

    // Output monitor and checker
    initial begin : monitor
        // Wait for reset deassert
        wait (rst_n == 1'b1);
        @(posedge clk);

        while (out_row < NUM_INPUT_BEATS) begin
            @(posedge clk);
            if (data_valid) begin
                $display("%t CONSUME beat %0d", $time, out_row);
                // Compare each lane explicitly
                if (data_out_0 !== sent_data[out_row*ARRAY_SIZE+0]) errors = errors + 1;
                if (data_out_1 !== sent_data[out_row*ARRAY_SIZE+1]) errors = errors + 1;
                if (data_out_2 !== sent_data[out_row*ARRAY_SIZE+2]) errors = errors + 1;
                if (data_out_3 !== sent_data[out_row*ARRAY_SIZE+3]) errors = errors + 1;
                if (data_out_4 !== sent_data[out_row*ARRAY_SIZE+4]) errors = errors + 1;
                if (data_out_5 !== sent_data[out_row*ARRAY_SIZE+5]) errors = errors + 1;
                if (data_out_6 !== sent_data[out_row*ARRAY_SIZE+6]) errors = errors + 1;
                if (data_out_7 !== sent_data[out_row*ARRAY_SIZE+7]) errors = errors + 1;
                out_row = out_row + 1;
            end
        end

        if (errors == 0) $display("PASS: All %0d beats matched.", NUM_INPUT_BEATS);
        else $display("FAIL: %0d mismatches.", errors);
        $finish;
    end

endmodule
