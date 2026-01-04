`timescale 1ns / 1ps

module axis_mux_static #
(
    parameter S_COUNT = 4,
    parameter DATA_WIDTH = 64
)
(
    input  wire                          clk,
    input  wire                          rst,

    // Inputs
    input  wire [S_COUNT*DATA_WIDTH-1:0] s_axis_tdata,
    input  wire [S_COUNT-1:0]            s_axis_tvalid,
    output reg  [S_COUNT-1:0]            s_axis_tready,
    input  wire [S_COUNT-1:0]            s_axis_tlast,
    input  wire [S_COUNT*(DATA_WIDTH/8)-1:0] s_axis_tkeep,

    // Output
    output wire [DATA_WIDTH-1:0]         m_axis_tdata,
    output wire                          m_axis_tvalid,
    input  wire                          m_axis_tready,
    output wire                          m_axis_tlast,
    output wire [(DATA_WIDTH/8)-1:0]     m_axis_tkeep,

    // Control
    input  wire                          enable, // Unused in static, kept for compatibility
    input  wire [$clog2(S_COUNT)-1:0]    select
);

    // 1. Data/Valid/Last/Keep Muxing (Combinatorial)
    // Simply slice the input array based on 'select'
    assign m_axis_tdata  = s_axis_tdata[select*DATA_WIDTH +: DATA_WIDTH];
    assign m_axis_tvalid = s_axis_tvalid[select];
    assign m_axis_tlast  = s_axis_tlast[select];
    assign m_axis_tkeep  = s_axis_tkeep[select*(DATA_WIDTH/8) +: (DATA_WIDTH/8)];

    // 2. Ready Demuxing
    // Pass the destination ready signal ONLY to the selected source
    integer i;
    always @* begin
        s_axis_tready = {S_COUNT{1'b0}};
        s_axis_tready[select] = m_axis_tready;
    end

endmodule