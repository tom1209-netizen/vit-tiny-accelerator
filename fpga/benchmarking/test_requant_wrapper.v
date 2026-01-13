`timescale 1ns / 1ps

module test_requant_wrapper #(
    parameter DATA_WIDTH   = 64,
    parameter ACC_WIDTH    = 32,
    parameter LANES_INT8   = 8,
    parameter MAX_CHANNELS = 512
) (
    input wire aclk,
    input wire aresetn,

    // GPIO Control Interface
    // Control Out:
    //   [0]: cfg_mode_int32
    //   [1]: cfg_use_bias
    //   [6:2]: cfg_shift (5 bits)
    //   [7]: cfg_round_en
    //   [8]: cfg_sat_en
    //   [9]: cfg_proc_start (pulse)
    //   [10]: sb_load_start (pulse)
    //   [26:11]: sb_count / cfg_num_channels
    input  wire [31:0] gpio_ctrl,
    // Status In:
    //   [0]: sb_load_done
    output wire [31:0] gpio_status,

    // AXI-Stream Slave: Scale/Bias Table (from DMA_0)
    input  wire [DATA_WIDTH-1:0] s_axis_sb_tdata,
    input  wire                  s_axis_sb_tvalid,
    input  wire                  s_axis_sb_tlast,
    output wire                  s_axis_sb_tready,

    // AXI-Stream Slave: Data Input (from DMA_1)
    input  wire [DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                  s_axis_tvalid,
    input  wire                  s_axis_tlast,
    output wire                  s_axis_tready,

    // AXI-Stream Master (to DMA Write Channel)
    output wire [DATA_WIDTH-1:0] m_axis_tdata,
    output wire                  m_axis_tvalid,
    output wire                  m_axis_tlast,
    input  wire                  m_axis_tready
);
    // Extract control signals
    wire        cfg_mode_int32 = gpio_ctrl[0];
    wire        cfg_use_bias = gpio_ctrl[1];
    wire [ 4:0] cfg_shift = gpio_ctrl[6:2];
    wire        cfg_round_en = gpio_ctrl[7];
    wire        cfg_sat_en = gpio_ctrl[8];
    wire        proc_start_raw = gpio_ctrl[9];
    wire        sb_load_raw = gpio_ctrl[10];
    wire [15:0] count_cfg = gpio_ctrl[26:11];

    // Edge detection for pulses
    reg proc_d1, proc_d2;
    reg sb_d1, sb_d2;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            proc_d1 <= 1'b0;
            proc_d2 <= 1'b0;
            sb_d1   <= 1'b0;
            sb_d2   <= 1'b0;
        end else begin
            proc_d1 <= proc_start_raw;
            proc_d2 <= proc_d1;
            sb_d1   <= sb_load_raw;
            sb_d2   <= sb_d1;
        end
    end

    wire cfg_proc_start = proc_d1 && !proc_d2;
    wire sb_load_start = sb_d1 && !sb_d2;

    // Latch count on sb_load_start pulse
    reg [15:0] sb_count_latched;
    reg [15:0] cfg_num_channels_latched;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            sb_count_latched         <= 16'd0;
            cfg_num_channels_latched <= 16'd0;
        end else if (sb_load_start) begin
            sb_count_latched         <= count_cfg;
            cfg_num_channels_latched <= count_cfg;
        end
    end

    // Status
    wire sb_load_done;
    assign gpio_status = {31'd0, sb_load_done};


    // DUT: Requant Unit
    requant_unit #(
        .DATA_WIDTH  (DATA_WIDTH),
        .ACC_WIDTH   (ACC_WIDTH),
        .LANES_INT8  (LANES_INT8),
        .MAX_CHANNELS(MAX_CHANNELS)
    ) u_requant (
        .clk  (aclk),
        .rst_n(aresetn),

        .cfg_mode_int32  (cfg_mode_int32),
        .cfg_use_bias    (cfg_use_bias),
        .cfg_shift       (cfg_shift),
        .cfg_round_en    (cfg_round_en),
        .cfg_sat_en      (cfg_sat_en),
        .cfg_num_channels(cfg_num_channels_latched),
        .cfg_chan_base   (16'd0),
        .cfg_proc_start  (cfg_proc_start),

        .sb_load_start   (sb_load_start),
        .sb_count        (sb_count_latched),
        .sb_load_done    (sb_load_done),
        .s_axis_sb_tdata (s_axis_sb_tdata),
        .s_axis_sb_tvalid(s_axis_sb_tvalid),
        .s_axis_sb_tready(s_axis_sb_tready),
        .s_axis_sb_tlast (s_axis_sb_tlast),

        .s_axis_tdata (s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast (s_axis_tlast),

        .m_axis_tdata (m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast (m_axis_tlast)
    );

endmodule
