`timescale 1ns / 1ps

module layer_norm_top (
    input wire clk  // System clock (e.g., 100MHz or 125MHz on Arty)
    
);

    // Signals
    wire [63:0] s_axis_tdata, m_axis_tdata;
    wire s_axis_tvalid, m_axis_tvalid;
    wire s_axis_tready, m_axis_tready;
    wire s_axis_tlast, m_axis_tlast;
    
    wire [31:0] cfg_gamma, cfg_beta;

    // VIO Signals
    wire vio_start;
    wire vio_reset_n;  // We can control reset via VIO too

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
    layer_norm_stimulus #(
        .DATA_WIDTH(64),
        .STAT_WIDTH(32)
    ) source_inst (
        .clk          (clk),
        .rst_n        (vio_reset_n),
        .start_trigger(vio_start),

        // Outputs to Layer Norm
        .cfg_gamma(cfg_gamma),
        .cfg_beta(cfg_beta),
        
        .m_axis_tdata (s_axis_tdata),
        .m_axis_tvalid(s_axis_tvalid),
        .m_axis_tlast (s_axis_tlast),
        .m_axis_tready(s_axis_tready)
    );

    //-------------------------------------------------------------------------
    // 3. DUT (Your ReLU Module)
    //-------------------------------------------------------------------------
    layer_norm dut_inst (
        .clk(clk),
        .aresetn(vio_reset_n),

        .s_axis_tdata (s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast (s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        
        .cfg_gamma(cfg_gamma),
        .cfg_beta(cfg_beta),

        .m_axis_tdata (m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast (m_axis_tlast),
        .m_axis_tready(m_axis_tready)
    );

    // Sink (Loopback ready)
    // We just act as a perfect sink that is always ready to accept data
    assign m_axis_tready = 1'b1;

    //-------------------------------------------------------------------------
    // 4. ILA (Integrated Logic Analyzer)
    //-------------------------------------------------------------------------
    
    ila_0 my_ila (
        .clk(clk),
        
        .probe0(s_axis_tdata),
        .probe1(s_axis_tvalid),
        .probe2(s_axis_tlast),
        .probe3(s_axis_tready),
        
        .probe4(m_axis_tdata),
        .probe5(m_axis_tvalid),
        .probe6(m_axis_tlast),
        .probe7(m_axis_tready),
        
        .probe8(cfg_gamma),
        .probe9(cfg_beta)
    );

endmodule
