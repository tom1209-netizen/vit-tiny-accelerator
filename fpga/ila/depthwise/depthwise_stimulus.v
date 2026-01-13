`timescale 1ns / 1ps

module depthwise_axis_stimulus #(
    parameter DATA_WIDTH   = 8,
    parameter LANES        = 8,
    parameter INPUT_WIDTH  = 64,
    parameter OUTPUT_WIDTH = 64
) (
    input wire clk,
    input wire rst_n,
    input wire start_trigger,

    // Configuration (from VIO)
    input wire [7:0] cfg_height_in,
    input wire [7:0] cfg_width_in,
    input wire [7:0] cfg_channels_in,

    // Control outputs
    output reg         start,
    output reg  [15:0] cfg_height,
    output reg  [15:0] cfg_width,
    output reg  [15:0] cfg_channels,
    input  wire        done,

    // Kernel stream
    output reg  [INPUT_WIDTH-1:0] m_axis_kernel_tdata,
    output reg                    m_axis_kernel_tvalid,
    output reg                    m_axis_kernel_tlast,
    input  wire                   m_axis_kernel_tready,

    // Data stream
    output reg  [INPUT_WIDTH-1:0] m_axis_data_tdata,
    output reg                    m_axis_data_tvalid,
    output reg                    m_axis_data_tlast,
    input  wire                   m_axis_data_tready
);

    // Compact test: 4x4x8 feature map
    localparam TEST_HEIGHT = 4;
    localparam TEST_WIDTH = 4;
    localparam TEST_CHANNELS = 8;
    localparam KERNEL_SIZE = 9;  // 3x3

    // Kernel beats: 9 weights per channel group, channel_beats = channels/lanes = 1
    localparam KERNEL_BEATS = KERNEL_SIZE;  // 9 beats for 1 channel group

    // Data beats: height * width * channel_beats = 4*4*1 = 16
    localparam DATA_BEATS = TEST_HEIGHT * TEST_WIDTH;

    reg [7:0] kernel_beat_count;
    reg [7:0] data_beat_count;

    localparam IDLE = 3'd0;
    localparam LOAD_KERNEL = 3'd1;
    localparam START_PULSE = 3'd2;
    localparam STREAM_DATA = 3'd3;
    localparam WAIT_DONE = 3'd4;
    localparam FINISHED = 3'd5;
    reg [2:0] state;

    // Edge detection
    wire start_trigger_edge;
    reg start_d1, start_d2;
    assign start_trigger_edge = start_d1 && ~start_d2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_d1 <= 0;
            start_d2 <= 0;
        end else begin
            start_d1 <= start_trigger;
            start_d2 <= start_d1;
        end
    end

    // Kernel patterns: Simple uniform weights for easy verification
    // All weights = 1 means output = sum of 3x3 neighborhood (with padding = 0)
    always @(*) begin
        m_axis_kernel_tdata = {INPUT_WIDTH{1'b0}};

        if (state == LOAD_KERNEL) begin
            // For channel group 0: all weights = 1
            // Each beat contains 8 lanes of the same kernel position
            m_axis_kernel_tdata = {8{8'd1}};  // All lanes, weight = 1
        end
    end

    // Data patterns: Row-major ramp for predictable convolution output
    always @(*) begin
        m_axis_data_tdata = {INPUT_WIDTH{1'b0}};

        if (state == STREAM_DATA) begin
            // Create a ramp pattern: pixel value = (row * width + col) for each lane
            // Each beat contains 8 channels for the same (row, col)
            case (data_beat_count)
                // Row 0
                8'd0: m_axis_data_tdata = {8{8'd0}};  // (0,0)
                8'd1: m_axis_data_tdata = {8{8'd1}};  // (0,1)
                8'd2: m_axis_data_tdata = {8{8'd2}};  // (0,2)
                8'd3: m_axis_data_tdata = {8{8'd3}};  // (0,3)
                // Row 1
                8'd4: m_axis_data_tdata = {8{8'd4}};  // (1,0)
                8'd5: m_axis_data_tdata = {8{8'd5}};  // (1,1)
                8'd6: m_axis_data_tdata = {8{8'd6}};  // (1,2)
                8'd7: m_axis_data_tdata = {8{8'd7}};  // (1,3)
                // Row 2
                8'd8: m_axis_data_tdata = {8{8'd8}};  // (2,0)
                8'd9: m_axis_data_tdata = {8{8'd9}};  // (2,1)
                8'd10: m_axis_data_tdata = {8{8'd10}};  // (2,2)
                8'd11: m_axis_data_tdata = {8{8'd11}};  // (2,3)
                // Row 3
                8'd12: m_axis_data_tdata = {8{8'd12}};  // (3,0)
                8'd13: m_axis_data_tdata = {8{8'd13}};  // (3,1)
                8'd14: m_axis_data_tdata = {8{8'd14}};  // (3,2)
                8'd15: m_axis_data_tdata = {8{8'd15}};  // (3,3)
                default: m_axis_data_tdata = {INPUT_WIDTH{1'b0}};
            endcase
        end
    end

    // State machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= IDLE;
            start                <= 1'b0;
            cfg_height           <= 16'd0;
            cfg_width            <= 16'd0;
            cfg_channels         <= 16'd0;
            m_axis_kernel_tvalid <= 1'b0;
            m_axis_kernel_tlast  <= 1'b0;
            m_axis_data_tvalid   <= 1'b0;
            m_axis_data_tlast    <= 1'b0;
            kernel_beat_count    <= 8'd0;
            data_beat_count      <= 8'd0;
        end else begin
            start <= 1'b0;

            case (state)
                IDLE: begin
                    m_axis_kernel_tvalid <= 1'b0;
                    m_axis_data_tvalid   <= 1'b0;
                    kernel_beat_count    <= 8'd0;
                    data_beat_count      <= 8'd0;

                    if (start_trigger_edge) begin
                        // Capture config (use hardcoded for simplicity, ignore VIO)
                        cfg_height   <= TEST_HEIGHT;
                        cfg_width    <= TEST_WIDTH;
                        cfg_channels <= TEST_CHANNELS;
                        state        <= LOAD_KERNEL;
                    end
                end

                LOAD_KERNEL: begin
                    m_axis_kernel_tvalid <= 1'b1;
                    m_axis_kernel_tlast  <= (kernel_beat_count == KERNEL_BEATS - 1);

                    if (m_axis_kernel_tready && m_axis_kernel_tvalid) begin
                        if (kernel_beat_count == KERNEL_BEATS - 1) begin
                            state                <= START_PULSE;
                            m_axis_kernel_tvalid <= 1'b0;
                            m_axis_kernel_tlast  <= 1'b0;
                        end else begin
                            kernel_beat_count <= kernel_beat_count + 1;
                        end
                    end
                end

                START_PULSE: begin
                    start <= 1'b1;
                    state <= STREAM_DATA;
                    m_axis_data_tvalid <= 1'b1;
                end

                STREAM_DATA: begin
                    m_axis_data_tlast <= (data_beat_count == DATA_BEATS - 1);

                    if (m_axis_data_tready && m_axis_data_tvalid) begin
                        if (data_beat_count == DATA_BEATS - 1) begin
                            state              <= WAIT_DONE;
                            m_axis_data_tvalid <= 1'b0;
                            m_axis_data_tlast  <= 1'b0;
                        end else begin
                            data_beat_count <= data_beat_count + 1;
                        end
                    end
                end

                WAIT_DONE: begin
                    if (done) begin
                        state <= FINISHED;
                    end
                end

                FINISHED: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
