`timescale 1ns / 1ps

module test_softmax_wrapper #(
    parameter AXIS_DATA_WIDTH = 64,
    parameter DATA_WIDTH      = 8,
    parameter EXP_WIDTH       = 20,
    parameter SUM_WIDTH       = 32,
    parameter RECIP_WIDTH     = 16,
    parameter FIFO_DEPTH      = 256,
    parameter EXP_INIT_FILE   = "../rtl/softmax/lut/exp_table_q4_16.hex",
    parameter RECIP_INIT_FILE = "../rtl/softmax/lut/recip_lut.hex"
) (
    input wire aclk,
    input wire aresetn,

    // GPIO Control Interface
    // [0]: start pulse
    // [12:1]: num_tokens (up to 4096)
    input  wire [31:0] gpio_ctrl,
    // [0]: done
    output wire [31:0] gpio_status,

    // AXI-Stream Slave (from DMA Read Channel)
    input  wire [AXIS_DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                       s_axis_tvalid,
    input  wire                       s_axis_tlast,
    output wire                       s_axis_tready,

    // AXI-Stream Master (to DMA Write Channel)
    output wire [AXIS_DATA_WIDTH-1:0] m_axis_tdata,
    output wire                       m_axis_tvalid,
    output wire                       m_axis_tlast,
    input  wire                       m_axis_tready
);
    // Extract control signals
    wire start_raw = gpio_ctrl[0];
    wire [11:0] num_tokens_cfg = gpio_ctrl[12:1];

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

    // Latch num_tokens on start pulse
    reg [31:0] num_tokens_latched;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) num_tokens_latched <= 32'd0;
        else if (start_pulse) num_tokens_latched <= {20'd0, num_tokens_cfg};
    end

    // DUT status
    wire done;
    assign gpio_status = {31'd0, done};


    // DUT: Softmax Unit
    softmax_unit #(
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
        .DATA_WIDTH     (DATA_WIDTH),
        .EXP_WIDTH      (EXP_WIDTH),
        .SUM_WIDTH      (SUM_WIDTH),
        .RECIP_WIDTH    (RECIP_WIDTH),
        .FIFO_DEPTH     (FIFO_DEPTH),
        .EXP_INIT_FILE  (EXP_INIT_FILE),
        .RECIP_INIT_FILE(RECIP_INIT_FILE)
    ) u_softmax (
        .clk  (aclk),
        .rst_n(aresetn),

        .start     (start_pulse),
        .num_tokens(num_tokens_latched),
        .done      (done),

        .s_axis_tdata (s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast (s_axis_tlast),
        .s_axis_tready(s_axis_tready),

        .m_axis_tdata (m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast (m_axis_tlast),
        .m_axis_tready(m_axis_tready)
    );

endmodule
