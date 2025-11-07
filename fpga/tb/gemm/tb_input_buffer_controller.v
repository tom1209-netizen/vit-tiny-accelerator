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

    // Sent data capture for checking
    reg signed  [     DATA_WIDTH-1:0] sent_data     [0:TOTAL_VALUES-1];

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

    // AXIS driver for one beat
    task send_axis_beat;
        input [AXIS_DATA_WIDTH-1:0] tdata_in;
        input tlast_in;
        begin
            s_axis_tdata  <= tdata_in;
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= tlast_in;
            @(posedge clk);
            s_axis_tvalid <= 1'b0;
            s_axis_tlast  <= 1'b0;
            s_axis_tdata  <= {AXIS_DATA_WIDTH{1'b0}};
        end
    endtask

    integer i, j, k, errors, out_row, val;
    reg [AXIS_DATA_WIDTH-1:0] beat;

    initial begin
        // Init
        rst_n = 1'b0;
        enable = 1'b0;
        s_axis_tdata = {AXIS_DATA_WIDTH{1'b0}};
        s_axis_tvalid = 1'b0;
        s_axis_tlast = 1'b0;
        errors = 0;
        out_row = 0;

        // Reset
        repeat (5) @(posedge clk);
        rst_n  = 1'b1;
        enable = 1'b1;
        @(posedge clk);

        $display("Test 1: Send a full 8x8 matrix via AXI-Stream");

        // Drive and check each beat in lockstep
        for (i = 0; i < NUM_INPUT_BEATS; i = i + 1) begin
            beat = {AXIS_DATA_WIDTH{1'b0}};
            for (j = 0; j < VALUES_PER_BEAT; j = j + 1) begin
                val = i * VALUES_PER_BEAT + j;
                beat[j*DATA_WIDTH+:DATA_WIDTH] = val[DATA_WIDTH-1:0];
                sent_data[i*VALUES_PER_BEAT+j] = val[DATA_WIDTH-1:0];
            end

            send_axis_beat(beat, (i == NUM_INPUT_BEATS - 1));

            // Wait for data_valid pulse for this beat
            @(posedge clk);
            while (data_valid == 1'b0) @(posedge clk);

            $display("Beat %0d tdata = 0x%016h", out_row, beat);
            $display("Actual   [%0d]: %0d %0d %0d %0d %0d %0d %0d %0d", out_row, data_out_0,
                     data_out_1, data_out_2, data_out_3, data_out_4, data_out_5, data_out_6,
                     data_out_7);
            $write("Expected [%0d]: ", out_row);
            for (k = 0; k < ARRAY_SIZE; k = k + 1) begin
                $write("%0d", sent_data[out_row*ARRAY_SIZE+k]);
                if (k != ARRAY_SIZE - 1) $write(" ");
            end
            $display("");

            // Compare this row immediately
            $display("# Checking output row %0d", out_row);
            if (data_out_0 != sent_data[out_row*ARRAY_SIZE+0]) errors = errors + 1;
            if (data_out_1 != sent_data[out_row*ARRAY_SIZE+1]) errors = errors + 1;
            if (data_out_2 != sent_data[out_row*ARRAY_SIZE+2]) errors = errors + 1;
            if (data_out_3 != sent_data[out_row*ARRAY_SIZE+3]) errors = errors + 1;
            if (data_out_4 != sent_data[out_row*ARRAY_SIZE+4]) errors = errors + 1;
            if (data_out_5 != sent_data[out_row*ARRAY_SIZE+5]) errors = errors + 1;
            if (data_out_6 != sent_data[out_row*ARRAY_SIZE+6]) errors = errors + 1;
            if (data_out_7 != sent_data[out_row*ARRAY_SIZE+7]) errors = errors + 1;

            out_row = out_row + 1;
        end

        if (errors == 0) $display("PASS: All rows matched.");
        else $display("FAIL: %0d mismatches.", errors);
        $finish;
    end

endmodule
