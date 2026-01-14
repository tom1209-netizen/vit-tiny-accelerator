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

    localparam KERNEL_SIZE = 9;  // 3x3

    reg [15:0] num_chan_beats;

    reg [15:0] kernel_chan_beat;
    reg [ 3:0] kernel_coeff;

    reg [15:0] data_row;
    reg [15:0] data_col;
    reg [15:0] data_chan_beat;
    wire [15:0] data_rowcol_idx = data_row * cfg_width + data_col;

    localparam IDLE = 3'd0;
    localparam START_PULSE = 3'd1;
    localparam LOAD_KERNEL = 3'd2;
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

    // Kernel patterns: Simple per-coefficient values for easy verification
    always @(*) begin
        m_axis_kernel_tdata = {INPUT_WIDTH{1'b0}};

        if (state == LOAD_KERNEL) begin
            // Each beat contains 8 lanes of the same kernel coefficient
            m_axis_kernel_tdata = {LANES{{(DATA_WIDTH-4){1'b0}}, kernel_coeff}};  // All lanes, coeff index
        end
    end

    // Data patterns: Row-major ramp for predictable convolution output
    always @(*) begin
        m_axis_data_tdata = {INPUT_WIDTH{1'b0}};

        if (state == STREAM_DATA) begin
            // Each beat contains 8 channels for the same (row, col)
            m_axis_data_tdata = {LANES{data_rowcol_idx[7:0]}};
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
            num_chan_beats       <= 16'd0;
            m_axis_kernel_tvalid <= 1'b0;
            m_axis_kernel_tlast  <= 1'b0;
            m_axis_data_tvalid   <= 1'b0;
            m_axis_data_tlast    <= 1'b0;
            kernel_chan_beat     <= 16'd0;
            kernel_coeff         <= 4'd0;
            data_row             <= 16'd0;
            data_col             <= 16'd0;
            data_chan_beat       <= 16'd0;
        end else begin
            start <= 1'b0;

            case (state)
                IDLE: begin
                    m_axis_kernel_tvalid <= 1'b0;
                    m_axis_data_tvalid   <= 1'b0;
                    m_axis_kernel_tlast  <= 1'b0;
                    m_axis_data_tlast    <= 1'b0;
                    kernel_chan_beat     <= 16'd0;
                    kernel_coeff         <= 4'd0;
                    data_row             <= 16'd0;
                    data_col             <= 16'd0;
                    data_chan_beat       <= 16'd0;

                    if (start_trigger_edge) begin
                        // Capture config from VIO
                        cfg_height     <= {8'd0, cfg_height_in};
                        cfg_width      <= {8'd0, cfg_width_in};
                        cfg_channels   <= {8'd0, cfg_channels_in};
                        num_chan_beats <= {8'd0, cfg_channels_in} / LANES;
                        state          <= START_PULSE;
                    end
                end

                START_PULSE: begin
                    start <= 1'b1;
                    if (num_chan_beats == 0 || cfg_height == 0 || cfg_width == 0) begin
                        state <= WAIT_DONE;
                    end else begin
                        state <= LOAD_KERNEL;
                    end
                end

                LOAD_KERNEL: begin
                    m_axis_kernel_tvalid <= 1'b1;
                    m_axis_kernel_tlast  <= (kernel_chan_beat == num_chan_beats - 1) &&
                                            (kernel_coeff == KERNEL_SIZE - 1);

                    if (m_axis_kernel_tready && m_axis_kernel_tvalid) begin
                        if ((kernel_chan_beat == num_chan_beats - 1) &&
                            (kernel_coeff == KERNEL_SIZE - 1)) begin
                            state                <= STREAM_DATA;
                            m_axis_kernel_tvalid <= 1'b0;
                            m_axis_kernel_tlast  <= 1'b0;
                        end else begin
                            if (kernel_coeff == KERNEL_SIZE - 1) begin
                                kernel_coeff     <= 4'd0;
                                kernel_chan_beat <= kernel_chan_beat + 1;
                            end else begin
                                kernel_coeff <= kernel_coeff + 1;
                            end
                        end
                    end
                end

                STREAM_DATA: begin
                    m_axis_data_tvalid <= 1'b1;
                    m_axis_data_tlast  <= (data_row == cfg_height - 1) &&
                                          (data_col == cfg_width - 1) &&
                                          (data_chan_beat == num_chan_beats - 1);

                    if (m_axis_data_tready && m_axis_data_tvalid) begin
                        if ((data_row == cfg_height - 1) &&
                            (data_col == cfg_width - 1) &&
                            (data_chan_beat == num_chan_beats - 1)) begin
                            state              <= WAIT_DONE;
                            m_axis_data_tvalid <= 1'b0;
                            m_axis_data_tlast  <= 1'b0;
                        end else begin
                            if (data_chan_beat == num_chan_beats - 1) begin
                                data_chan_beat <= 16'd0;
                                if (data_col == cfg_width - 1) begin
                                    data_col <= 16'd0;
                                    data_row <= data_row + 1;
                                end else begin
                                    data_col <= data_col + 1;
                                end
                            end else begin
                                data_chan_beat <= data_chan_beat + 1;
                            end
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
