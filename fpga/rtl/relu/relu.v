`timescale 1ns / 1ps

module relu #(
    parameter DATA_WIDTH = 64, 
    parameter DATA_TYPE  = 8   
)(
    // Slave Interface 
    input  wire [DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                  s_axis_tvalid,
    input  wire                  s_axis_tlast,
    output wire                  s_axis_tready,

    // Master Interface 
    output wire [DATA_WIDTH-1:0] m_axis_tdata,
    output wire                  m_axis_tvalid,
    output wire                  m_axis_tlast,
    input  wire                  m_axis_tready
);

    
    localparam NUM_ELEMENTS = DATA_WIDTH / DATA_TYPE;    
    //-------------------------------------------------------------------------
    // PROCESS
    //-------------------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < NUM_ELEMENTS; i = i + 1) begin : relu_calc_loop
            assign m_axis_tdata[(i*DATA_TYPE) +: DATA_TYPE] = (s_axis_tdata[(i+1)*DATA_TYPE-1] == 1'b1) ? {DATA_TYPE{1'b0}} : s_axis_tdata[(i*DATA_TYPE) +: DATA_TYPE];
        end
    endgenerate
    
    
    assign m_axis_tvalid = s_axis_tvalid;

    
    assign m_axis_tlast  = s_axis_tlast;

    
    
    assign s_axis_tready = m_axis_tready;

endmodule