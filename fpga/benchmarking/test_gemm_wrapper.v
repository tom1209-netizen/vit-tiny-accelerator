`timescale 1ns / 1ps

module test_gemm_wrapper #(
    parameter DATA_WIDTH      = 8,
    parameter ACC_WIDTH       = 32,
    parameter ARRAY_SIZE      = 8,
    parameter AXIS_DATA_WIDTH = 64
) (
    input wire aclk,
    input wire aresetn,

    // GPIO Control Interface (directly from AXI GPIO)
    input  wire [31:0] gpio_ctrl,   // [0]: start_tile pulse
    output wire [31:0] gpio_status, // [0]: tile_done

    // AXI-Stream Slave A (from DMA_0 Read Channel)
    input  wire [AXIS_DATA_WIDTH-1:0] s_axis_a_tdata,
    input  wire                       s_axis_a_tvalid,
    input  wire                       s_axis_a_tlast,
    output wire                       s_axis_a_tready,

    // AXI-Stream Slave B (from DMA_1 Read Channel)
    input  wire [AXIS_DATA_WIDTH-1:0] s_axis_b_tdata,
    input  wire                       s_axis_b_tvalid,
    input  wire                       s_axis_b_tlast,
    output wire                       s_axis_b_tready,

    // AXI-Stream Master (to DMA Write Channel)
    output wire [AXIS_DATA_WIDTH-1:0] m_axis_tdata,
    output wire                       m_axis_tvalid,
    output wire                       m_axis_tlast,
    input  wire                       m_axis_tready
);
    // Extract control signals from GPIO
    wire start_tile_raw = gpio_ctrl[0];

    // Edge detection for start_tile (convert level to pulse)
    reg start_d1, start_d2;
    wire start_tile_pulse;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            start_d1 <= 1'b0;
            start_d2 <= 1'b0;
        end else begin
            start_d1 <= start_tile_raw;
            start_d2 <= start_d1;
        end
    end

    assign start_tile_pulse = start_d1 && !start_d2;  // Rising edge

    // DUT status signals
    wire tile_done;

    // Pack GPIO status
    assign gpio_status = {31'd0, tile_done};

    // DUT: GEMM Core Top
    gemm_core_top #(
        .DATA_WIDTH     (DATA_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),
        .ARRAY_SIZE     (ARRAY_SIZE),
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH)
    ) u_gemm_core (
        .aclk   (aclk),
        .aresetn(aresetn),

        .start_tile(start_tile_pulse),
        .tile_done (tile_done),

        .s_axis_a_tdata (s_axis_a_tdata),
        .s_axis_a_tvalid(s_axis_a_tvalid),
        .s_axis_a_tlast (s_axis_a_tlast),
        .s_axis_a_tready(s_axis_a_tready),

        .s_axis_b_tdata (s_axis_b_tdata),
        .s_axis_b_tvalid(s_axis_b_tvalid),
        .s_axis_b_tlast (s_axis_b_tlast),
        .s_axis_b_tready(s_axis_b_tready),

        .m_axis_out_tdata (m_axis_tdata),
        .m_axis_out_tvalid(m_axis_tvalid),
        .m_axis_out_tlast (m_axis_tlast),
        .m_axis_out_tready(m_axis_tready)
    );

endmodule
