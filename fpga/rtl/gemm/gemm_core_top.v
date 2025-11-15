`timescale 1ns / 1ps

module gemm_core_top #(
    parameter DATA_WIDTH      = 8,
    parameter ACC_WIDTH       = 32,
    parameter ARRAY_SIZE      = 8,
    parameter AXIS_DATA_WIDTH = 64
) (
    input wire aclk,
    input wire aresetn,

    // Control
    input  wire start_tile,
    output wire tile_done,

    // AXI-Stream input A
    input  wire [AXIS_DATA_WIDTH-1:0] s_axis_a_tdata,
    input  wire                       s_axis_a_tvalid,
    input  wire                       s_axis_a_tlast,
    output wire                       s_axis_a_tready,

    // AXI-Stream input B
    input  wire [AXIS_DATA_WIDTH-1:0] s_axis_b_tdata,
    input  wire                       s_axis_b_tvalid,
    input  wire                       s_axis_b_tlast,
    output wire                       s_axis_b_tready,

    // AXI-Stream output C
    output wire [AXIS_DATA_WIDTH-1:0] m_axis_out_tdata,
    output wire                       m_axis_out_tvalid,
    output wire                       m_axis_out_tlast,
    input  wire                       m_axis_out_tready
);
    // A and B lanes from input buffer controllers
    wire signed [DATA_WIDTH-1:0] a0, a1, a2, a3, a4, a5, a6, a7;
    wire a_valid_beat;

    wire signed [DATA_WIDTH-1:0] b0, b1, b2, b3, b4, b5, b6, b7;
    wire b_valid_beat;

    // A stream buffer
    input_buffer_controller #(
        .DATA_WIDTH     (DATA_WIDTH),
        .ARRAY_SIZE     (ARRAY_SIZE),
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH)
    ) buffer_a (
        .clk          (aclk),
        .rst_n        (aresetn),
        .s_axis_tdata (s_axis_a_tdata),
        .s_axis_tvalid(s_axis_a_tvalid),
        .s_axis_tlast (s_axis_a_tlast),
        .s_axis_tready(s_axis_a_tready),
        .data_out_0   (a0),
        .data_out_1   (a1),
        .data_out_2   (a2),
        .data_out_3   (a3),
        .data_out_4   (a4),
        .data_out_5   (a5),
        .data_out_6   (a6),
        .data_out_7   (a7),
        .data_valid   (a_valid_beat),
        .enable       (1'b1)
    );

    // B stream buffer
    input_buffer_controller #(
        .DATA_WIDTH     (DATA_WIDTH),
        .ARRAY_SIZE     (ARRAY_SIZE),
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH)
    ) buffer_b (
        .clk          (aclk),
        .rst_n        (aresetn),
        .s_axis_tdata (s_axis_b_tdata),
        .s_axis_tvalid(s_axis_b_tvalid),
        .s_axis_tlast (s_axis_b_tlast),
        .s_axis_tready(s_axis_b_tready),
        .data_out_0   (b0),
        .data_out_1   (b1),
        .data_out_2   (b2),
        .data_out_3   (b3),
        .data_out_4   (b4),
        .data_out_5   (b5),
        .data_out_6   (b6),
        .data_out_7   (b7),
        .data_valid   (b_valid_beat),
        .enable       (1'b1)
    );


    // Output collector starts waiting immediately; it only emits beats when cells finish
    wire start_output_collector = start_tile;
    wire array_active;

    // Clear accumulators at tile start
    wire clear_acc = start_tile;


    // Systolic array instance
    wire signed [ACC_WIDTH-1:0]
        acc_out_0_0, acc_out_0_1, acc_out_0_2, acc_out_0_3,
        acc_out_0_4, acc_out_0_5, acc_out_0_6, acc_out_0_7,
        acc_out_1_0, acc_out_1_1, acc_out_1_2, acc_out_1_3,
        acc_out_1_4, acc_out_1_5, acc_out_1_6, acc_out_1_7,
        acc_out_2_0, acc_out_2_1, acc_out_2_2, acc_out_2_3,
        acc_out_2_4, acc_out_2_5, acc_out_2_6, acc_out_2_7,
        acc_out_3_0, acc_out_3_1, acc_out_3_2, acc_out_3_3,
        acc_out_3_4, acc_out_3_5, acc_out_3_6, acc_out_3_7,
        acc_out_4_0, acc_out_4_1, acc_out_4_2, acc_out_4_3,
        acc_out_4_4, acc_out_4_5, acc_out_4_6, acc_out_4_7,
        acc_out_5_0, acc_out_5_1, acc_out_5_2, acc_out_5_3,
        acc_out_5_4, acc_out_5_5, acc_out_5_6, acc_out_5_7,
        acc_out_6_0, acc_out_6_1, acc_out_6_2, acc_out_6_3,
        acc_out_6_4, acc_out_6_5, acc_out_6_6, acc_out_6_7,
        acc_out_7_0, acc_out_7_1, acc_out_7_2, acc_out_7_3,
        acc_out_7_4, acc_out_7_5, acc_out_7_6, acc_out_7_7;

    wire
        acc_done_0_0, acc_done_0_1, acc_done_0_2, acc_done_0_3,
        acc_done_0_4, acc_done_0_5, acc_done_0_6, acc_done_0_7,
        acc_done_1_0, acc_done_1_1, acc_done_1_2, acc_done_1_3,
        acc_done_1_4, acc_done_1_5, acc_done_1_6, acc_done_1_7,
        acc_done_2_0, acc_done_2_1, acc_done_2_2, acc_done_2_3,
        acc_done_2_4, acc_done_2_5, acc_done_2_6, acc_done_2_7,
        acc_done_3_0, acc_done_3_1, acc_done_3_2, acc_done_3_3,
        acc_done_3_4, acc_done_3_5, acc_done_3_6, acc_done_3_7,
        acc_done_4_0, acc_done_4_1, acc_done_4_2, acc_done_4_3,
        acc_done_4_4, acc_done_4_5, acc_done_4_6, acc_done_4_7,
        acc_done_5_0, acc_done_5_1, acc_done_5_2, acc_done_5_3,
        acc_done_5_4, acc_done_5_5, acc_done_5_6, acc_done_5_7,
        acc_done_6_0, acc_done_6_1, acc_done_6_2, acc_done_6_3,
        acc_done_6_4, acc_done_6_5, acc_done_6_6, acc_done_6_7,
        acc_done_7_0, acc_done_7_1, acc_done_7_2, acc_done_7_3,
        acc_done_7_4, acc_done_7_5, acc_done_7_6, acc_done_7_7;

    systolic_array #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH (ACC_WIDTH),
        .ARRAY_SIZE(ARRAY_SIZE)
    ) systolic_array_inst (
        .clk  (aclk),
        .rst_n(aresetn),

        .a_in_0(a0),
        .a_in_1(a1),
        .a_in_2(a2),
        .a_in_3(a3),
        .a_in_4(a4),
        .a_in_5(a5),
        .a_in_6(a6),
        .a_in_7(a7),

        .a_valid_in_0(a_valid_beat),
        .a_valid_in_1(a_valid_beat),
        .a_valid_in_2(a_valid_beat),
        .a_valid_in_3(a_valid_beat),
        .a_valid_in_4(a_valid_beat),
        .a_valid_in_5(a_valid_beat),
        .a_valid_in_6(a_valid_beat),
        .a_valid_in_7(a_valid_beat),

        .b_in_0(b0),
        .b_in_1(b1),
        .b_in_2(b2),
        .b_in_3(b3),
        .b_in_4(b4),
        .b_in_5(b5),
        .b_in_6(b6),
        .b_in_7(b7),

        .b_valid_in_0(b_valid_beat),
        .b_valid_in_1(b_valid_beat),
        .b_valid_in_2(b_valid_beat),
        .b_valid_in_3(b_valid_beat),
        .b_valid_in_4(b_valid_beat),
        .b_valid_in_5(b_valid_beat),
        .b_valid_in_6(b_valid_beat),
        .b_valid_in_7(b_valid_beat),

        .clear_acc(clear_acc),

        .acc_out_0_0(acc_out_0_0),
        .acc_out_0_1(acc_out_0_1),
        .acc_out_0_2(acc_out_0_2),
        .acc_out_0_3(acc_out_0_3),
        .acc_out_0_4(acc_out_0_4),
        .acc_out_0_5(acc_out_0_5),
        .acc_out_0_6(acc_out_0_6),
        .acc_out_0_7(acc_out_0_7),

        .acc_out_1_0(acc_out_1_0),
        .acc_out_1_1(acc_out_1_1),
        .acc_out_1_2(acc_out_1_2),
        .acc_out_1_3(acc_out_1_3),
        .acc_out_1_4(acc_out_1_4),
        .acc_out_1_5(acc_out_1_5),
        .acc_out_1_6(acc_out_1_6),
        .acc_out_1_7(acc_out_1_7),

        .acc_out_2_0(acc_out_2_0),
        .acc_out_2_1(acc_out_2_1),
        .acc_out_2_2(acc_out_2_2),
        .acc_out_2_3(acc_out_2_3),
        .acc_out_2_4(acc_out_2_4),
        .acc_out_2_5(acc_out_2_5),
        .acc_out_2_6(acc_out_2_6),
        .acc_out_2_7(acc_out_2_7),

        .acc_out_3_0(acc_out_3_0),
        .acc_out_3_1(acc_out_3_1),
        .acc_out_3_2(acc_out_3_2),
        .acc_out_3_3(acc_out_3_3),
        .acc_out_3_4(acc_out_3_4),
        .acc_out_3_5(acc_out_3_5),
        .acc_out_3_6(acc_out_3_6),
        .acc_out_3_7(acc_out_3_7),

        .acc_out_4_0(acc_out_4_0),
        .acc_out_4_1(acc_out_4_1),
        .acc_out_4_2(acc_out_4_2),
        .acc_out_4_3(acc_out_4_3),
        .acc_out_4_4(acc_out_4_4),
        .acc_out_4_5(acc_out_4_5),
        .acc_out_4_6(acc_out_4_6),
        .acc_out_4_7(acc_out_4_7),

        .acc_out_5_0(acc_out_5_0),
        .acc_out_5_1(acc_out_5_1),
        .acc_out_5_2(acc_out_5_2),
        .acc_out_5_3(acc_out_5_3),
        .acc_out_5_4(acc_out_5_4),
        .acc_out_5_5(acc_out_5_5),
        .acc_out_5_6(acc_out_5_6),
        .acc_out_5_7(acc_out_5_7),

        .acc_out_6_0(acc_out_6_0),
        .acc_out_6_1(acc_out_6_1),
        .acc_out_6_2(acc_out_6_2),
        .acc_out_6_3(acc_out_6_3),
        .acc_out_6_4(acc_out_6_4),
        .acc_out_6_5(acc_out_6_5),
        .acc_out_6_6(acc_out_6_6),
        .acc_out_6_7(acc_out_6_7),

        .acc_out_7_0(acc_out_7_0),
        .acc_out_7_1(acc_out_7_1),
        .acc_out_7_2(acc_out_7_2),
        .acc_out_7_3(acc_out_7_3),
        .acc_out_7_4(acc_out_7_4),
        .acc_out_7_5(acc_out_7_5),
        .acc_out_7_6(acc_out_7_6),
        .acc_out_7_7(acc_out_7_7),

        .acc_done_0_0(acc_done_0_0),
        .acc_done_0_1(acc_done_0_1),
        .acc_done_0_2(acc_done_0_2),
        .acc_done_0_3(acc_done_0_3),
        .acc_done_0_4(acc_done_0_4),
        .acc_done_0_5(acc_done_0_5),
        .acc_done_0_6(acc_done_0_6),
        .acc_done_0_7(acc_done_0_7),

        .acc_done_1_0(acc_done_1_0),
        .acc_done_1_1(acc_done_1_1),
        .acc_done_1_2(acc_done_1_2),
        .acc_done_1_3(acc_done_1_3),
        .acc_done_1_4(acc_done_1_4),
        .acc_done_1_5(acc_done_1_5),
        .acc_done_1_6(acc_done_1_6),
        .acc_done_1_7(acc_done_1_7),

        .acc_done_2_0(acc_done_2_0),
        .acc_done_2_1(acc_done_2_1),
        .acc_done_2_2(acc_done_2_2),
        .acc_done_2_3(acc_done_2_3),
        .acc_done_2_4(acc_done_2_4),
        .acc_done_2_5(acc_done_2_5),
        .acc_done_2_6(acc_done_2_6),
        .acc_done_2_7(acc_done_2_7),

        .acc_done_3_0(acc_done_3_0),
        .acc_done_3_1(acc_done_3_1),
        .acc_done_3_2(acc_done_3_2),
        .acc_done_3_3(acc_done_3_3),
        .acc_done_3_4(acc_done_3_4),
        .acc_done_3_5(acc_done_3_5),
        .acc_done_3_6(acc_done_3_6),
        .acc_done_3_7(acc_done_3_7),

        .acc_done_4_0(acc_done_4_0),
        .acc_done_4_1(acc_done_4_1),
        .acc_done_4_2(acc_done_4_2),
        .acc_done_4_3(acc_done_4_3),
        .acc_done_4_4(acc_done_4_4),
        .acc_done_4_5(acc_done_4_5),
        .acc_done_4_6(acc_done_4_6),
        .acc_done_4_7(acc_done_4_7),

        .acc_done_5_0(acc_done_5_0),
        .acc_done_5_1(acc_done_5_1),
        .acc_done_5_2(acc_done_5_2),
        .acc_done_5_3(acc_done_5_3),
        .acc_done_5_4(acc_done_5_4),
        .acc_done_5_5(acc_done_5_5),
        .acc_done_5_6(acc_done_5_6),
        .acc_done_5_7(acc_done_5_7),

        .acc_done_6_0(acc_done_6_0),
        .acc_done_6_1(acc_done_6_1),
        .acc_done_6_2(acc_done_6_2),
        .acc_done_6_3(acc_done_6_3),
        .acc_done_6_4(acc_done_6_4),
        .acc_done_6_5(acc_done_6_5),
        .acc_done_6_6(acc_done_6_6),
        .acc_done_6_7(acc_done_6_7),

        .acc_done_7_0(acc_done_7_0),
        .acc_done_7_1(acc_done_7_1),
        .acc_done_7_2(acc_done_7_2),
        .acc_done_7_3(acc_done_7_3),
        .acc_done_7_4(acc_done_7_4),
        .acc_done_7_5(acc_done_7_5),
        .acc_done_7_6(acc_done_7_6),
        .acc_done_7_7(acc_done_7_7),

        .array_active(array_active)
    );


    // Output collector
    output_collector #(
        .ACC_WIDTH      (ACC_WIDTH),
        .ARRAY_SIZE     (ARRAY_SIZE),
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
        .VALUES_PER_BEAT(2)
    ) output_ctrl (
        .clk  (aclk),
        .rst_n(aresetn),

        .acc_in_0_0(acc_out_0_0),
        .acc_in_0_1(acc_out_0_1),
        .acc_in_0_2(acc_out_0_2),
        .acc_in_0_3(acc_out_0_3),
        .acc_in_0_4(acc_out_0_4),
        .acc_in_0_5(acc_out_0_5),
        .acc_in_0_6(acc_out_0_6),
        .acc_in_0_7(acc_out_0_7),

        .acc_in_1_0(acc_out_1_0),
        .acc_in_1_1(acc_out_1_1),
        .acc_in_1_2(acc_out_1_2),
        .acc_in_1_3(acc_out_1_3),
        .acc_in_1_4(acc_out_1_4),
        .acc_in_1_5(acc_out_1_5),
        .acc_in_1_6(acc_out_1_6),
        .acc_in_1_7(acc_out_1_7),

        .acc_in_2_0(acc_out_2_0),
        .acc_in_2_1(acc_out_2_1),
        .acc_in_2_2(acc_out_2_2),
        .acc_in_2_3(acc_out_2_3),
        .acc_in_2_4(acc_out_2_4),
        .acc_in_2_5(acc_out_2_5),
        .acc_in_2_6(acc_out_2_6),
        .acc_in_2_7(acc_out_2_7),

        .acc_in_3_0(acc_out_3_0),
        .acc_in_3_1(acc_out_3_1),
        .acc_in_3_2(acc_out_3_2),
        .acc_in_3_3(acc_out_3_3),
        .acc_in_3_4(acc_out_3_4),
        .acc_in_3_5(acc_out_3_5),
        .acc_in_3_6(acc_out_3_6),
        .acc_in_3_7(acc_out_3_7),

        .acc_in_4_0(acc_out_4_0),
        .acc_in_4_1(acc_out_4_1),
        .acc_in_4_2(acc_out_4_2),
        .acc_in_4_3(acc_out_4_3),
        .acc_in_4_4(acc_out_4_4),
        .acc_in_4_5(acc_out_4_5),
        .acc_in_4_6(acc_out_4_6),
        .acc_in_4_7(acc_out_4_7),

        .acc_in_5_0(acc_out_5_0),
        .acc_in_5_1(acc_out_5_1),
        .acc_in_5_2(acc_out_5_2),
        .acc_in_5_3(acc_out_5_3),
        .acc_in_5_4(acc_out_5_4),
        .acc_in_5_5(acc_out_5_5),
        .acc_in_5_6(acc_out_5_6),
        .acc_in_5_7(acc_out_5_7),

        .acc_in_6_0(acc_out_6_0),
        .acc_in_6_1(acc_out_6_1),
        .acc_in_6_2(acc_out_6_2),
        .acc_in_6_3(acc_out_6_3),
        .acc_in_6_4(acc_out_6_4),
        .acc_in_6_5(acc_out_6_5),
        .acc_in_6_6(acc_out_6_6),
        .acc_in_6_7(acc_out_6_7),

        .acc_in_7_0(acc_out_7_0),
        .acc_in_7_1(acc_out_7_1),
        .acc_in_7_2(acc_out_7_2),
        .acc_in_7_3(acc_out_7_3),
        .acc_in_7_4(acc_out_7_4),
        .acc_in_7_5(acc_out_7_5),
        .acc_in_7_6(acc_out_7_6),
        .acc_in_7_7(acc_out_7_7),

        .acc_done_0_0(acc_done_0_0),
        .acc_done_0_1(acc_done_0_1),
        .acc_done_0_2(acc_done_0_2),
        .acc_done_0_3(acc_done_0_3),
        .acc_done_0_4(acc_done_0_4),
        .acc_done_0_5(acc_done_0_5),
        .acc_done_0_6(acc_done_0_6),
        .acc_done_0_7(acc_done_0_7),

        .acc_done_1_0(acc_done_1_0),
        .acc_done_1_1(acc_done_1_1),
        .acc_done_1_2(acc_done_1_2),
        .acc_done_1_3(acc_done_1_3),
        .acc_done_1_4(acc_done_1_4),
        .acc_done_1_5(acc_done_1_5),
        .acc_done_1_6(acc_done_1_6),
        .acc_done_1_7(acc_done_1_7),

        .acc_done_2_0(acc_done_2_0),
        .acc_done_2_1(acc_done_2_1),
        .acc_done_2_2(acc_done_2_2),
        .acc_done_2_3(acc_done_2_3),
        .acc_done_2_4(acc_done_2_4),
        .acc_done_2_5(acc_done_2_5),
        .acc_done_2_6(acc_done_2_6),
        .acc_done_2_7(acc_done_2_7),

        .acc_done_3_0(acc_done_3_0),
        .acc_done_3_1(acc_done_3_1),
        .acc_done_3_2(acc_done_3_2),
        .acc_done_3_3(acc_done_3_3),
        .acc_done_3_4(acc_done_3_4),
        .acc_done_3_5(acc_done_3_5),
        .acc_done_3_6(acc_done_3_6),
        .acc_done_3_7(acc_done_3_7),

        .acc_done_4_0(acc_done_4_0),
        .acc_done_4_1(acc_done_4_1),
        .acc_done_4_2(acc_done_4_2),
        .acc_done_4_3(acc_done_4_3),
        .acc_done_4_4(acc_done_4_4),
        .acc_done_4_5(acc_done_4_5),
        .acc_done_4_6(acc_done_4_6),
        .acc_done_4_7(acc_done_4_7),

        .acc_done_5_0(acc_done_5_0),
        .acc_done_5_1(acc_done_5_1),
        .acc_done_5_2(acc_done_5_2),
        .acc_done_5_3(acc_done_5_3),
        .acc_done_5_4(acc_done_5_4),
        .acc_done_5_5(acc_done_5_5),
        .acc_done_5_6(acc_done_5_6),
        .acc_done_5_7(acc_done_5_7),

        .acc_done_6_0(acc_done_6_0),
        .acc_done_6_1(acc_done_6_1),
        .acc_done_6_2(acc_done_6_2),
        .acc_done_6_3(acc_done_6_3),
        .acc_done_6_4(acc_done_6_4),
        .acc_done_6_5(acc_done_6_5),
        .acc_done_6_6(acc_done_6_6),
        .acc_done_6_7(acc_done_6_7),

        .acc_done_7_0(acc_done_7_0),
        .acc_done_7_1(acc_done_7_1),
        .acc_done_7_2(acc_done_7_2),
        .acc_done_7_3(acc_done_7_3),
        .acc_done_7_4(acc_done_7_4),
        .acc_done_7_5(acc_done_7_5),
        .acc_done_7_6(acc_done_7_6),
        .acc_done_7_7(acc_done_7_7),

        .start_output(start_output_collector),

        .m_axis_tdata (m_axis_out_tdata),
        .m_axis_tvalid(m_axis_out_tvalid),
        .m_axis_tlast (m_axis_out_tlast),
        .m_axis_tready(m_axis_out_tready),

        .done(tile_done)
    );

endmodule
