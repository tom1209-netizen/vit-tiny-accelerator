`timescale 1ns / 1ps

module gemm_top (
    input wire clk
);

    // Parameters
    parameter DATA_WIDTH = 8;
    parameter ACC_WIDTH = 32;
    parameter ARRAY_SIZE = 8;
    parameter AXIS_DATA_WIDTH = 64;

    // Signals
    wire [AXIS_DATA_WIDTH-1:0] s_axis_a_tdata, s_axis_b_tdata;
    wire s_axis_a_tvalid, s_axis_b_tvalid;
    wire s_axis_a_tlast, s_axis_b_tlast;
    wire s_axis_a_tready, s_axis_b_tready;

    wire [AXIS_DATA_WIDTH-1:0] m_axis_out_tdata;
    wire                       m_axis_out_tvalid;
    wire                       m_axis_out_tlast;
    wire                       m_axis_out_tready;

    wire                       start_tile;
    wire                       tile_done;

    // VIO Signals
    wire                       vio_start;
    wire                       vio_reset_n;

    //-------------------------------------------------------------------------
    // 1. VIO (Virtual Input/Output)
    //-------------------------------------------------------------------------
    // Configure in IP Catalog:
    // - Output Probe Count: 2
    //   - PROBE_OUT0: Width 1 (reset_n) - Set Initial Value to 0x1
    //   - PROBE_OUT1: Width 1 (start_trigger)
    vio_0 my_vio (
        .clk       (clk),
        .probe_out0(vio_reset_n),
        .probe_out1(vio_start)
    );

    //-------------------------------------------------------------------------
    // 2. Stimulus Generator
    //-------------------------------------------------------------------------
    gemm_axis_stimulus #(
        .DATA_WIDTH     (DATA_WIDTH),
        .ARRAY_SIZE     (ARRAY_SIZE),
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH)
    ) source_inst (
        .clk          (clk),
        .rst_n        (vio_reset_n),
        .start_trigger(vio_start),

        // Matrix A output
        .m_axis_a_tdata (s_axis_a_tdata),
        .m_axis_a_tvalid(s_axis_a_tvalid),
        .m_axis_a_tlast (s_axis_a_tlast),
        .m_axis_a_tready(s_axis_a_tready),

        // Matrix B output
        .m_axis_b_tdata (s_axis_b_tdata),
        .m_axis_b_tvalid(s_axis_b_tvalid),
        .m_axis_b_tlast (s_axis_b_tlast),
        .m_axis_b_tready(s_axis_b_tready),

        .start_tile(start_tile)
    );

    //-------------------------------------------------------------------------
    // 3. DUT (GEMM Core)
    //-------------------------------------------------------------------------
    gemm_core_top #(
        .DATA_WIDTH     (DATA_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),
        .ARRAY_SIZE     (ARRAY_SIZE),
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH)
    ) dut_inst (
        .aclk   (clk),
        .aresetn(vio_reset_n),

        .start_tile(start_tile),
        .tile_done (tile_done),

        .s_axis_a_tdata (s_axis_a_tdata),
        .s_axis_a_tvalid(s_axis_a_tvalid),
        .s_axis_a_tlast (s_axis_a_tlast),
        .s_axis_a_tready(s_axis_a_tready),

        .s_axis_b_tdata (s_axis_b_tdata),
        .s_axis_b_tvalid(s_axis_b_tvalid),
        .s_axis_b_tlast (s_axis_b_tlast),
        .s_axis_b_tready(s_axis_b_tready),

        .m_axis_out_tdata (m_axis_out_tdata),
        .m_axis_out_tvalid(m_axis_out_tvalid),
        .m_axis_out_tlast (m_axis_out_tlast),
        .m_axis_out_tready(m_axis_out_tready)
    );

    // Perfect sink - always ready
    assign m_axis_out_tready = 1'b1;

    //-------------------------------------------------------------------------
    // 4. ILA (Integrated Logic Analyzer)
    //-------------------------------------------------------------------------
    
    ila_0 my_ila (
        .clk    (clk),
        
        .probe0 (s_axis_a_tdata),
        .probe1 (s_axis_a_tvalid),
        .probe2 (s_axis_a_tlast),
        .probe3 (s_axis_a_tready),
        
        .probe4 (s_axis_b_tdata),
        .probe5 (s_axis_b_tvalid),
        .probe6 (s_axis_b_tlast),
        .probe7 (s_axis_b_tready),
        
        .probe8 (m_axis_out_tdata),
        .probe9 (m_axis_out_tvalid),
        .probe10 (m_axis_out_tlast),
        .probe11 (m_axis_out_tready),
        
        .probe12 (start_tile),
        .probe13(tile_done)
        
    );

endmodule
