`timescale 1ns / 1ps

// Waiting for tile config 0x10 and 0x70 to continue
module mlp_block_top #(
    parameter AXIS_DATA_WIDTH   = 64,
    parameter DATA_WIDTH        = 8,
    parameter ARRAY_SIZE        = 8
)(
    input wire clk,
    input wire rst_n,

    // AXI4-Stream input 1 (Token/Weight input, from AXI DMA Shim)
    input wire [AXIS_DATA_WIDTH-1:0]    axis_data_1_in_tdata,
    input wire                          axis_data_1_in_tvalid,
    input wire                          axis_data_1_in_tlast,
    output wire                         axis_data_1_in_tready,

    // AXI4-Stream input 2 (Requant data, used only by GeLU)
    input wire [AXIS_DATA_WIDTH-1:0]    axis_requant_b_tdata,
    input wire                          axis_requant_b_tvalid,
    input wire                          axis_requant_b_tlast,
    output wire                         axis_requant_b_tready,

    // AXI4-Stream output 1 (Weight output, always from weight buffer)
    output wire [AXIS_DATA_WIDTH-1:0]   m_axis_1_tdata,
    output wire                         m_axis_1_tvalid,
    output wire                         m_axis_1_tlast,
    input wire                          m_axis_1_tready,

    // AXI4-Stream output 0 (Norm/GeLU output, alternating)
    output wire [AXIS_DATA_WIDTH-1:0]   m_axis_0_tdata,
    output wire                         m_axis_0_tvalid,
    output wire                         m_axis_0_tlast,
    input wire                          m_axis_0_tready,

    // Control signals
    input wire enable
);

    // Wires for internal processing
    // AXI4-Stream control signals for weight_buffer_out
    wire [AXIS_DATA_WIDTH-1:0]  weight_buffer_out_tdata;
    wire                        weight_buffer_out_tvalid;
    wire                        weight_buffer_out_tready;
    wire                        weight_buffer_out_tlast;

    // AXI4-Stream control signals for norm_out
    wire [AXIS_DATA_WIDTH-1:0]  norm_out_tdata;
    wire                        norm_out_tvalid;
    wire                        norm_out_tready;
    wire                        norm_out_tlast;

    // AXI4-Stream control signals for gelu_out
    wire [AXIS_DATA_WIDTH-1:0]  gelu_out_tdata;
    wire                        gelu_out_tvalid;
    wire                        gelu_out_tready;
    wire                        gelu_out_tlast;
    
    reg current_phase;

    // Store weights and push data to axis_1
    weight_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH)
    ) weight_buffer_inst (
        .clk                (clk),
        .rst_n              (rst_n),
        
        .s_axis_tdata       (axis_data_1_in_tdata),
        .s_axis_tvalid      (axis_data_1_in_tvalid),
        .s_axis_tlast       (axis_data_1_in_tlast),
        .s_axis_tready      (axis_data_1_in_tready),
        
        .m_axis_tdata       (weight_buffer_out_tdata),
        .m_axis_tvalid      (weight_buffer_out_tvalid),
        .m_axis_tlast       (weight_buffer_out_tlast),
        .m_axis_tready      (weight_buffer_out_tready)
    );

    // Norm Block to normalize tokens
    norm_unit #(
        .DATA_WIDTH(DATA_WIDTH),
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH)
    ) norm_inst (
        .clk                (clk),
        .rst_n              (rst_n),
        
        .s_axis_tdata       (axis_data_1_in_tdata),
        .s_axis_tvalid      (axis_data_1_in_tvalid),
        .s_axis_tlast       (axis_data_1_in_tlast),
        .s_axis_tready      (axis_data_1_in_tready),
        
        .m_axis_tdata       (norm_out_tdata),
        .m_axis_tvalid      (norm_out_tvalid),
        .m_axis_tlast       (norm_out_tlast),
        .m_axis_tready      (norm_out_tready)
    );

    // GeLU Block for activation, using axis_requant_b as input
    gelu_pwl gelu_inst (
        .clk                (clk),
        .rst_n              (rst_n),
        
        .s_axis_tdata       (axis_requant_b_tdata),
        .s_axis_tvalid      (axis_requant_b_tvalid),
        .s_axis_tlast       (axis_requant_b_tlast),
        .s_axis_tready      (axis_requant_b_tready),
        
        .m_axis_tdata       (gelu_out_tdata),
        .m_axis_tvalid      (gelu_out_tvalid),
        .m_axis_tlast       (gelu_out_tlast),
        .m_axis_tready      (gelu_out_tready)
    );

    // Logic to alternate between norm and GeLU outputs to axis_0
    assign m_axis_0_tdata   = current_phase ? gelu_out_tdata    : norm_out_tdata;
    assign m_axis_0_tvalid  = current_phase ? gelu_out_tvalid   : norm_out_tvalid;
    assign m_axis_0_tlast   = current_phase ? gelu_out_tlast    : norm_out_tlast;
    
    // Ensure that tready is only asserted when tvalid is valid and the receiver is ready
    assign m_axis_0_tready = (m_axis_0_tvalid && m_axis_0_tready);

endmodule

