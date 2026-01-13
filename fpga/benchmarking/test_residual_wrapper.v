`timescale 1ns / 1ps

module test_residual_wrapper #(
    parameter DATA_WIDTH = 64,
    parameter ELEM_WIDTH = 8
) (
    input wire aclk,
    input wire aresetn,

    // GPIO Interface (optional - for consistency)
    input  wire [31:0] gpio_ctrl,   // Not used - pure dataflow
    output wire [31:0] gpio_status, // [0]: output valid (for timing reference)

    // AXI-Stream Slave A (from DMA_0 Read Channel)
    input  wire [DATA_WIDTH-1:0] s_axis_a_tdata,
    input  wire                  s_axis_a_tvalid,
    input  wire                  s_axis_a_tlast,
    output wire                  s_axis_a_tready,

    // AXI-Stream Slave B (from DMA_1 Read Channel)
    input  wire [DATA_WIDTH-1:0] s_axis_b_tdata,
    input  wire                  s_axis_b_tvalid,
    input  wire                  s_axis_b_tlast,
    output wire                  s_axis_b_tready,

    // AXI-Stream Master (to DMA Write Channel)
    output wire [DATA_WIDTH-1:0] m_axis_tdata,
    output wire                  m_axis_tvalid,
    output wire                  m_axis_tlast,
    input  wire                  m_axis_tready
);
    // Status: expose output valid for timing measurement
    assign gpio_status = {31'd0, m_axis_tvalid};

    // DUT: Residual Add
    residual_add #(
        .DATA_WIDTH(DATA_WIDTH),
        .ELEM_WIDTH(ELEM_WIDTH)
    ) u_residual_add (
        .clk  (aclk),
        .rst_n(aresetn),

        .s_axis_a_tdata (s_axis_a_tdata),
        .s_axis_a_tvalid(s_axis_a_tvalid),
        .s_axis_a_tlast (s_axis_a_tlast),
        .s_axis_a_tready(s_axis_a_tready),

        .s_axis_b_tdata (s_axis_b_tdata),
        .s_axis_b_tvalid(s_axis_b_tvalid),
        .s_axis_b_tlast (s_axis_b_tlast),
        .s_axis_b_tready(s_axis_b_tready),

        .m_axis_tdata (m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast (m_axis_tlast),
        .m_axis_tready(m_axis_tready)
    );

endmodule
