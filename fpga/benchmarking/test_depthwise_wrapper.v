`timescale 1ns / 1ps

module test_depthwise_wrapper #(
    parameter DATA_WIDTH   = 8,
    parameter LANES        = 8,
    parameter INPUT_WIDTH  = 64,
    parameter OUTPUT_WIDTH = 64,
    parameter MAX_WIDTH    = 28,
    parameter MAX_CHANNELS = 128,
    parameter ACC_WIDTH    = 32
) (
    input wire aclk,
    input wire aresetn,

    // GPIO Control Interface
    // Control Out:
    //   [0]: start (pulse)
    //   [8:1]: cfg_height (8 bits, max 255)
    //   [16:9]: cfg_width (8 bits, max 255)
    //   [24:17]: cfg_channels (8 bits, max 255)
    input  wire [31:0] gpio_ctrl,
    // Status In:
    //   [0]: done
    output wire [31:0] gpio_status,

    // AXI-Stream Slave: Kernels (from DMA_0)
    input  wire [INPUT_WIDTH-1:0] s_axis_kernel_tdata,
    input  wire                   s_axis_kernel_tvalid,
    input  wire                   s_axis_kernel_tlast,
    output wire                   s_axis_kernel_tready,

    // AXI-Stream Slave: Data Input (from DMA_1)
    input  wire [INPUT_WIDTH-1:0] s_axis_data_tdata,
    input  wire                   s_axis_data_tvalid,
    input  wire                   s_axis_data_tlast,
    output wire                   s_axis_data_tready,

    // AXI-Stream Master (to DMA Write Channel)
    output wire [OUTPUT_WIDTH-1:0] m_axis_tdata,
    output wire                    m_axis_tvalid,
    output wire                    m_axis_tlast,
    input  wire                    m_axis_tready
);
    // Extract control signals
    wire start_raw = gpio_ctrl[0];
    wire [7:0] height_cfg   = gpio_ctrl[8:1];
    wire [7:0] width_cfg    = gpio_ctrl[16:9];
    wire [7:0] channels_cfg = gpio_ctrl[24:17];

    // Edge detection for start
    reg start_d1, start_d2;
    wire start_pulse;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            start_d1 <= 1'b0;
            start_d2 <= 1'b0;
        end else begin
            start_d1 <= start_raw;
            start_d2 <= start_d1;
        end
    end

    assign start_pulse = start_d1 && !start_d2;

    // Latch configuration on start pulse
    reg [15:0] cfg_height_latched;
    reg [15:0] cfg_width_latched;
    reg [15:0] cfg_channels_latched;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            cfg_height_latched   <= 16'd0;
            cfg_width_latched    <= 16'd0;
            cfg_channels_latched <= 16'd0;
        end else if (start_pulse) begin
            cfg_height_latched   <= {8'd0, height_cfg};
            cfg_width_latched    <= {8'd0, width_cfg};
            cfg_channels_latched <= {8'd0, channels_cfg};
        end
    end

    // Status
    wire done;
    assign gpio_status = {31'd0, done};

    // DUT: Depthwise Convolution Unit
    depthwise_conv_unit #(
        .DATA_WIDTH  (DATA_WIDTH),
        .LANES       (LANES),
        .INPUT_WIDTH (INPUT_WIDTH),
        .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .MAX_WIDTH   (MAX_WIDTH),
        .MAX_CHANNELS(MAX_CHANNELS),
        .ACC_WIDTH   (ACC_WIDTH)
    ) u_depthwise (
        .clk  (aclk),
        .rst_n(aresetn),

        .start       (start_pulse),
        .done        (done),
        .cfg_height  (cfg_height_latched),
        .cfg_width   (cfg_width_latched),
        .cfg_channels(cfg_channels_latched),

        .axis_kernel_in_tdata (s_axis_kernel_tdata),
        .axis_kernel_in_tvalid(s_axis_kernel_tvalid),
        .axis_kernel_in_tlast (s_axis_kernel_tlast),
        .axis_kernel_in_tready(s_axis_kernel_tready),

        .axis_data_in_tdata (s_axis_data_tdata),
        .axis_data_in_tvalid(s_axis_data_tvalid),
        .axis_data_in_tlast (s_axis_data_tlast),
        .axis_data_in_tready(s_axis_data_tready),

        .axis_data_out_tdata (m_axis_tdata),
        .axis_data_out_tvalid(m_axis_tvalid),
        .axis_data_out_tlast (m_axis_tlast),
        .axis_data_out_tready(m_axis_tready)
    );

endmodule
